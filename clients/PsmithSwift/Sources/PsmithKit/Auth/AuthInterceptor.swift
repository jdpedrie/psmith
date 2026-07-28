import Foundation
import Connect
import SwiftProtobuf

/// Reads the current bearer token from a TokenStore and stamps it onto every
/// outbound request as `Authorization: Bearer <token>`. Also flips
/// `AuthState.needsReauth` when the server returns 401.
public final class AuthInterceptor: UnaryInterceptor, StreamInterceptor, @unchecked Sendable {
    private let tokenStore: TokenStore
    private let authState: AuthState
    private let clientID: String

    /// Lowercase: connect normalises header keys, and a mismatched case reads
    /// as absent on the server.
    static let clientIDHeader = "psmith-client-id"

    public init(tokenStore: TokenStore, authState: AuthState, clientID: String) {
        self.tokenStore = tokenStore
        self.authState = authState
        self.clientID = clientID
    }

    private func attachToken<Message: ProtobufMessage>(_ request: HTTPRequest<Message>) -> HTTPRequest<Message> {
        var headers = request.headers
        // Stamped before the token check. An early return on the
        // unauthenticated path would drop the id too, and the server reads it
        // in the same place it reads the token.
        headers[Self.clientIDHeader] = [clientID]
        guard let token = try? tokenStore.load(), !token.isEmpty else {
            return HTTPRequest(
                url: request.url,
                headers: headers,
                message: request.message,
                method: request.method,
                trailers: request.trailers,
                idempotencyLevel: request.idempotencyLevel
            )
        }
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
        var headers = request.headers
        headers[Self.clientIDHeader] = [clientID]
        guard let token = try? tokenStore.load(), !token.isEmpty else {
            return HTTPRequest(
                url: request.url,
                headers: headers,
                message: request.message,
                method: request.method,
                trailers: request.trailers,
                idempotencyLevel: request.idempotencyLevel
            )
        }
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
