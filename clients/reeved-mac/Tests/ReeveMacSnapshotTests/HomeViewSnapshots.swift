import Testing
import SwiftUI
@testable import ReeveMac
import ReeveKit
import SnapshotHarness

/// HomeView is the chats / settings shell. These snapshots capture the
/// four scenes the user actually toggles between, plus a settings-mode
/// snapshot at minWindow size to catch column-clipping in SettingsView's
/// HSplitView.
@MainActor
struct HomeViewSnapshots {

    // MARK: - Chats mode

    @Test
    func chatsNothingSelected() {
        let env = SnapshotEnvironment.standard()
        let view = ReeveMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { HomeView(user: SnapshotFixtures.user()) }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    @Test
    func chatsConversationSelected() {
        let convos = SnapshotFixtures.conversations()
        let env = SnapshotEnvironment.standard(
            conversations: convos,
            selectedID: convos.first?.id
        )
        let view = ReeveMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { HomeView(user: SnapshotFixtures.user()) }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    @Test
    func chatsComposingNew() {
        let env = SnapshotEnvironment.standard(composing: true)
        let view = ReeveMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { HomeView(user: SnapshotFixtures.user()) }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    // MARK: - Settings mode

    @Test
    func settingsMode() {
        let env = SnapshotEnvironment.standard(navMode: .settings)
        let view = ReeveMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { HomeView(user: SnapshotFixtures.user()) }
        assertViewSnapshots(view, sizes: defaultSizes)
    }
}
