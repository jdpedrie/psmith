import Foundation
import Connect

public enum ClarkError: Error, LocalizedError {
    case rpc(code: Code, message: String)
    case missingPayload(String)
    case localStorage(Error)

    public var errorDescription: String? {
        switch self {
        case let .rpc(code, message):
            // Many upstream errors arrive with a JSON envelope embedded in
            // the RPC message string (provider 4xx/5xx errors that the
            // server pass-through wraps). Pull the human-readable bit so
            // banners and toasts read cleanly. The raw stays available
            // via the Error itself; this is just the display path.
            return ClarkError.humanise(rpcCode: code, message: message)
        case let .missingPayload(field):
            return "missing payload field: \(field)"
        case let .localStorage(err):
            return "local storage error: \(err.localizedDescription)"
        }
    }

    /// Public normalisation entry point. Use this anywhere a UI surface
    /// needs to render an arbitrary `Error` — it tries hardest to extract
    /// a readable sentence, then falls back to whatever string-form the
    /// system can produce. Never returns the empty string for a non-nil
    /// error: at minimum returns a placeholder so the UI doesn't render a
    /// silent failure.
    public static func display(_ error: Error) -> String {
        if let ce = error as? ClarkError, let s = ce.errorDescription, !s.isEmpty {
            return s
        }
        let ld = error.localizedDescription
        if !ld.isEmpty { return normaliseEmbeddedJSON(ld) }
        return "(unknown error: \(String(describing: type(of: error))))"
    }

    /// Best-effort human-friendly rendering of an RPC failure. The
    /// server's Internal errors often wrap a provider's JSON envelope —
    /// `{"error":{"message":"…"}}` — and we'd rather show "…" than the
    /// whole envelope as a banner.
    private static func humanise(rpcCode: Code, message: String) -> String {
        let cleaned = normaliseEmbeddedJSON(message)
        if cleaned.isEmpty { return "RPC \(rpcCode)" }
        return "RPC \(rpcCode): \(cleaned)"
    }

    /// If `s` looks like JSON containing a `.error.message` (or top-level
    /// `.message`) field, return that. Otherwise return `s` trimmed.
    /// Resilient to malformed input — never throws, always returns a
    /// string fit for display.
    private static func normaliseEmbeddedJSON(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return trimmed }
        // Try `{"error":{"message":"…"}}` first — the OpenAI / Anthropic /
        // Google envelope shape that 99% of provider 4xx/5xx use.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let inner = obj["error"] as? [String: Any],
               let m = inner["message"] as? String, !m.isEmpty {
                return m
            }
            if let m = obj["message"] as? String, !m.isEmpty {
                return m
            }
        }
        // The string might also be a "PREFIX: {json…}" form — server
        // wrap-and-rethrow patterns. Look for an embedded `{...}` and
        // try to pull a message out of it.
        if let braceStart = trimmed.firstIndex(of: "{"),
           let braceEnd = trimmed.lastIndex(of: "}"),
           braceStart < braceEnd {
            let inner = String(trimmed[braceStart...braceEnd])
            if let data = inner.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let env = obj["error"] as? [String: Any],
                   let m = env["message"] as? String, !m.isEmpty {
                    return m
                }
                if let m = obj["message"] as? String, !m.isEmpty {
                    return m
                }
            }
        }
        return trimmed
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
    /// we swallow the error so callers can render Login. We also clear the
    /// keychain when the stored token is rejected, so subsequent launches
    /// don't repeat the dead-token round-trip and force the user through a
    /// fresh login flow once.
    @discardableResult
    public func restoreSession() async -> ClarkUser? {
        guard let token = try? tokenStore.load(), !token.isEmpty else { return nil }
        _ = token
        do {
            return try await whoAmI()
        } catch {
            // Wipe the dead token only on auth-class failures. Network /
            // transport errors are transient — keep the token so the next
            // launch can retry once the server is reachable.
            if case let ClarkError.rpc(code, _) = error,
               code == .unauthenticated || code == .permissionDenied {
                try? tokenStore.clear()
            }
            return nil
        }
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
