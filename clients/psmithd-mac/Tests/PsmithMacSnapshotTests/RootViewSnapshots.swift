import Testing
import SwiftUI
@testable import PsmithMac
import PsmithKit
import SnapshotHarness

/// RootView is the top-level auth gate — it renders an interstitial when
/// the on-disk session is still being validated (`.resolving`), LoginView
/// when `.signedOut`, and HomeView when `.signedIn`. Snapshots verify the
/// gate routes to the right child; the downstream visual content is
/// covered by `LoginViewSnapshots` and `HomeViewSnapshots`.
@MainActor
struct RootViewSnapshots {

    @Test
    func loggedOut() {
        let env = SnapshotEnvironment.standard()
        // Standard env starts in `.resolving` (post-launch, pre-bootstrap).
        // Call clear() to land in `.signedOut` so this snapshot reflects
        // the LoginView path, not the resolving spinner.
        env.app.authState.clear()
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { RootView() }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    @Test
    func loggedIn() {
        let env = SnapshotEnvironment.standard()
        env.app.authState.setAuthenticated(SnapshotFixtures.user())
        let view = PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { RootView() }
        assertViewSnapshots(view, sizes: defaultSizes)
    }
}
