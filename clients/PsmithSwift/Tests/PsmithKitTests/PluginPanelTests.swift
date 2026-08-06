import Connect
import Foundation
import Testing

@testable import PsmithKit
import PsmithKitTestHarness

/// Layer 1 coverage for plugin panels against a real psmithd.
///
/// The property under test is that a client can drive a plugin it knows
/// nothing about: it discovers the panel from a descriptor, renders whatever
/// fragments come back, and sends actions it never had to understand.
@Suite("PluginPanels", .serialized)
struct PluginPanelTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    private static let packs = """
    {"packs":[
      {"id":"runbook","name":"Deploy runbook","description":"Release steps","body":"RUNBOOK BODY"},
      {"id":"schema","name":"Schema notes","description":"Table layout","body":"SCHEMA BODY"}
    ]}
    """

    /// Creates a profile carrying context_packs and a conversation on it.
    private func packConversation(_ client: PsmithClient, prefix: String) async throws -> String {
        let patch = Fixtures.minimalProfilePatch(name: "Packs \(prefix)")
        let profile = try await client.profiles.create(patch)
        _ = try await client.profiles.setProfilePlugins(
            profileID: profile.id,
            plugins: [
                PsmithProfilePlugin(
                    pluginName: "context_packs",
                    ordinal: 0,
                    config: Data(Self.packs.utf8),
                    disabled: false
                )
            ]
        )
        let convo = try await client.conversations.create(profileID: profile.id, title: "Packs")
        return convo.id
    }

    @Test("a plugin's panel is discoverable from its descriptor")
    func panelIsDiscoverable() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "panel-desc")

        let types = try await client.profiles.listPluginTypes()
        let packs = try #require(types.first { $0.name == "context_packs" })

        // This is what lets a client build the menu without knowing any plugin
        // by name: filter on having a panel, show the title you are given.
        let panel = try #require(packs.panel, "context_packs should contribute a panel")
        #expect(!panel.title.isEmpty)
        #expect(packs.capabilities.panelProvider)
    }

    @Test("the panel renders as fragments the client already knows")
    func panelRendersFragments() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "panel-body")
        let convoID = try await packConversation(client, prefix: "body")

        let fragments = try await client.conversations.pluginPanel(
            conversationID: convoID,
            pluginName: "context_packs"
        )
        #expect(fragments.count == 1)
        // card_list is an existing component: no new renderer shipped for this.
        #expect(fragments.first?.component == "card_list")

        let props = String(decoding: fragments.first?.props ?? Data(), as: UTF8.self)
        #expect(props.contains("Deploy runbook"))
        // The bodies are the thing being deferred; shipping them to the client
        // would defeat the feature and leak the payload early.
        #expect(!props.contains("RUNBOOK BODY"))
    }

    @Test("an action round-trips and returns the updated panel")
    func actionUpdatesPanel() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "panel-action")
        let convoID = try await packConversation(client, prefix: "action")

        let after = try await client.conversations.invokePluginAction(
            conversationID: convoID,
            pluginName: "context_packs",
            action: "arm",
            params: ["id": "runbook"]
        )
        let props = String(decoding: after.first?.props ?? Data(), as: UTF8.self)
        // One round trip: the response IS the new panel, so the sheet never
        // shows stale state while a second fetch is in flight.
        #expect(props.contains("Sends next"))
    }

    /// Arming has to work on a conversation with no messages — that is exactly
    /// when a user queues context, before typing anything.
    @Test("a pack can be armed before the first message")
    func armWorksOnEmptyConversation() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "panel-empty")
        let convoID = try await packConversation(client, prefix: "empty")

        let after = try await client.conversations.invokePluginAction(
            conversationID: convoID,
            pluginName: "context_packs",
            action: "arm",
            params: ["id": "runbook"]
        )
        #expect(!after.isEmpty)
        let props = String(decoding: after.first?.props ?? Data(), as: UTF8.self)
        #expect(props.contains("Sends next"))
    }

    @Test("a plugin not on the conversation has no reachable panel")
    func inactivePluginRejected() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "panel-inactive")
        let convoID = try await packConversation(client, prefix: "inactive")

        await #expect(throws: (any Error).self) {
            _ = try await client.conversations.pluginPanel(
                conversationID: convoID,
                pluginName: "brave_search"
            )
        }
    }
}
