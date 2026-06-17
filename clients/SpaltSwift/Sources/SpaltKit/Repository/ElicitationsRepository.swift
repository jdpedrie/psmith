import Foundation

/// User-side projection of an MCP elicitation action. Mirrors
/// `internal/elicit.Action`. Encoded as the lowercase string on the
/// wire.
public enum SpaltElicitAction: String, Sendable, Hashable, Codable {
    case accept
    case decline
    case cancel
}

/// Repository for delivering elicitation responses back to the server.
/// Bypasses the Connect surface — the endpoint is a plain HTTP POST
/// (`/conversations/{id}/elicitations/{eid}/respond`) because the
/// server-side response flow is a small bespoke handler, not a Connect
/// RPC. Bearer-token auth identical to the Connect calls (same
/// session table); reuses the app's existing TokenStore.
public final class ElicitationsRepository: Sendable {
    private let host: URL
    private let tokenStore: TokenStore
    private let session: URLSession

    public init(host: URL, tokenStore: TokenStore, session: URLSession = .shared) {
        self.host = host
        self.tokenStore = tokenStore
        self.session = session
    }

    /// Submit the user's response to a pending elicitation. `content`
    /// may be nil for decline/cancel actions; for accept it's the JSON
    /// payload matching the elicitation's RequestedSchema (e.g.
    /// `{"api_key":"sk-..."}`).
    public func respond(
        conversationID: String,
        elicitationID: String,
        action: SpaltElicitAction,
        content: Data? = nil
    ) async throws {
        let url = host
            .appendingPathComponent("conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("elicitations")
            .appendingPathComponent(elicitationID)
            .appendingPathComponent("respond")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try tokenStore.load(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Server expects `{action: "...", content?: {...}}` — match
        // elicit.Response on the Go side. content is optional and
        // emitted only for accept.
        var body: [String: Any] = ["action": action.rawValue]
        if let content, action == .accept {
            if let obj = try? JSONSerialization.jsonObject(with: content) {
                body["content"] = obj
            }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SpaltElicitationError.transport(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200, 204:
            return
        case 401:
            throw SpaltElicitationError.unauthorized
        case 404:
            // Elicitation already drained or never existed — treat
            // as a soft "too late." Callers usually want to clear
            // their local pending entry regardless.
            throw SpaltElicitationError.notFound
        default:
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            throw SpaltElicitationError.serverError(status: http.statusCode, body: msg)
        }
    }
}

public enum SpaltElicitationError: Error, Sendable {
    case transport(Error)
    case unauthorized
    case notFound
    case serverError(status: Int, body: String)
}
