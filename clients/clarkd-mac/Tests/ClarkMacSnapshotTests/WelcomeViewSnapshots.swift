import Testing
import SwiftUI
@testable import ClarkMac
import ClarkKit
import SnapshotHarness

/// Welcome detail-pane snapshots. Two states:
///   - canCreate (a non-parentOnly profile exists) → New Conversation button enabled
///   - cannotCreate (only parentOnly profiles, or none) → button disabled, alt copy
///
/// Rendered at default + minColumn so we catch both the "main view" layout
/// and the narrow detail-column case (when the user has dragged the
/// sidebar wide).
@MainActor
struct WelcomeViewSnapshots {

    @Test
    func welcomeCanCreate() {
        let env = SnapshotEnvironment.standard(
            profiles: [SnapshotFixtures.profile()]
        )
        let view = ClarkMacEnvironment(
            app: env.app,
            convos: env.convos,
            navigator: env.navigator,
            windowState: env.windowState
        ) { WelcomeView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }

    @Test
    func welcomeCannotCreate() {
        let env = SnapshotEnvironment.standard(
            profiles: [SnapshotFixtures.parentOnlyProfile()]
        )
        let view = ClarkMacEnvironment(
            app: env.app,
            convos: env.convos,
            navigator: env.navigator,
            windowState: env.windowState
        ) { WelcomeView() }
        assertViewSnapshots(view, sizes: columnSizes)
    }
}
