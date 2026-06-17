import Foundation

/// Persistent storage + resolution for the Obsidian vault's
/// security-scoped bookmark. The user picks their vault folder via
/// `UIDocumentPicker` (see ObsidianVaultView); the picked URL is
/// converted to a bookmark with `.minimalBookmark` + security-scoped
/// resolution, persisted to UserDefaults, and resolved on every
/// subsequent tool call.
///
/// Security-scoped bookmarks survive app restart and provide ongoing
/// access to a user-chosen folder outside the app's sandbox. Each
/// access must be wrapped in
/// `url.startAccessingSecurityScopedResource()` /
/// `stopAccessingSecurityScopedResource()` — the helper here
/// centralises that dance so handlers don't forget.
enum ObsidianVaultBookmark {
    private static let key = "spalt.obsidian.vaultBookmark.v1"

    /// True when a vault bookmark is currently saved. Drives the
    /// settings UI's "vault selected" indicator + the iOS client's
    /// RegisterCapabilities pass: when false, the obsidian_* tool
    /// names are NOT advertised, so the server's obsidian plugin
    /// returns a friendly "open Settings → Obsidian" error to the
    /// model instead of letting the call land on an unbookmarked
    /// device.
    static var isSet: Bool {
        return UserDefaults.standard.data(forKey: key) != nil
    }

    /// Persist the bookmark for a picked vault URL. Caller should
    /// already have called startAccessingSecurityScopedResource on
    /// the URL (UIDocumentPicker hands back URLs that need that
    /// dance). Throws on bookmark-creation failure (rare; the URL
    /// must be valid + the user must have actually granted access).
    static func save(folderURL: URL) throws {
        let data = try folderURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Remove the saved bookmark — settings UI's "forget vault"
    /// affordance.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Resolve the bookmark to a usable URL. Returns nil when no
    /// bookmark is stored or the bookmark has gone stale (folder
    /// deleted, moved, etc.) — the caller surfaces a clear error
    /// to the model in either case.
    ///
    /// Stale-bookmark resolution can succeed with `isStale=true`;
    /// we discard those and signal "no vault" because regenerating
    /// the bookmark requires re-prompting the user with
    /// UIDocumentPicker, which can't happen from a background
    /// handler.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                return nil
            }
            return url
        } catch {
            return nil
        }
    }

    /// Run a block with the resolved vault URL inside a security-
    /// scoped resource access. Returns whatever the block returns;
    /// throws if no bookmark is saved or the resource can't be
    /// accessed.
    static func withVault<T>(_ block: (URL) throws -> T) throws -> T {
        guard let url = resolve() else {
            throw ObsidianVaultError.notConfigured
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw ObsidianVaultError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try block(url)
    }
}

enum ObsidianVaultError: Error, CustomStringConvertible {
    case notConfigured
    case accessDenied
    case noteNotFound(String)
    case noteAlreadyExists(String)
    case outsideVault(String)

    var description: String {
        switch self {
        case .notConfigured:
            return "no Obsidian vault is bookmarked on this device — open Settings → Obsidian and pick your vault folder"
        case .accessDenied:
            return "the saved vault bookmark could not be accessed (folder may have moved)"
        case .noteNotFound(let p):
            return "note '\(p)' not found in vault"
        case .noteAlreadyExists(let p):
            return "note '\(p)' already exists (pass overwrite=true to replace)"
        case .outsideVault(let p):
            return "path '\(p)' escapes the vault root"
        }
    }
}
