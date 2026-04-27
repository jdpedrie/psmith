import Foundation
import Connect

public enum ClarkError: Error, LocalizedError {
    case rpc(code: Code, message: String)
    case missingPayload(String)
    case localStorage(Error)

    public var errorDescription: String? {
        switch self {
        case let .rpc(code, message):
            return "RPC \(code): \(message)"
        case let .missingPayload(field):
            return "missing payload field: \(field)"
        case let .localStorage(err):
            return "local storage error: \(err.localizedDescription)"
        }
    }
}

/// Wraps the generated AuthServiceClient with idiomatic Swift methods. Hides
/// the request/response message ceremony so views can call
/// `try await repo.auth.login(username: ..., password: ...)`.
public final class AuthRepository: Sendable {
    private let client: Clark_V1_AuthServiceClientInterface
    private let tokenStore: TokenStore
    private let authState: AuthState

    public init(
        client: Clark_V1_AuthServiceClientInterface,
        tokenStore: TokenStore,
        authState: AuthState
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.authState = authState
    }

    public func login(username: String, password: String, clientLabel: String? = nil) async throws -> ClarkUser {
        var req = Clark_V1_LoginRequest()
        req.username = username
        req.password = password
        if let clientLabel { req.clientLabel = clientLabel }

        let resp = await client.login(request: req, headers: [:])
        guard let msg = resp.message else {
            throw map(error: resp.error) ?? ClarkError.missingPayload("login response")
        }
        do { try tokenStore.save(msg.sessionToken) } catch { throw ClarkError.localStorage(error) }

        let user = ClarkUser(from: msg.user)
        await MainActor.run { authState.setAuthenticated(user) }
        return user
    }

    public func whoAmI() async throws -> ClarkUser {
        let resp = await client.whoAmI(request: Clark_V1_WhoAmIRequest(), headers: [:])
        guard let msg = resp.message else {
            throw map(error: resp.error) ?? ClarkError.missingPayload("whoami response")
        }
        let user = ClarkUser(from: msg.user)
        await MainActor.run { authState.setAuthenticated(user) }
        return user
    }

    public func logout() async throws {
        let resp = await client.logout(request: Clark_V1_LogoutRequest(), headers: [:])
        if resp.message == nil, let err = map(error: resp.error) {
            throw err
        }
        try? tokenStore.clear()
        await MainActor.run { authState.clear() }
    }

    /// Restore session from on-disk token: if a token is present, call WhoAmI.
    /// On 401 the AuthInterceptor will already have flagged needsReauth; here
    /// we just swallow the error so callers can render Login.
    @discardableResult
    public func restoreSession() async -> ClarkUser? {
        guard let token = try? tokenStore.load(), !token.isEmpty else { return nil }
        _ = token
        return try? await whoAmI()
    }

    private func map(error: ConnectError?) -> ClarkError? {
        guard let error else { return nil }
        return .rpc(code: error.code, message: error.message ?? error.code.name)
    }
}

extension ClarkUser {
    init(from p: Clark_V1_User) {
        self.init(
            id: p.id,
            username: p.username,
            displayName: p.hasDisplayName ? p.displayName : nil,
            isAdmin: p.isAdmin
        )
    }
}
