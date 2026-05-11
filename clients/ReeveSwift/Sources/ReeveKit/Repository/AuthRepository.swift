import Foundation
import Connect

public enum ReeveError: Error, LocalizedError {
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
            return ReeveError.humanise(rpcCode: code, message: message)
        case let .missingPayload(field):
            return "Missing field in server response: \(field)"
        case let .localStorage(err):
            return "Couldn't read local storage: \(ReeveError.display(err))"
        }
    }

    /// Public normalisation entry point. Use this anywhere a UI surface
    /// needs to render an arbitrary `Error` — it tries hardest to extract
    /// a readable sentence, then falls back to whatever string-form the
    /// system can produce. Never returns the empty string for a non-nil
    /// error: at minimum returns a placeholder so the UI doesn't render a
    /// silent failure.
    ///
    /// Code calling sites SHOULD route every catch-block error through
    /// here — `String(describing: error)` and bare `localizedDescription`
    /// both leak raw JSON / Swift type names into user-facing strings.
    public static func display(_ error: Error) -> String {
        if let ce = error as? ReeveError, let s = ce.errorDescription, !s.isEmpty {
            return s
        }
        let ld = error.localizedDescription
        if !ld.isEmpty { return normaliseEmbeddedJSON(ld) }
        return "Something went wrong."
    }

    /// Best-effort human-friendly rendering of an RPC failure. The
    /// server's Internal errors often wrap a provider's JSON envelope —
    /// `{"error":{"message":"…"}}` — and we'd rather show "…" than the
    /// whole envelope as a banner.
    private static func humanise(rpcCode: Code, message: String) -> String {
        let cleaned = normaliseEmbeddedJSON(message)
        let label = friendlyRPCLabel(for: rpcCode)
        if cleaned.isEmpty { return label }
        // Avoid the redundant "Server error: server error" pattern when
        // the cleaned message already starts with the same phrase.
        if cleaned.lowercased().hasPrefix(label.lowercased()) {
            return cleaned
        }
        return "\(label): \(cleaned)"
    }

    /// Maps Connect's lower-case RPC codes ("internal", "unavailable",
    /// "deadline_exceeded", …) to short user-facing labels. The codes
    /// themselves are mechanical and unhelpful in a banner; mapping them
    /// keeps the surface vocabulary stable.
    private static func friendlyRPCLabel(for code: Code) -> String {
        switch code {
        case .canceled:           return "Cancelled"
        case .unknown:            return "Server error"
        case .invalidArgument:    return "Invalid request"
        case .deadlineExceeded:   return "Request timed out"
        case .notFound:           return "Not found"
        case .alreadyExists:      return "Already exists"
        case .permissionDenied:   return "Permission denied"
        case .resourceExhausted:  return "Rate limit"
        case .failedPrecondition: return "Couldn't complete"
        case .aborted:            return "Aborted"
        case .outOfRange:         return "Out of range"
        case .unimplemented:      return "Not implemented"
        case .internalError:      return "Server error"
        case .unavailable:        return "Server unreachable"
        case .dataLoss:           return "Server error"
        case .unauthenticated:    return "Not signed in"
        default:                  return "Error"
        }
    }

    /// Walk a JSON tree and return the first plausible human-readable
    /// message field. Resilient to malformed input — never throws,
    /// always returns a string fit for display.
    ///
    /// Shapes recognised, in priority order:
    ///   - `{"error": {"message": "..."}}`           — OpenAI / Anthropic / Google envelope.
    ///   - `{"error": "..."}`                         — providers that send the message as a bare string.
    ///   - `{"message": "..."}`                       — our normalised wrapper.
    ///   - `{"errors": [{"message": "..."}]}`         — GitHub / GraphQL-style arrays.
    ///   - `{"detail": "..."}`                        — FastAPI / DRF default.
    ///   - `{"error_description": "..."}`             — OAuth-style.
    ///   - `"PREFIX: {json…}"` wrapped strings — server wrap-and-rethrow patterns.
    ///
    /// If none of those match but the trimmed input is itself non-empty
    /// non-JSON, return it. If it IS JSON but no message field surfaces,
    /// return a generic "Server error" rather than dumping raw braces.
    private static func normaliseEmbeddedJSON(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }

        // 1. Direct JSON parse over the whole string.
        if let extracted = extractMessageFromJSONString(trimmed) {
            return extracted
        }

        // 2. Look for an embedded `{...}` inside a wrapped string (server
        //    "prefix: {payload}" patterns) and try again on the inner JSON.
        if let braceStart = trimmed.firstIndex(of: "{"),
           let braceEnd = trimmed.lastIndex(of: "}"),
           braceStart < braceEnd {
            let inner = String(trimmed[braceStart...braceEnd])
            if let extracted = extractMessageFromJSONString(inner) {
                // Preserve any prefix text — it sometimes contains
                // useful context that the JSON alone strips.
                let prefix = trimmed[..<braceStart]
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ":-,")))
                if !prefix.isEmpty {
                    return "\(prefix): \(extracted)"
                }
                return extracted
            }
            // The string looked like JSON but had no message field. Don't
            // dump the raw braces; produce a friendly fallback.
            return "Server error"
        }

        // 3. Not JSON. Return as-is.
        return trimmed
    }

    /// Tries every known shape against a candidate JSON string. Returns
    /// nil when the candidate isn't JSON or has no extractable message.
    private static func extractMessageFromJSONString(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        // Bare JSON string (`"upstream blew up"`) → use it directly.
        if let str = any as? String, !str.isEmpty {
            return str
        }

        guard let obj = any as? [String: Any] else { return nil }

        // `{"error": {"message": "..."}}`
        if let inner = obj["error"] as? [String: Any],
           let m = inner["message"] as? String, !m.isEmpty {
            return m
        }
        // `{"error": "..."}` — providers that send the bare string.
        if let m = obj["error"] as? String, !m.isEmpty {
            return m
        }
        // Our normalised wrapper.
        if let m = obj["message"] as? String, !m.isEmpty {
            return m
        }
        // GitHub / GraphQL: `{"errors": [{"message": "..."}, ...]}`.
        if let arr = obj["errors"] as? [[String: Any]],
           let first = arr.first,
           let m = first["message"] as? String, !m.isEmpty {
            return m
        }
        // FastAPI / DRF: `{"detail": "..."}`. detail can also be a list
        // of objects (validation errors); take the first.
        if let m = obj["detail"] as? String, !m.isEmpty {
            return m
        }
        if let arr = obj["detail"] as? [[String: Any]],
           let first = arr.first {
            if let m = first["msg"] as? String, !m.isEmpty { return m }
            if let m = first["message"] as? String, !m.isEmpty { return m }
        }
        // OAuth-style.
        if let m = obj["error_description"] as? String, !m.isEmpty {
            return m
        }
        return nil
    }
}

/// Result of probing a candidate reeved URL. The login screen uses
/// this to decide whether to advance to the username/password form
/// (`.ok`) or surface a tailored failure message.
public enum ReeveProbeResult: Sendable, Equatable {
    /// Server answered cleanly. `serverName` should be "reeved" for the
    /// canonical server; clients can warn on anything else. `version` is
    /// the build identifier, empty for dev builds.
    case ok(serverName: String, version: String)
    /// Server reachable but refused the probe — e.g. an unrelated
    /// service running at this URL, or an old reeved that doesn't yet
    /// implement Probe.
    case wrongServer(detail: String)
    /// Couldn't reach the URL at all (DNS, refused, timeout, malformed
    /// URL). `detail` is a human-readable reason.
    case unreachable(detail: String)
}

/// Probes a candidate reeved URL without authentication. Doesn't hold
/// onto state — constructs a one-shot ReeveClient against the given
/// URL, calls Probe, returns. Runs on the main actor because AuthState
/// init is main-actor-isolated; the probe itself is fast and the
/// network wait is await-suspended off-actor.
@MainActor
public func probeReeveServer(url: URL) async -> ReeveProbeResult {
    let probeStore = InMemoryTokenStore()
    let probeAuth = AuthState()
    let client = ReeveClient(host: url, tokenStore: probeStore, authState: probeAuth)
    return await client.auth.probe()
}

/// Wraps the generated AuthServiceClient with idiomatic Swift methods. Hides
/// the request/response message ceremony so views can call
/// `try await repo.auth.login(username: ..., password: ...)`.
public final class AuthRepository: Sendable {
    private let client: Reeve_V1_AuthServiceClientInterface
    private let tokenStore: TokenStore
    private let authState: AuthState
    private let cache: ReeveCache?

    public init(
        client: Reeve_V1_AuthServiceClientInterface,
        tokenStore: TokenStore,
        authState: AuthState,
        cache: ReeveCache? = nil
    ) {
        self.client = client
        self.tokenStore = tokenStore
        self.authState = authState
        self.cache = cache
    }

    /// Calls AuthService.Probe. Returns a typed ReeveProbeResult so the
    /// LoginView can branch on the failure mode without parsing error
    /// messages. Doesn't throw — every code path resolves to one of the
    /// three cases.
    public func probe() async -> ReeveProbeResult {
        let resp = await client.probe(request: Reeve_V1_ProbeRequest(), headers: [:])
        if let msg = resp.message {
            return .ok(serverName: msg.server, version: msg.version)
        }
        // resp.error is set when the RPC came back with an error.
        if let err = resp.error {
            let detail = err.message ?? String(describing: err.code)
            // unimplemented or unauthenticated would be a "wrong server"
            // signal (something is at this URL but it isn't a reeved that
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

    public func login(username: String, password: String, clientLabel: String? = nil) async throws -> ReeveUser {
        var req = Reeve_V1_LoginRequest()
        req.username = username
        req.password = password
        if let clientLabel { req.clientLabel = clientLabel }

        let resp = await client.login(request: req, headers: [:])
        guard let msg = resp.message else {
            throw map(error: resp.error) ?? ReeveError.missingPayload("login response")
        }
        do { try tokenStore.save(msg.sessionToken) } catch { throw ReeveError.localStorage(error) }

        let user = ReeveUser(from: msg.user)
        await MainActor.run { authState.setAuthenticated(user) }
        return user
    }

    public func whoAmI() async throws -> ReeveUser {
        let resp = await client.whoAmI(request: Reeve_V1_WhoAmIRequest(), headers: [:])
        guard let msg = resp.message else {
            throw map(error: resp.error) ?? ReeveError.missingPayload("whoami response")
        }
        let user = ReeveUser(from: msg.user)
        await MainActor.run { authState.setAuthenticated(user) }
        // Persist for offline restore. Best-effort; a cache failure
        // here doesn't break the live login path.
        if let cache {
            try? await cache.set(user, kind: CacheKind.currentUser, id: "me", capBytes: CachePreferences.capBytes)
        }
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
    public func restoreSession() async -> ReeveUser? {
        guard let token = try? tokenStore.load(), !token.isEmpty else { return nil }
        _ = token
        do {
            return try await whoAmI()
        } catch {
            // Wipe the dead token only on auth-class failures. Network /
            // transport errors are transient — keep the token so the next
            // launch can retry once the server is reachable.
            if case let ReeveError.rpc(code, _) = error,
               code == .unauthenticated || code == .permissionDenied {
                try? tokenStore.clear()
                return nil
            }
            // Transport/unavailable: rather than bouncing the user to
            // Login, fall back to the cached identity if we have one.
            // The connectivity monitor + composer-disable already
            // signal "server unreachable" once they get inside; this
            // just lets them get past the front door.
            if let cache,
               let cached: ReeveUser = await cache.get(ReeveUser.self, kind: CacheKind.currentUser, id: "me") {
                await MainActor.run { authState.setAuthenticated(cached) }
                return cached
            }
            return nil
        }
    }

    private func map(error: ConnectError?) -> ReeveError? {
        guard let error else { return nil }
        return .rpc(code: error.code, message: error.message ?? error.code.name)
    }
}

extension ReeveUser {
    init(from p: Reeve_V1_User) {
        self.init(
            id: p.id,
            username: p.username,
            displayName: p.hasDisplayName ? p.displayName : nil,
            isAdmin: p.isAdmin
        )
    }
}
