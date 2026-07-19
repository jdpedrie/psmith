import Foundation
import Testing
import Connect
@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 tests for the MCP server registry: repository round-trip,
/// secret withholding, and the pseudo-plugin surfacing in the plugin
/// type list that the pickers render from.
@Suite("MCPServersViewModel", .serialized)
@MainActor
struct MCPServersViewModelTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    @Test("create, list, update keeping secrets, delete")
    func crudRoundTrip() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mcp-crud")
        let vm = MCPServersViewModel(client: client)

        await vm.load()
        #expect(vm.servers.isEmpty)

        let created = await vm.upsert(
            id: nil,
            name: "Firecrawl",
            transport: "http",
            url: "https://mcp.firecrawl.test/rpc",
            headers: "Authorization: Bearer fc-secret"
        )
        let server = try #require(created)
        #expect(!server.id.isEmpty)
        #expect(server.hasHeaders)
        #expect(server.pluginRefName == "mcp:" + server.id)

        // Save again with headers nil (the edit form never echoes
        // secrets) — stored value must survive.
        let updated = await vm.upsert(
            id: server.id,
            name: "Firecrawl EU",
            transport: "http",
            url: "https://mcp.firecrawl.test/eu"
        )
        #expect(updated?.name == "Firecrawl EU")
        #expect(updated?.hasHeaders == true)

        await vm.load()
        #expect(vm.servers.count == 1)
        #expect(vm.servers.first?.name == "Firecrawl EU")

        #expect(await vm.delete(id: server.id))
        #expect(vm.servers.isEmpty)
    }

    @Test("duplicate name surfaces an error, not a silent failure")
    func duplicateName() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mcp-dup")
        let vm = MCPServersViewModel(client: client)

        _ = await vm.upsert(id: nil, name: "Same", transport: "inproc")
        let second = await vm.upsert(id: nil, name: "Same", transport: "inproc")
        #expect(second == nil)
        #expect(vm.error != nil)
        #expect(vm.servers.count == 1)
    }

    @Test("registered server appears as a pseudo-plugin in the picker list")
    func pseudoPluginSurfaces() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "mcp-pseudo")
        let vm = MCPServersViewModel(client: client)
        let created = await vm.upsert(
            id: nil, name: "Firecrawl", transport: "http",
            url: "https://mcp.firecrawl.test/rpc"
        )
        let server = try #require(created)

        let types = try await client.profiles.listPluginTypes()
        let pseudo = try #require(types.first { $0.name == server.pluginRefName })
        #expect(pseudo.displayName == "Firecrawl")
        #expect(pseudo.capabilities.toolProvider)
        #expect(pseudo.configFields.map(\.name) == ["tool_prefix"])
    }
}
