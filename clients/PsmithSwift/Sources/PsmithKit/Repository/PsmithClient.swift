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

    /// Optional on-device read-through cache. When non-nil,
    /// repositories write successful fetches into it and fall back
    /// to it on network failure — the app keeps showing recent
    /// conversation data when psmithd is unreachable.
    public let cache: PsmithCache?

    public init(host: URL, tokenStore: TokenStore, authState: AuthState, cache: PsmithCache? = nil) {
        let interceptor = AuthInterceptor(tokenStore: tokenStore, authState: authState)
        let config = ProtocolClientConfig(
            host: host.absoluteString,
            networkProtocol: .connect,
            codec: ProtoCodec(),
            interceptors: [.init { _ in interceptor }]
        )
        // URLSession defaults to a 60s `timeoutIntervalForRequest` that
        // governs "max time between bytes" for any request — including
        // server-streaming SubscribeStream calls. A reasoning model
        // that goes silent for ~60s while it thinks would otherwise
        // race against the server-side idle timeout (also 60s):
        // sometimes URLSession wins, the iOS subscriber gets a
        // transport error before the server's Terminal event arrives,
        // and the materialised row appears in the DB without iOS ever
        // reloading the chain — the assistant turn "disappears."
        //
        // Bump the per-request timeout well above the server's
        // IdleTimeout so the server's own timer reliably terminates
        // the stream first and emits a clean Terminal event. The
        // resource timeout keeps the URLSession default (~7 days), so
        // a runaway stream can't leak forever.
        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = 600
        let protocolClient = ProtocolClient(
            httpClient: URLSessionHTTPClient(configuration: urlConfig),
            config: config
        )
        self.cache = cache
        self.auth = AuthRepository(
            client: Psmith_V1_AuthServiceClient(client: protocolClient),
            tokenStore: tokenStore,
            authState: authState,
            cache: cache
        )
        self.conversations = ConversationsRepository(
            client: Psmith_V1_ConversationsServiceClient(client: protocolClient),
            cache: cache
        )
        self.profiles = ProfilesRepository(
            client: Psmith_V1_ProfilesServiceClient(client: protocolClient),
            cache: cache
        )
        self.streams = StreamSubscriber(
            client: Psmith_V1_StreamsServiceClient(client: protocolClient)
        )
        self.modelProviders = ModelProvidersRepository(
            client: Psmith_V1_ModelProvidersServiceClient(client: protocolClient),
            cache: cache
        )
        self.files = FilesRepository(
            client: Psmith_V1_FilesServiceClient(client: protocolClient),
            host: host
        )
        self.langfuse = LangfuseRepository(
            client: Psmith_V1_LangfuseServiceClient(client: protocolClient)
        )
        self.embedder = EmbedderRepository(
            client: Psmith_V1_EmbedderServiceClient(client: protocolClient)
        )
        self.deviceTools = DeviceToolsRepository(
            client: Psmith_V1_DeviceToolsServiceClient(client: protocolClient),
            host: host,
            tokenStore: tokenStore
        )
        self.events = EventsSubscriber(
            client: Psmith_V1_EventsServiceClient(client: protocolClient)
        )
    }
}
