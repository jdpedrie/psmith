import Testing
import SwiftUI
@testable import ReeveMac
import ReeveKit
import SnapshotHarness

/// NewConversationView snapshots. Covers the "no profile" state cleanly via
/// the default-state path (parentOnly profile in fixtures → no chat-capable
/// default selected on appear); the other variants live behind `@State
/// private` fields (`selectedProfileID`, `overrideProviderID`,
/// `overrideModelID`, `conversationCallSettings`) that the view never
/// exposes through init / environment.
///
/// Reaching them from a snapshot test would mean parameterising
/// NewConversationView on those fields — production surgery for relatively
/// modest snapshot value. Document the variants we can't reach and let
/// Layer 3 (XCUITest) catch them once the full app interaction is on a
/// real screen.
@MainActor
struct NewConversationViewSnapshots {

    @Test
    func noProfileSelected() {
        // Only a parent-only profile exists, so `defaultProfileID` resolves
        // to nil and the picker stays empty. The send button is disabled
        // (it gates on selectedProfileID != nil).
        let env = SnapshotEnvironment.standard(
            profiles: [SnapshotFixtures.parentOnlyProfile()],
            composing: true
        )
        let view = ReeveMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { NewConversationView() }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    @Test
    func profileSelectedDefaultModel() {
        // A real profile is loaded; on the view's `.task { … }` it sets
        // `selectedProfileID = defaultProfileID`. Override fields stay nil,
        // so the model picker shows "Inherit from profile" as the active row.
        let env = SnapshotEnvironment.standard(
            profiles: [SnapshotFixtures.profile()],
            composing: true
        )
        let view = ReeveMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { NewConversationView() }
        assertViewSnapshots(view, sizes: defaultSizes)
    }

    // SKIP: profile selected, model overridden — `overrideProviderID/ModelID`
    // are `@State private` on NewConversationView. TODO: Layer 3 (XCUITest).
    //
    // SKIP: Chat Settings expanded with full CallSettingsForm — same; the
    // section is always present in the scroll, but a "filled in"
    // `conversationCallSettings` requires reaching the @State binding.
    // The default snapshot above already exercises the section in its
    // empty (inherit-everywhere) shape.
}
