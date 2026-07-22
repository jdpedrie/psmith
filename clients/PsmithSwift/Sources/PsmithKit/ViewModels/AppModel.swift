import Foundation
import Observation

/// Top-level app state: holds the auth state and a configured PsmithClient.
/// Reusable across macOS / iOS — host apps inject the desired host URL and
/// token store via the explicit init, or use the convenience init that picks
/// sensible defaults (FileTokenStore + PSMITH_HOST env override).
@Observable
@MainActor
public final class AppModel {
    public let authState: AuthState
    public let client: PsmithClient
    /// The URL this AppModel's client was built against. Surfaced so the
    /// LoginView can show "logging into ${serverURL}" and so a "change
    /// server" affordance can compare against the persisted store.
    public let serverURL: URL
    /// The account this model serves, when running under
    /// AccountManager (every multi-account flow). nil for legacy
    /// single-account constructions; in that case caches use the
    /// process-wide default paths.
    public let accountID: UUID?

    /// Settings-tab view models held eagerly so SettingsView never has to
    /// wait for them to materialise (which causes a visible layout flash).
    public let providers: ProvidersViewModel
    public let profiles: ProfilesViewModel
    public let mcpServers: MCPServersViewModel

    /// Tracks reachability of `serverURL`. Composer reads this to
    /// disable Send when the server is unreachable; banners read it
    /// to surface a "viewing cached data" notice.
    public let connectivity: ConnectivityMonitor

    /// App-lifetime owner of every active stream subscription, so
    /// leaving a chat mid-generation and re-entering picks up where
    /// the stream left off without a refresh round-trip. View models
    /// register their runs here and read streaming state from
    /// `hub.streams[conversationID]` instead of owning it directly.
    public let streamHub: StreamHub

    /// Delivers elicitation responses (user-supplied input to MCP
    /// tool calls — e.g. an API key for Psmith Manager's
    /// `create_user_model_provider`) back to the server. Uses the
    /// session token for auth; bypasses the Connect surface because
    /// the endpoint is a small bespoke handler, not an RPC.
    public let elicitations: ElicitationsRepository

    /// Persistent outbound send queue — holds SendMessage requests
    /// that couldn't reach the server (typically because
    /// connectivity dropped) and drains them when the
    /// ConnectivityMonitor flips back to online. ConversationViewModel.send
    /// routes through this on offline so the user never gets a
    /// blocked Send button — the message rides in the queue and
    /// goes out the moment the server is reachable again.
    public let outboundQueue: OutboundQueue

    /// Device-tools dispatcher — owns the per-platform handler
    /// registry, registers the supported set with the server on
    /// bootstrap, and routes incoming ChunkDeviceToolUse events to
    /// the matching handler. Always present (cheap to hold); the
    /// platform-specific bootstrap code is what actually
    /// registers handlers for Calendar / Obsidian / etc. into
    /// `DeviceToolRegistry.shared`.
    public let deviceTools: DeviceToolDispatcher

    /// App-wide read-aloud playback — one message speaking at a
    /// time across every conversation, so it lives here rather
    /// than per-ConversationViewModel.
    public let speech: SpeechPlaybackModel

    public init(
        host: URL,
        tokenStore: TokenStore,
        authState: AuthState = .init(),
        accountID: UUID? = nil
    ) {
        self.authState = authState
        self.serverURL = host
        self.accountID = accountID
        // Cache is best-effort: if SwiftData can't bring up the
        // store (corrupt file, sandbox issue), the client falls
        // back to network-only — no offline reads, but the app
        // otherwise works. We log so the failure is debuggable.
        //
        // When an accountID is supplied, the cache file is
        // namespaced so two accounts don't share entries.
        let cache: PsmithCache?
        do {
            if let accountID {
                cache = try Self.makeAccountScopedCache(accountID: accountID)
            } else {
                cache = try PsmithCache()
            }
        } catch {
            NSLog("PsmithCache init failed: \(error). Running without on-device cache.")
            cache = nil
        }
        let c = PsmithClient(host: host, tokenStore: tokenStore, authState: authState, cache: cache)
        self.client = c
        self.providers = ProvidersViewModel(client: c)
        self.profiles = ProfilesViewModel(client: c)
        self.mcpServers = MCPServersViewModel(client: c)
        self.outboundQueue = OutboundQueue()
        self.connectivity = ConnectivityMonitor(host: host, queue: self.outboundQueue)
        let hub = StreamHub(subscriber: c.streams)
        self.streamHub = hub
        self.elicitations = ElicitationsRepository(host: host, tokenStore: tokenStore)
        let dispatcher = DeviceToolDispatcher(client: c)
        self.deviceTools = dispatcher
        self.speech = SpeechPlaybackModel(client: c)
        // Hook the hub's chunk router to the dispatcher so
        // ChunkDeviceToolUse events flow through native handlers
        // without each capability module wiring its own observer.
        hub.deviceToolDispatcher = dispatcher
    }

    /// Builds a PsmithCache whose store URL embeds the account id.
    /// Two accounts (even on the same host) get distinct sqlite
    /// files so cache hits never cross identity boundaries.
    private static func makeAccountScopedCache(accountID: UUID) throws -> PsmithCache {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("Psmith/Accounts/\(accountID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("cache.sqlite", isDirectory: false)
        return try PsmithCache(storeURL: storeURL)
    }

    /// Default factory: pulls the URL from `ServerURLStore` (which falls
    /// through to PSMITH_HOST env, then http://127.0.0.1:8080) and uses a
    /// FileTokenStore. Falls back to an in-memory token store if the
    /// file store can't be initialized.
    public convenience init() {
        let host = ServerURLStore.shared.current
        let tokenStore: TokenStore
        do {
            tokenStore = try FileTokenStore()
        } catch {
            NSLog("FileTokenStore init failed: \(error). Falling back to in-memory.")
            tokenStore = InMemoryTokenStore()
        }
        self.init(host: host, tokenStore: tokenStore, authState: AuthState())
    }

    /// Set to true once `bootstrap()` has completed. Bootstrap is
    /// idempotent at the auth-restore layer, but `connectivity.onOnline`
    /// appends to a callback list — calling bootstrap twice would
    /// register the outbound-queue drain twice, causing duplicate
    /// drains on every reconnect. Guard with this flag so the
    /// switch-account flow can safely fire `bootstrap` on every
    /// activation without piling up hooks.
    private var bootstrapped: Bool = false

    /// Fired (on MainActor) whenever the server pushes a
    /// ConversationChanged account event, for the LIST-level reaction:
    /// the platform root wires this to its ConversationsModel's
    /// debounced refresh at construction time (AppModel deliberately
    /// doesn't own the ConversationsModel — it's scene-scoped on both
    /// platforms). The per-conversation reaction routes through
    /// StreamHub.notifyConversationChanged independently.
    public var onConversationListChanged: (@MainActor () -> Void)?

    public func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        // Wire the server push channel BEFORE restoreSession so an
        // event fired during the restore window doesn't slip past
        // (rare but possible — a slow whoAmI + a fast MCP edit by
        // the same user from another client). The subscriber's
        // onProfileChanged just calls profiles.load(); idempotent +
        // cheap, so any race is harmless.
        client.events.onProfileChanged = { [weak self] _ in
            guard let self else { return }
            Task { await self.profiles.load() }
        }
        // Provider/model mutations from other clients (or this one —
        // no origin identity) reload the provider list wholesale;
        // load() is idempotent and the list is small.
        client.events.onProviderChanged = { [weak self] _ in
            guard let self else { return }
            Task { await self.providers.load() }
        }
        // Conversation mutations fan out two ways: the list-level
        // callback (debounced refresh, wired by the platform root)
        // and the per-conversation observer registry on the hub
        // (the open view model's staleness check). Events fire for
        // this client's own mutations too — both reactions are cheap
        // enough that echo suppression isn't worth its complexity.
        client.events.onConversationChanged = { [weak self] conversationID in
            guard let self else { return }
            Task { @MainActor in
                self.onConversationListChanged?()
                self.streamHub.notifyConversationChanged(conversationID: conversationID)
                // Time-critical adopt path: if the changed conversation
                // is on screen and the hub holds no stream for it, the
                // change may be another client's just-started run — one
                // scoped ListActiveRuns attaches this client to the
                // live stream in the same beat, instead of waiting for
                // the debounced list refresh's full adopt sweep.
                await self.adoptActiveRunIfViewing(conversationID: conversationID)
            }
        }
        client.events.start()
        _ = await client.auth.restoreSession()
        // `restoreSession()` flips phase to `.signedIn` on success and on
        // cached-restore under transport failure. The "no token" + "dead
        // token" paths leave it untouched, so we have to push the
        // transition to `.signedOut` ourselves — otherwise the
        // interstitial would persist forever for fresh installs.
        if authState.phase == .resolving {
            authState.clear()
        }
        // Tell the server which device tools this client can fulfill,
        // once per session. Runs after the auth restore so the
        // authenticated DeviceToolsService.RegisterCapabilities call
        // has a Bearer token. Best-effort: failure logs and the
        // device-tool catalog stays unfiltered server-side, which
        // means the model may try to call a tool the device can't
        // run — the dispatcher reports "no handler" and the model
        // sees a clean tool error.
        if authState.phase == .signedIn {
            await deviceTools.registerWithServer()
        }
        // Register the drain hook BEFORE starting the monitor so
        // the first probe of the session — which can fire online
        // immediately — runs the drain. Otherwise queued messages
        // from a prior offline session sit until the next state
        // transition.
        connectivity.onOnline { [weak self] in
            guard let self else { return }
            _ = await self.outboundQueue.drain(client: self.client)
        }
        connectivity.start()
        // After successful auth, sweep the server for runs that were
        // still going when the app last quit. Each one gets adopted
        // by the hub — cold-launching into a mid-stream conversation
        // sees live content instead of a stale chain.
        if authState.phase == .signedIn {
            await adoptActiveRunsFromServer()
        }
    }

    /// Queries the server for currently-running stream_runs the caller
    /// owns and asks `StreamHub` to adopt each one. Best-effort: a
    /// failure here just leaves the hub empty and the user's next
    /// conversation entry does the regular load.
    public func adoptActiveRunsFromServer() async {
        do {
            let runs = try await client.streams.listActiveRuns()
            for run in runs {
                streamHub.adopt(run)
            }
        } catch {
            // Don't surface — caller continues with a cold hub.
        }
    }

    /// Scoped adopt for the event fast path: when a ConversationChanged
    /// lands for a conversation the user is LOOKING AT and the hub has
    /// no active stream for it, ask the server whether a run is going
    /// and attach. Bounded to the viewed conversation so event bursts
    /// don't turn into an RPC per event; everything else is covered by
    /// the list refresh's adopt sweep a debounce-beat later.
    public func adoptActiveRunIfViewing(conversationID: String) async {
        guard streamHub.viewingConversationIDs.contains(conversationID),
              streamHub.streams[conversationID] == nil
        else { return }
        guard let runs = try? await client.streams.listActiveRuns(conversationID: conversationID) else {
            return
        }
        for run in runs {
            streamHub.adopt(run)
        }
    }

    /// Reconnect the account-events stream immediately. Platform roots
    /// call this on foregrounding (alongside their pull refresh): a
    /// stream that died during a background suspend may be deep in
    /// reconnect backoff, and the pull refresh only covers the moment
    /// of activation — the kick restores the PUSH channel for
    /// everything after it.
    public func kickEventStream() {
        client.events.kick()
    }
}
