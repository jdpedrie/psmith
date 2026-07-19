import Foundation

/// One registered MCP server from the user-level registry. Registered
/// once in Settings; surfaces as a pseudo-plugin ("mcp:<id>") in every
/// plugin picker via ListPluginTypes. Secret-bearing fields (env,
/// headers) never cross the wire — `hasEnv` / `hasHeaders` say whether
/// a stored value exists so edit forms can hint "set; leave blank to
/// keep".
public struct PsmithMCPServer: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public var name: String
    public var transport: String
    public var command: String
    public var args: String
    public var url: String
    public var toolPrefix: String
    public let hasEnv: Bool
    public let hasHeaders: Bool

    public init(
        id: String,
        name: String,
        transport: String,
        command: String = "",
        args: String = "",
        url: String = "",
        toolPrefix: String = "",
        hasEnv: Bool = false,
        hasHeaders: Bool = false
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.toolPrefix = toolPrefix
        self.hasEnv = hasEnv
        self.hasHeaders = hasHeaders
    }

    init(from proto: Psmith_V1_MCPServer) {
        self.id = proto.id
        self.name = proto.name
        self.transport = proto.transport
        self.command = proto.command
        self.args = proto.args
        self.url = proto.url
        self.toolPrefix = proto.toolPrefix
        self.hasEnv = proto.hasEnv_p
        self.hasHeaders = proto.hasHeaders_p
    }

    /// Pipeline plugin name this server attaches under ("mcp:<id>").
    public var pluginRefName: String { "mcp:" + id }

    /// Secret-free one-liner for list rows.
    public var summary: String {
        switch transport {
        case "http": return "http · " + url
        case "inproc": return "in-process"
        default: return "stdio · " + command
        }
    }
}
