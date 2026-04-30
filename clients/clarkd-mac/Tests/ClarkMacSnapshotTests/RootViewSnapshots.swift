import Testing
import SwiftUI
@testable import ClarkMac
import ClarkKit
import SnapshotHarness

/// RootView is the top-level auth gate — it renders LoginView when
/// `app.authState.isAuthenticated == false` and HomeView when true. These
/// snapshots verify the gate routes correctly. The downstream visual
/// differences are covered by `LoginViewSnapshots` and `HomeViewSnapshots`,
/// so we just need to confirm Root forwards to the right child.
@MainActor
struct RootViewSnapshots {

    @Test
    func loggedOut() {
        let env = SnapshotEnvironment.standard()
        // Default standard env has authState in its initial (logged-out) state.
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { RootView() }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    @Test
    func loggedIn() {
        let env = SnapshotEnvironment.standard()
        env.app.authState.setAuthenticated(SnapshotFixtures.user())
        let view = ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { RootView() }
        assertViewSnapshots(view, sizes: defaultSizes)
    }
}
