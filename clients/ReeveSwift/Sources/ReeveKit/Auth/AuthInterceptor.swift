import Foundation
import Connect
import SwiftProtobuf

/// Reads the current bearer token from a TokenStore and stamps it onto every
/// outbound request as `Authorization: Bearer <token>`. Also flips
/// `AuthState.needsReauth` when the server returns 401.
public final class AuthInterceptor: UnaryInterceptor, StreamInterceptor, @unchecked Sendable {
    private let tokenStore: TokenStore
    private let authState: AuthState

    public init(tokenStore: TokenStore, authState: AuthState) {
        self.tokenStore = tokenStore
        self.authState = authState
    }

    private func attachToken<Message: ProtobufMessage>(_ request: HTTPRequest<Message>) -> HTTPRequest<Message> {
        guard let token = try? tokenStore.load(), !token.isEmpty else { return request }
        var headers = request.headers
        headers["authorization"] = ["Bearer \(token)"]
        return HTTPRequest(
            url: request.url,
            headers: headers,
            message: request.message,
            method: request.method,
            trailers: request.trailers,
            idempotencyLevel: request.idempotencyLevel
        )
    }

    private func attachToken(_ request: HTTPRequest<Void>) -> HTTPRequest<Void> {
        guard let token = try? tokenStore.load(), !token.isEmpty else { return request }
        var headers = request.headers
        headers["authorization"] = ["Bearer \(token)"]
        return HTTPRequest(
            url: request.url,
            headers: headers,
            message: request.message,
            method: request.method,
            trailers: request.trailers,
            idempotencyLevel: request.idempotencyLevel
        )
    }

    // MARK: - UnaryInterceptor

    @Sendable
    public func handleUnaryRequest<Message: ProtobufMessage>(
        _ request: HTTPRequest<Message>,
        proceed: @escaping @Sendable (Result<HTTPRequest<Message>, ConnectError>) -> Void
    ) {
        proceed(.success(attachToken(request)))
    }

    @Sendable
    public func handleUnaryResponse<Message: ProtobufMessage>(
        _ response: ResponseMessage<Message>,
        proceed: @escaping @Sendable (ResponseMessage<Message>) -> Void
    ) {
        if response.code == .unauthenticated {
            authState.flagNeedsReauth()
        }
        proceed(response)
    }

    // MARK: - StreamInterceptor

    @Sendable
    public func handleStreamStart(
        _ request: HTTPRequest<Void>,
        proceed: @escaping @Sendable (Result<HTTPRequest<Void>, ConnectError>) -> Void
    ) {
        proceed(.success(attachToken(request)))
    }
}
