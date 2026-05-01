import Foundation
import Connect

/// Top-level entrypoint. Holds the configured ProtocolClient + the repositories
/// that wrap each generated service. Apps construct one of these per session.
public final class ReeveClient: Sendable {
    public let auth: AuthRepository
    public let conversations: ConversationsRepository
    public let profiles: ProfilesRepository
    public let streams: StreamSubscriber
    public let modelProviders: ModelProvidersRepository

    public init(host: URL, tokenStore: TokenStore, authState: AuthState) {
        let interceptor = AuthInterceptor(tokenStore: tokenStore, authState: authState)
        let config = ProtocolClientConfig(
            host: host.absoluteString,
            networkProtocol: .connect,
            codec: ProtoCodec(),
            interceptors: [.init { _ in interceptor }]
        )
        let protocolClient = ProtocolClient(
            httpClient: URLSessionHTTPClient(),
            config: config
        )
        self.auth = AuthRepository(
            client: Reeve_V1_AuthServiceClient(client: protocolClient),
            tokenStore: tokenStore,
            authState: authState
        )
        self.conversations = ConversationsRepository(
            client: Reeve_V1_ConversationsServiceClient(client: protocolClient)
        )
        self.profiles = ProfilesRepository(
            client: Reeve_V1_ProfilesServiceClient(client: protocolClient)
        )
        self.streams = StreamSubscriber(
            client: Reeve_V1_StreamsServiceClient(client: protocolClient)
        )
        self.modelProviders = ModelProvidersRepository(
            client: Reeve_V1_ModelProvidersServiceClient(client: protocolClient)
        )
    }
}
