import Foundation

/// Handlers for the Obsidian-vault device tools. Each handler
/// resolves the security-scoped bookmark via
/// `FilesFolderBookmark.withVault`, does its filesystem work, and
/// returns a structured JSON response.
///
/// Vault-relative paths are normalised before use — leading slashes
/// are stripped, `..` traversal is rejected (we don't want the
/// model writing outside the bookmarked folder), and paths must
/// end in `.md` for read/write operations to keep the surface
/// scoped to the actual notes.
public enum FilesTools {

    private static let toolNames = [
        "files_list_notes",
        "files_read_note",
        "files_append_note",
        "files_create_note",
        "files_search_text",
    ]

    public static func register() {
        let r = DeviceToolRegistry.shared
        r.register(name: "files_list_notes", handler: listNotes)
        r.register(name: "files_read_note", handler: readNote)
        r.register(name: "files_append_note", handler: appendNote)
        r.register(name: "files_create_note", handler: createNote)
        r.register(name: "files_search_text", handler: searchText)
    }

    /// Mirror of register() — drops the files_* handlers from
    /// the shared registry. Called when the user forgets their
    /// vault so the iOS RegisterCapabilities pass stops advertising
    /// these tools to the server.
    public static func unregister() {
        let r = DeviceToolRegistry.shared
        for name in toolNames {
            r.unregister(name: name)
        }
    }

    /// Sync the registration state to the current bookmark state.
    /// Call from app boot and after any vault-bookmark change so
    /// the dispatcher's registeredNames() always reflects what
    /// this device can actually fulfill.
    public static func syncRegistration() {
        if isAvailable {
            register()
        } else {
            unregister()
        }
    }

    /// Whether to advertise files_* tools at RegisterCapabilities
    /// time. The dispatcher's registerWithServer call sources the
    /// supported set from DeviceToolRegistry.shared.registeredNames,
    /// which is everything we've registered — but obsidian tools
    /// only make sense when a vault bookmark exists. PsmithiOSApp
    /// checks this and registers (or skips) accordingly; the
    /// server's obsidian plugin then refuses calls if the iOS
    /// client didn't advertise.
    static var isAvailable: Bool {
        FilesFolderBookmark.isSet
    }

    // MARK: - Handlers

    private static let listNotes: DeviceToolHandler = { inputJSON in
        let input = try decode(ListInput.self, from: inputJSON)
        let recursive = input.recursive ?? true
        let output = try FilesFolderBookmark.withVault { root -> ListOutput in
            let start = try resolveSubfolder(root: root, folder: input.folder)
            let notes = try walkMarkdownNotes(root: start, vaultRoot: root, recursive: recursive)
            return ListOutput(notes: notes.sorted())
        }
        return try JSONEncoder.iso8601.encode(output)
    }

    private static let readNote: DeviceToolHandler = { inputJSON in
        let input = try decode(ReadInput.self, from: inputJSON)
        let payload = try FilesFolderBookmark.withVault { root -> ReadOutput in
            let url = try resolveNotePath(root: root, path: input.path, mustExist: true)
            let content = try String(contentsOf: url, encoding: .utf8)
            return ReadOutput(path: input.path, content: content)
        }
        return try JSONEncoder.iso8601.encode(payload)
    }

    private static let appendNote: DeviceToolHandler = { inputJSON in
        let input = try decode(WriteInput.self, from: inputJSON)
        let payload = try FilesFolderBookmark.withVault { root -> WriteOutput in
            let url = try resolveNotePath(root: root, path: input.path, mustExist: true)
            var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // Append with a blank-line separator so daily-log style
            // captures stay readable. Only add the separator if the
            // existing content doesn't already end in two newlines.
            if !existing.isEmpty {
                if !existing.hasSuffix("\n\n") {
                    if existing.hasSuffix("\n") { existing += "\n" }
                    else                         { existing += "\n\n" }
                }
            }
            let updated = existing + input.content
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return WriteOutput(path: input.path, bytes: updated.utf8.count)
        }
        return try JSONEncoder.iso8601.encode(payload)
    }

    private static let createNote: DeviceToolHandler = { inputJSON in
        let input = try decode(CreateInput.self, from: inputJSON)
        let overwrite = input.overwrite ?? false
        let payload = try FilesFolderBookmark.withVault { root -> WriteOutput in
            let url = try resolveNotePath(root: root, path: input.path, mustExist: false)
            if !overwrite && FileManager.default.fileExists(atPath: url.path) {
                throw ObsidianVaultError.noteAlreadyExists(input.path)
            }
            // Ensure parent directory exists.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try input.content.write(to: url, atomically: true, encoding: .utf8)
            return WriteOutput(path: input.path, bytes: input.content.utf8.count)
        }
        return try JSONEncoder.iso8601.encode(payload)
    }

    private static let searchText: DeviceToolHandler = { inputJSON in
        let input = try decode(SearchInput.self, from: inputJSON)
        let limit = min(max(input.limit ?? 10, 1), 50)
        let query = input.query.lowercased()
        if query.isEmpty {
            throw DeviceToolError.message("query is required")
        }
        let output = try FilesFolderBookmark.withVault { root -> SearchOutput in
            var hits: [SearchHit] = []
            let notes = try walkMarkdownNotes(root: root, vaultRoot: root, recursive: true)
            for rel in notes {
                let url = root.appendingPathComponent(rel)
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if let range = content.lowercased().range(of: query) {
                    let snippet = makeSnippet(from: content, around: range, vault: rel)
                    hits.append(SearchHit(path: rel, excerpt: snippet))
                    if hits.count >= limit { break }
                }
            }
            return SearchOutput(query: input.query, hits: hits)
        }
        return try JSONEncoder.iso8601.encode(output)
    }

    // MARK: - Path resolution + safety

    /// Resolve `folder` under `root`, defaulting to `root` itself
    /// when nil/empty. Refuses traversal via `..`.
    private static func resolveSubfolder(root: URL, folder: String?) throws -> URL {
        guard let folder = folder?.trimmingCharacters(in: .init(charactersIn: " /")),
              !folder.isEmpty else { return root }
        if folder.contains("..") {
            throw ObsidianVaultError.outsideVault(folder)
        }
        return root.appendingPathComponent(folder, isDirectory: true)
    }

    /// Resolve a vault-relative note path to an absolute URL.
    /// Refuses leading slashes (those would escape via absolute
    /// paths), `..` traversal, and anything not ending in `.md`.
    /// When `mustExist` is true, throws `.noteNotFound` if the
    /// file is missing.
    private static func resolveNotePath(root: URL, path: String, mustExist: Bool) throws -> URL {
        let cleaned = path.trimmingCharacters(in: .init(charactersIn: " /"))
        if cleaned.isEmpty {
            throw ObsidianVaultError.outsideVault(path)
        }
        if cleaned.contains("..") {
            throw ObsidianVaultError.outsideVault(path)
        }
        // Tolerate the model leaving the .md off — append it.
        let withExt = cleaned.hasSuffix(".md") ? cleaned : (cleaned + ".md")
        let url = root.appendingPathComponent(withExt)
        if mustExist, !FileManager.default.fileExists(atPath: url.path) {
            throw ObsidianVaultError.noteNotFound(cleaned)
        }
        return url
    }

    /// Walk a folder for `.md` files, returning vault-relative paths.
    private static func walkMarkdownNotes(root: URL, vaultRoot: URL, recursive: Bool) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        var out: [String] = []
        let prefix = vaultRoot.path
        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            let abs = url.path
            if abs.hasPrefix(prefix) {
                var rel = String(abs.dropFirst(prefix.count))
                if rel.hasPrefix("/") { rel.removeFirst() }
                out.append(rel)
            }
        }
        return out
    }

    /// Build a ~160-char excerpt centred on the match. Strips
    /// internal newlines + collapses whitespace so the model
    /// sees a clean blurb regardless of how the surrounding
    /// markdown is wrapped.
    private static func makeSnippet(from content: String, around range: Range<String.Index>, vault: String) -> String {
        let target: Int = 160
        let halfTarget = target / 2
        let startOffset = content.distance(from: content.startIndex, to: range.lowerBound)
        let endOffset = content.distance(from: content.startIndex, to: range.upperBound)
        let lo = max(0, startOffset - halfTarget)
        let hi = min(content.count, endOffset + halfTarget)
        let loIdx = content.index(content.startIndex, offsetBy: lo)
        let hiIdx = content.index(content.startIndex, offsetBy: hi)
        let raw = String(content[loIdx..<hiIdx])
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let lead = lo > 0 ? "…" : ""
        let trail = hi < content.count ? "…" : ""
        return lead + collapsed + trail
    }

    // MARK: - Wire types

    private struct ListInput: Decodable {
        let folder: String?
        let recursive: Bool?
    }
    private struct ListOutput: Encodable {
        let notes: [String]
    }
    private struct ReadInput: Decodable { let path: String }
    private struct ReadOutput: Encodable {
        let path: String
        let content: String
    }
    private struct WriteInput: Decodable {
        let path: String
        let content: String
    }
    private struct WriteOutput: Encodable {
        let path: String
        let bytes: Int
    }
    private struct CreateInput: Decodable {
        let path: String
        let content: String
        let overwrite: Bool?
    }
    private struct SearchInput: Decodable {
        let query: String
        let limit: Int?
    }
    private struct SearchOutput: Encodable {
        let query: String
        let hits: [SearchHit]
    }
    private struct SearchHit: Encodable {
        let path: String
        let excerpt: String
    }
}
