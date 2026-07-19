import Testing
import SwiftUI
@testable import PsmithMac
import PsmithKit
import SnapshotHarness

/// Snapshots for the Settings → MCP Servers detail column: the edit
/// form for an http server (secret hint visible), the stdio variant,
/// the register-new form, and the empty placeholder.
@MainActor
struct MCPServersViewSnapshots {

    private func detail(model: MCPServersViewModel) -> some View {
        let env = SnapshotEnvironment.standard(navMode: .settings)
        return PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            MCPServersDetail(model: model)
        }
    }

    @Test
    func editHTTPServer() {
        let model = SnapshotStubs.makeMCPServersModel()
        assertViewSnapshots(detail(model: model), sizes: columnSizes)
    }

    @Test
    func editStdioServer() {
        let model = SnapshotStubs.makeMCPServersModel(selectedID: "mcp-localfs")
        assertViewSnapshots(detail(model: model), sizes: columnSizes)
    }

    @Test
    func registerNew() {
        let model = SnapshotStubs.makeMCPServersModel(selectedID: nil, isAddingNew: true)
        assertViewSnapshots(detail(model: model), sizes: columnSizes)
    }

    @Test
    func emptyPlaceholder() {
        let model = SnapshotStubs.makeMCPServersModel(servers: [], selectedID: nil)
        assertViewSnapshots(detail(model: model), sizes: columnSizes)
    }
}
