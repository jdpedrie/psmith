import Foundation
import Connect
import SwiftProtobuf

/// Server-side catalog metadata for a single device tool. Mirrors
/// `Spalt_V1_SupportedTool`. Settings UI uses this to render per-
/// tool documentation; the dispatcher uses `name` as the handler
/// key.
public struct SpaltSupportedTool: Sendable, Hashable {
    public let name: String
    public let displayName: String
    public let description: String
    /// JSON Schema bytes. Empty if the tool takes no input.
    public let inputSchema: Data
    public let category: String
    public let requiredPermissions: [String]

    init(from p: Spalt_V1_SupportedTool) {
        name = p.name
        displayName = p.displayName
        description = p.description_p
        inputSchema = p.inputSchema
        category = p.category
        requiredPermissions = p.requiredPermissions
    }
}

/// Repository over DeviceToolsService (capability registration +
/// catalog fetch) plus the plain HTTP `respond` endpoint that
/// matches the server's broker. Three surfaces because the
/// capability handshake and the response post are physically
/// different transports (Connect for one, vanilla HTTP for the
/// other).
public final class DeviceToolsRepository: Sendable {
    private let client: Spalt_V1_DeviceToolsServiceClientInterface
    private let host: URL
    private let tokenStore: TokenStore
    private let session: URLSession

    public init(
        client: Spalt_V1_DeviceToolsServiceClientInterface,
        host: URL,
        tokenStore: TokenStore,
        session: URLSession = .shared
    ) {
        self.client = client
        self.host = host
        self.tokenStore = tokenStore
        self.session = session
    }

    /// Announce the set of tool names the connected device can
    /// fulfill right now (OS permission granted + dependencies
    /// satisfied). Called once per StreamSubscriber connection.
    /// Idempotent — the server replaces the previous set.
    public func registerCapabilities(
        supportedToolNames: [String],
        attributes: [String: String] = [:]
    ) async throws {
        var req = Spalt_V1_RegisterCapabilitiesRequest()
        req.supportedToolNames = supportedToolNames
        req.clientAttributes = attributes.filter { !$0.value.isEmpty }
        let resp = await client.registerCapabilities(request: req, headers: [:])
        if let err = resp.error { throw SpaltError.from(err) }
    }

    /// Fetch the server's full device-tool catalog. The dispatcher
    /// doesn't need this for execution (it dispatches by tool name
    /// alone), but the settings UI consumes the rich metadata
    /// (display name, description, required permissions, JSON
    /// schema) to render per-tool toggle rows.
    public func listSupportedTools() async throws -> [SpaltSupportedTool] {
        let resp = await client.listSupportedTools(
            request: Spalt_V1_ListSupportedToolsRequest(), headers: [:])
        if let err = resp.error { throw SpaltError.from(err) }
        let tools = resp.message?.tools ?? []
        return tools.map(SpaltSupportedTool.init(from:))
    }

    /// POST a device-tool result back to the server. Mirrors the
    /// elicit `respond` shape — same auth, same convo-ownership
    /// check server-side. Either `output` or `errorMessage` must
    /// be non-nil; the server rejects an empty response.
    public func respond(
        conversationID: String,
        callID: String,
        output: Data?,
        errorMessage: String?
    ) async throws {
        let url = host
            .appendingPathComponent("conversations")
            .appendingPathComponent(conversationID)
            .appendingPathComponent("device-tools")
            .appendingPathComponent(callID)
            .appendingPathComponent("respond")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try tokenStore.load(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [:]
        if let output, !output.isEmpty {
            if let obj = try? JSONSerialization.jsonObject(with: output) {
                body["output"] = obj
            } else {
                // Caller passed bytes that aren't JSON-decodable —
                // wrap as a string so the server still gets something
                // intelligible. Shouldn't happen with handlers that
                // encode Codable responses, but defensive.
                body["output"] = String(data: output, encoding: .utf8) ?? ""
            }
        }
        if let errorMessage, !errorMessage.isEmpty {
            body["error"] = errorMessage
        }
        if body.isEmpty {
            throw DeviceToolsError.emptyResponse
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DeviceToolsError.transport(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200, 204: return
        case 401: throw DeviceToolsError.unauthorized
        case 404:
            // Call already drained or never existed — soft failure;
            // the model will have moved on by now.
            throw DeviceToolsError.notFound
        default:
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            throw DeviceToolsError.serverError(status: http.statusCode, body: msg)
        }
    }
}

public enum DeviceToolsError: Error, Sendable {
    case transport(Error)
    case unauthorized
    case notFound
    case serverError(status: Int, body: String)
    case emptyResponse
}

/// One audit-log row. Mirrors `Spalt_V1_DeviceToolCall`. Used by
/// the Settings → Device tool activity scroll on iOS.
public struct SpaltDeviceToolCall: Sendable, Hashable, Identifiable {
    public let id: String
    public let conversationID: String
    public let messageID: String?
    public let toolName: String
    /// Raw input + output JSON bytes; the UI pretty-prints in the
    /// expanded row. Empty data when the call errored / timed out.
    public let inputJSON: Data
    public let outputJSON: Data
    public let status: String         // "ok" | "error" | "timeout"
    public let errorMessage: String
    public let invokedAt: Date
    public let completedAt: Date

    init(from p: Spalt_V1_DeviceToolCall) {
        id = p.id
        conversationID = p.conversationID
        messageID = p.hasMessageID ? p.messageID : nil
        toolName = p.toolName
        inputJSON = p.inputJson
        outputJSON = p.outputJson
        status = p.status
        errorMessage = p.errorMessage
        invokedAt = p.hasInvokedAt ? p.invokedAt.date : .distantPast
        completedAt = p.hasCompletedAt ? p.completedAt.date : .distantPast
    }
}

public extension DeviceToolsRepository {
    /// Recent-first paginated list of the calling user's device-
    /// tool calls. Pass the `invokedAt` of the previous page's
    /// last entry as `before` to fetch the next page.
    func listCalls(
        before: Date? = nil,
        limit: Int32 = 50,
        conversationID: String? = nil
    ) async throws -> [SpaltDeviceToolCall] {
        var req = Spalt_V1_ListDeviceToolCallsRequest()
        if let before {
            req.before = Google_Protobuf_Timestamp(date: before)
        }
        req.limit = limit
        if let conversationID, !conversationID.isEmpty {
            req.conversationID = conversationID
        }
        let resp = await client.listDeviceToolCalls(request: req, headers: [:])
        if let err = resp.error { throw SpaltError.from(err) }
        return (resp.message?.calls ?? []).map(SpaltDeviceToolCall.init(from:))
    }
}
