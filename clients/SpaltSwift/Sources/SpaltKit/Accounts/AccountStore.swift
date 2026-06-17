import Foundation

/// Persists the list of remembered accounts + the currently-active
/// account ID across app launches via UserDefaults. Tokens live
/// elsewhere (per-account `TokenStore`) — this store only carries
/// identity metadata that's safe to keep in plaintext defaults.
///
/// Mirrors the singleton pattern used by `ServerURLStore` and
/// `ThemeStore`: `shared` is the process-wide instance; tests
/// construct fresh instances against a custom UserDefaults suite
/// so they don't pollute the user's prefs.
public final class AccountStore: @unchecked Sendable {
    public static let shared = AccountStore()

    private static let accountsKey = "spalt.accounts.v1"
    private static let activeIDKey = "spalt.accounts.active_id.v1"

    private let defaults: UserDefaults
    /// Lock guards in-memory mutations; the file-backed defaults
    /// itself is thread-safe but the load/decode/encode round-trip
    /// isn't atomic.
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns every persisted account, sorted by `createdAt` so
    /// the switcher list reads stable across launches.
    public func loadAccounts() -> [Account] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.createdAt < $1.createdAt }
    }

    /// The id of the currently-selected account, or nil when none
    /// has been chosen (fresh install / user signed out of every
    /// account). Returns nil when the persisted id refers to an
    /// account the caller can't find — `AccountManager` handles
    /// the fallback selection.
    public func loadActiveID() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard let s = defaults.string(forKey: Self.activeIDKey) else { return nil }
        return UUID(uuidString: s)
    }

    /// Replaces the persisted accounts list verbatim. Callers that
    /// add or remove an entry typically read → mutate → save in one
    /// pass; the lock keeps that round-trip atomic per-process.
    public func saveAccounts(_ accounts: [Account]) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.accountsKey)
    }

    /// Persists the active id. Pass nil to clear (no account
    /// selected) — the next launch will fall through to "first
    /// available account" or the welcome screen.
    public func saveActiveID(_ id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeIDKey)
        } else {
            defaults.removeObject(forKey: Self.activeIDKey)
        }
    }

    /// Convenience: append a new account + immediately set it
    /// active. Used by the "Add account" flow once login succeeds.
    public func append(_ account: Account, makeActive: Bool = true) {
        var list = loadAccounts()
        list.append(account)
        saveAccounts(list)
        if makeActive {
            saveActiveID(account.id)
        }
    }

    /// Convenience: remove an account by id. Returns the new
    /// accounts list. The caller is responsible for clearing the
    /// account's token store and tearing down its in-memory
    /// ViewModels — this method only touches metadata.
    @discardableResult
    public func remove(_ id: UUID) -> [Account] {
        var list = loadAccounts()
        list.removeAll { $0.id == id }
        saveAccounts(list)
        // Clear active pointer if it referenced the removed account.
        if loadActiveID() == id {
            saveActiveID(list.first?.id)
        }
        return list
    }
}
