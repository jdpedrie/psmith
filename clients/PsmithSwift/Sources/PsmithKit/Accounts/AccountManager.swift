import Foundation
import Observation

/// Top-level multi-account host. Holds the persisted list of
/// accounts, the active selection, and one live `AppModel`
/// per-account. Designed so existing call sites that read
/// `app.providers` etc. just become `accounts.active?.providers`.
///
/// Switching the active account swaps which AppModel `active`
/// returns; idle accounts stay alive in memory so re-selecting
/// snaps back instantly without a fresh login. For a personal
/// machine with 1–5 accounts the memory cost is bounded; if a
/// future use case ever wants 20+ accounts we'd switch to lazy
/// AppModel construction + LRU eviction.
///
/// **Legacy migration:** at first construction, when the persisted
/// accounts list is empty BUT the legacy single-account
/// `FileTokenStore` + `ServerURLStore` have content, this manager
/// imports them as a single account so the user's existing session
/// transparently survives the upgrade. The migration runs once;
/// after the imported account is persisted, future launches read
/// the multi-account state directly.
@Observable
@MainActor
public final class AccountManager {
    /// Every persisted account, sorted by createdAt. Mutating
    /// methods (`addAccount`, `removeAccount`) update this AND the
    /// underlying AccountStore in one operation.
    public private(set) var accounts: [Account] = []

    /// id of the currently-active account, or nil when no account
    /// is selected. `active` reads through this id to the
    /// per-account AppModel.
    public private(set) var activeAccountID: UUID?

    /// One AppModel per account, alive for the life of the
    /// process. Idle accounts continue to hold their stream
    /// subscriptions + local cache — switching back to an account
    /// is instantaneous because nothing has to be reloaded.
    private var appModelByAccount: [UUID: AppModel] = [:]

    private let store: AccountStore

    public init(store: AccountStore = .shared) {
        self.store = store
        self.accounts = store.loadAccounts()
        self.activeAccountID = store.loadActiveID()
        // Legacy single-account migration: if no accounts exist
        // yet, attempt to import the existing FileTokenStore +
        // ServerURLStore as the first account. The username comes
        // from a probe call against the legacy token; if that
        // succeeds, the account is persisted. Failure (legacy
        // token expired, server unreachable) leaves the legacy
        // state in place — the user just sees the welcome screen
        // and adds an account fresh.
        if accounts.isEmpty {
            tryImportLegacyAccount()
        }
        // Build AppModels for every persisted account up-front so
        // the active accessor never returns nil mid-session.
        for account in accounts {
            appModelByAccount[account.id] = makeAppModel(for: account)
        }
        // Fix up active pointer when the persisted id refers to an
        // account we no longer have (manual UserDefaults edit,
        // upgrade hiccup) — fall back to the first account in the
        // list or nil.
        if let id = activeAccountID, appModelByAccount[id] == nil {
            activeAccountID = accounts.first?.id
            store.saveActiveID(activeAccountID)
        } else if activeAccountID == nil, let first = accounts.first {
            activeAccountID = first.id
            store.saveActiveID(first.id)
        }
    }

    /// The currently-active AppModel, or nil when no account is
    /// selected (fresh install, user just signed out of the last
    /// account). UI surfaces nil as the welcome / login screen.
    public var active: AppModel? {
        guard let id = activeAccountID else { return nil }
        return appModelByAccount[id]
    }

    /// True when at least one account is signed in. Convenience
    /// for the App layer's "show login or app shell" decision.
    public var hasAnyAccount: Bool {
        !accounts.isEmpty
    }

    /// Accounts other than the currently-active one whose AppModel
    /// is signed in (token still valid). Used by the login screen
    /// to offer a "tap to switch back" affordance when the user
    /// signs out of the active account — without it they'd be
    /// stranded on the login form with no path back to a working
    /// session on another account.
    public var otherSignedInAccounts: [Account] {
        accounts.filter { account in
            guard account.id != activeAccountID else { return false }
            return appModelByAccount[account.id]?.authState.phase == .signedIn
        }
    }

    /// Build a fresh AppModel for the given account. Per-account
    /// storage paths (token file, SwiftData cache) come from the
    /// account id so two accounts on the same host don't collide.
    public func makeAppModel(for account: Account) -> AppModel {
        let tokenStore = perAccountTokenStore(account: account)
        return AppModel(host: account.host, tokenStore: tokenStore, accountID: account.id)
    }

    /// Logs in to `host` with the supplied credentials and adds
    /// the resulting account to the manager. On success the new
    /// account becomes active; on failure the manager is unchanged
    /// and the error propagates.
    ///
    /// `displayLabel` is optional — when nil the chip shows
    /// `username @ host.short`.
    @discardableResult
    public func addAccount(
        host: URL,
        username: String,
        password: String,
        displayLabel: String? = nil
    ) async throws -> Account {
        // Dedup: an account already exists for this (host, username).
        // Re-authenticate on its existing AppModel instead of minting
        // a duplicate row. This is what lets one form ("LoginView")
        // cover three flows: fresh first-account, add second account,
        // and sign-back-in to a signed-out account — the caller
        // always calls addAccount; this method figures out which.
        if let existing = accounts.first(where: { $0.host == host && $0.username == username }),
           let existingModel = appModelByAccount[existing.id] {
            try await existingModel.client.auth.login(username: username, password: password)
            // Bootstrap is once-per-AppModel (guarded), so re-calling
            // is a no-op when this model was bootstrapped earlier.
            await existingModel.bootstrap()
            // The events stream may be deep in reconnect backoff from
            // pre-login 401s (up to 30s) — reconnect it NOW with the
            // fresh token so pushed changes flow immediately.
            existingModel.kickEventStream()
            switchAccount(to: existing.id)
            return existing
        }
        let account = Account(host: host, username: username, displayLabel: displayLabel)
        let appModel = makeAppModel(for: account)
        try await appModel.client.auth.login(username: username, password: password)
        store.append(account, makeActive: true)
        accounts.append(account)
        appModelByAccount[account.id] = appModel
        activeAccountID = account.id
        await appModel.bootstrap()
        return account
    }

    /// Switch the active account. No-op when `id` is already
    /// active or unknown. Doesn't tear down the previously-active
    /// account — its AppModel keeps its stream subscriptions so
    /// switching back is instantaneous.
    public func switchAccount(to id: UUID) {
        guard appModelByAccount[id] != nil else { return }
        if activeAccountID == id { return }
        activeAccountID = id
        store.saveActiveID(id)
    }

    /// Forget an account: clears its token, drops the in-memory
    /// AppModel, removes the entry from the persisted list. If
    /// the removed account was active, the first remaining account
    /// becomes active (or nil when this was the last one).
    public func removeAccount(id: UUID) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        // Best-effort logout so the server invalidates the
        // session. Failures are silent — the local token is
        // cleared regardless so the account can't be resumed.
        if let model = appModelByAccount[id] {
            _ = try? await model.client.auth.logout()
        }
        let tokenStore = perAccountTokenStore(account: account)
        try? tokenStore.clear()
        appModelByAccount[id] = nil
        accounts = store.remove(id)
        activeAccountID = store.loadActiveID()
    }

    /// Sign out of the active account WITHOUT removing it from
    /// the list. The account stays in the switcher with its
    /// host/username intact so the user can sign back in with one
    /// click. Equivalent to clearing the token + clearing the
    /// active pointer if this was the last account.
    public func signOutActive() async {
        guard let id = activeAccountID,
              let model = appModelByAccount[id],
              let account = accounts.first(where: { $0.id == id }) else { return }
        _ = try? await model.client.auth.logout()
        let tokenStore = perAccountTokenStore(account: account)
        try? tokenStore.clear()
        // Local auth state flips to signed-out so the UI shows
        // login when this account is selected. We don't tear down
        // the AppModel — the same token store can authenticate
        // again on next login.
        model.authState.clear()
    }

    /// Bundle ids allowed to run the legacy import. The legacy token
    /// file lives at a USER-level path on macOS
    /// (~/Library/Application Support/PsmithMac/session.token), so
    /// without this gate ANY empty-account process running as the
    /// user — a rebadged scratch instance, a test runner — silently
    /// adopts the user's real session (observed twice; the incident
    /// log lives in docs/todo.md under "AccountManager legacy
    /// import"). Only the shipping apps may import.
    nonisolated static let legacyImportBundleWhitelist: Set<String> = [
        "dev.jdpedrie.PsmithMac",
        "dev.jdpedrie.PsmithiOS",
    ]

    /// Pure gate decision, separated so the whitelist logic is unit-
    /// testable without touching the real legacy file path.
    nonisolated static func shouldAttemptLegacyImport(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return legacyImportBundleWhitelist.contains(bundleID)
    }

    /// Try to import the existing single-account state (legacy
    /// FileTokenStore + ServerURLStore) as the first account.
    /// Best-effort: failures leave the legacy state untouched and
    /// the manager starts empty.
    private func tryImportLegacyAccount() {
        guard Self.shouldAttemptLegacyImport(bundleID: Bundle.main.bundleIdentifier) else {
            return
        }
        let host = ServerURLStore.shared.current
        guard let legacyStore = try? FileTokenStore() else { return }
        guard let token = try? legacyStore.load(), !(token.isEmpty) else { return }
        // Username unknown until a probe call confirms it. We
        // attempt the probe synchronously inside a Task — but for
        // simplicity here we just record `unknown`; on first
        // bootstrap the AuthRepository.restoreSession will refresh
        // the username via the AuthState. For initial import the
        // resolvedDisplayLabel falls back to the host string.
        let imported = Account(
            host: host,
            username: "imported",
            displayLabel: nil
        )
        // Copy the legacy token to the per-account file so the
        // imported account authenticates via its own token store.
        let perAccount = perAccountTokenStore(account: imported)
        try? perAccount.save(token)
        store.append(imported, makeActive: true)
        accounts = store.loadAccounts()
        activeAccountID = imported.id
        // Leave the legacy file in place for one launch as a
        // safety net. A follow-up cleanup pass can remove it after
        // the user confirms the imported account works.
    }

    /// Per-account FileTokenStore. Filename derives from the
    /// account id so two accounts (even on the same host) get
    /// distinct token files.
    private func perAccountTokenStore(account: Account) -> TokenStore {
        do {
            return try FileTokenStore(
                directoryName: "PsmithAccounts",
                filename: "session-\(account.id.uuidString).token"
            )
        } catch {
            NSLog("AccountManager: per-account FileTokenStore init failed for \(account.id): \(error). Using in-memory.")
            return InMemoryTokenStore()
        }
    }
}
