import Foundation
import Connect

/// Top-level entrypoint. Holds the configured ProtocolClient + the repositories
/// that wrap each generated service. Apps construct one of these per session.
public final class PsmithClient: Sendable {
    public let auth: AuthRepository
    public let conversations: ConversationsRepository
    public let profiles: ProfilesRepository
    public let streams: StreamSubscriber
    public let modelProviders: ModelProvidersRepository
    public let files: FilesRepository
    public let langfuse: LangfuseRepository
    public let embedder: EmbedderRepository
    public let deviceTools: DeviceToolsRepository
    public let events: EventsSubscriber
    public let speech: SpeechRepository

    /// Optional on-device read-through cache. When non-nil,
    /// repositories write successful fetches into it and fall back
    /// to it on network failure — the app keeps showing recent
    /// conversation data when psmithd is unreachable.
    public let cache: PsmithCache?

    /// Identifies this client instance to the server for the life of the
    /// process. Exposed for diagnostics; the events stream uses it to skip
    /// the echoes of this client's own mutations.
    public let clientID: String

    public init(host: URL, tokenStore: TokenStore, authState: AuthState, cache: PsmithCache? = nil) {
        // Identifies this client instance for the life of the process, so the
        // events stream can skip the echoes of mutations this client made.
        // Per-process on purpose: a restarted client has none of the state
        // that made suppressing the echo safe, so it should hear everything.
        let clientID = UUID().uuidString
        self.clientID = clientID
        let interceptor = AuthInterceptor(
            tokenStore: tokenStore,
            authState: authState,
            clientID: clientID
        )
        let config = ProtocolClientConfig(
            host: host.absoluteString,
            networkProtocol: .connect,
            codec: ProtoCodec(),
            interceptors: [.init { _ in interceptor }]
        )
        // TWO transports, because unary and streaming want opposite
        // timeouts and one URLSession can't serve both.
        //
        // Streaming: `timeoutIntervalForRequest` governs "max time
        // between bytes". A reasoning model that goes silent for ~60s
        // while it thinks would race the server-side idle timeout
        // (also 60s): sometimes URLSession wins, the subscriber gets a
        // transport error before the server's Terminal event arrives,
        // and the materialised row lands in the DB without the client
        // ever reloading the chain — the assistant turn "disappears."
        // So the stream transport sits well above that, letting the
        // server's own timer terminate first and emit a clean Terminal.
        //
        // That reasoning covers generation only. SubscribeAccountEvents
        // has no server-side bound, so 600s is the ONLY thing that would
        // ever notice a dead events stream — far too slow to be useful.
        // EventsSubscriber runs its own liveness deadline against the
        // server heartbeat instead; see RPCTimeouts.eventsLivenessDeadline.
        //
        // Unary: that same 600s applied to every list/get, which meant
        // an unreachable host pinned the launch path for ten minutes
        // per call with no error and no way for the UI to give up
        // (user-reported: "server unreachable just spins forever").
        // Unary calls are request/response, so a bound in the tens of
        // seconds is generous — the slowest are server-side model work
        // (GenerateConversationTitle, speech synthesis), not transfers.
        // This is the systemic bound; the per-call `withRPCTimeout`
        // wrappers on the launch-critical path are tighter still.
        let unaryConfig = URLSessionConfiguration.default
        unaryConfig.timeoutIntervalForRequest = RPCTimeouts.unaryRequest
        unaryConfig.timeoutIntervalForResource = RPCTimeouts.unaryResource
        let unaryClient = ProtocolClient(
            httpClient: URLSessionHTTPClient(configuration: unaryConfig),
            config: config
        )

        let streamConfig = URLSessionConfiguration.default
        streamConfig.timeoutIntervalForRequest = RPCTimeouts.streamingRequest
        let streamingClient = ProtocolClient(
            httpClient: URLSessionHTTPClient(configuration: streamConfig),
            config: config
        )
        self.cache = cache
        self.auth = AuthRepository(
            client: Psmith_V1_AuthServiceClient(client: unaryClient),
            tokenStore: tokenStore,
            authState: authState,
            cache: cache
        )
        self.conversations = ConversationsRepository(
            client: Psmith_V1_ConversationsServiceClient(client: unaryClient),
            cache: cache
        )
        self.profiles = ProfilesRepository(
            client: Psmith_V1_ProfilesServiceClient(client: unaryClient),
            cache: cache
        )
        self.streams = StreamSubscriber(
            client: Psmith_V1_StreamsServiceClient(client: streamingClient)
        )
        self.modelProviders = ModelProvidersRepository(
            client: Psmith_V1_ModelProvidersServiceClient(client: unaryClient),
            cache: cache
        )
        self.files = FilesRepository(
            client: Psmith_V1_FilesServiceClient(client: streamingClient),
            host: host
        )
        self.langfuse = LangfuseRepository(
            client: Psmith_V1_LangfuseServiceClient(client: unaryClient)
        )
        self.embedder = EmbedderRepository(
            client: Psmith_V1_EmbedderServiceClient(client: unaryClient)
        )
        self.deviceTools = DeviceToolsRepository(
            client: Psmith_V1_DeviceToolsServiceClient(client: unaryClient),
            host: host,
            tokenStore: tokenStore
        )
        self.events = EventsSubscriber(
            ownClientID: clientID,
            client: Psmith_V1_EventsServiceClient(client: streamingClient)
        )
        self.speech = SpeechRepository(
            client: Psmith_V1_SpeechServiceClient(client: unaryClient),
            host: host,
            tokenStore: tokenStore
        )
    }
}

/// Transport timeouts, named so the invariants between them are
/// testable. Both numbers come from a production failure:
///
///   - `streamingRequest` must stay ABOVE the server's stream
///     IdleTimeout (60s). Below it, URLSession kills a thinking
///     model's quiet stream before the server emits Terminal, the
///     materialised row never reaches the client, and the assistant
///     turn appears to vanish.
///   - `unaryRequest` must stay FAR BELOW it. Sharing the streaming
///     value meant an unreachable host pinned each list/get for ten
///     minutes with no error, which read to the user as an app that
///     spins forever.
enum RPCTimeouts {
    static let unaryRequest: TimeInterval = 30
    static let unaryResource: TimeInterval = 60
    static let streamingRequest: TimeInterval = 600
    /// The generation-stream idle timeout on the server
    /// (`server/stream.IdleTimeout`), which bounds how long the LLM
    /// upstream may go silent mid-run. `streamingRequest` is sized above
    /// it so the server's timer fires first and emits a clean Terminal.
    ///
    /// This governs generation only. It says nothing about
    /// SubscribeAccountEvents, which has no server-side bound at all —
    /// see `eventsLivenessDeadline`.
    static let generationIdleTimeout: TimeInterval = 60

    /// How long the events stream may go quiet before the client treats
    /// it as dead and reconnects.
    ///
    /// The server heartbeats every 20s (`server/events.HeartbeatInterval`),
    /// so silence past 50s means roughly two missed frames: long enough
    /// that a single dropped packet or a brief stall does not churn the
    /// connection, short enough to be a fraction of the 600s transport
    /// timeout that would otherwise be the only thing to notice.
    ///
    /// Without this, a half-open connection is indistinguishable from a
    /// quiet one. The app sits looking connected and receiving nothing
    /// for up to ten minutes.
    static let eventsLivenessDeadline: TimeInterval = 50
}
