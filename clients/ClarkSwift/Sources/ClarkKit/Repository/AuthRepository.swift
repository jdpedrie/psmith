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

/// Result of probing a candidate clarkd URL. The login screen uses
/// this to decide whether to advance to the username/password form
/// (`.ok`) or surface a tailored failure message.
public enum ClarkProbeResult: Sendable, Equatable {
    /// Server answered cleanly. `serverName` should be "clarkd" for the
    /// canonical server; clients can warn on anything else. `version` is
    /// the build identifier, empty for dev builds.
    case ok(serverName: String, version: String)
    /// Server reachable but refused the probe — e.g. an unrelated
    /// service running at this URL, or an old clarkd that doesn't yet
    /// implement Probe.
    case wrongServer(detail: String)
    /// Couldn't reach the URL at all (DNS, refused, timeout, malformed
    /// URL). `detail` is a human-readable reason.
    case unreachable(detail: String)
}

/// Probes a candidate clarkd URL without authentication. Doesn't hold
/// onto state — constructs a one-shot ClarkClient against the given
/// URL, calls Probe, returns. Runs on the main actor because AuthState
/// init is main-actor-isolated; the probe itself is fast and the
/// network wait is await-suspended off-actor.
@MainActor
public func probeClarkServer(url: URL) async -> ClarkProbeResult {
    let probeStore = InMemoryTokenStore()
    let probeAuth = AuthState()
    let client = ClarkClient(host: url, tokenStore: probeStore, authState: probeAuth)
    return await client.auth.probe()
}

/// Wraps the generated AuthServiceClient with idiomatic Swift methods. Hides
/// the request/response message ceremony so views can call
/// `try await repo.auth.login(username: ..., password: ...)`.
public final class AuthRepository: Sendable {
    private let client: Reeve_V1_AuthServiceClientInterface
    private let tokenStore: TokenStore
    private let authState: AuthState

    public init(
        client: Reeve_V1_AuthServiceClientInterface,
        tokenStore: TokenStore,
        authState: AuthState
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.authState = authState
    }

    /// Calls AuthService.Probe. Returns a typed ClarkProbeResult so the
    /// LoginView can branch on the failure mode without parsing error
    /// messages. Doesn't throw — every code path resolves to one of the
    /// three cases.
    public func probe() async -> ClarkProbeResult {
        let resp = await client.probe(request: Reeve_V1_ProbeRequest(), headers: [:])
        if let msg = resp.message {
            return .ok(serverName: msg.server, version: msg.version)
        }
        // resp.error is set when the RPC came back with an error.
        if let err = resp.error {
            let detail = err.message ?? String(describing: err.code)
            // unimplemented or unauthenticated would be a "wrong server"
            // signal (something is at this URL but it isn't a clarkd that
            // speaks the Probe RPC). Other codes (unavailable, deadline,
            // network) are unreachable.
            switch err.code {
            case .unimplemented, .unauthenticated, .permissionDenied, .invalidArgument:
                return .wrongServer(detail: detail)
            default:
                return .unreachable(detail: detail)
            }
        }
        return .unreachable(detail: "no response from server")
    }

    public func login(username: String, password: String, clientLabel: String? = nil) async throws -> ClarkUser {
        var req = Reeve_V1_LoginRequest()
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
        let resp = await client.whoAmI(request: Reeve_V1_WhoAmIRequest(), headers: [:])
        guard let msg = resp.message else {
            throw map(error: resp.error) ?? ClarkError.missingPayload("whoami response")
        }
        let user = ClarkUser(from: msg.user)
        await MainActor.run { authState.setAuthenticated(user) }
        return user
    }

    public func logout() async throws {
        let resp = await client.logout(request: Reeve_V1_LogoutRequest(), headers: [:])
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
    init(from p: Reeve_V1_User) {
        self.init(
            id: p.id,
            username: p.username,
            displayName: p.hasDisplayName ? p.displayName : nil,
            isAdmin: p.isAdmin
        )
    }
}
