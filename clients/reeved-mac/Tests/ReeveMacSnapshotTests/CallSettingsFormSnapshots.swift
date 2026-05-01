import Testing
import SwiftUI
@testable import ReeveMac
import ReeveKit
import SnapshotHarness

/// `CallSettingsForm` is the shared call-settings editor reused across the
/// provider-defaults tab, model gear popover, profile form, new-conversation
/// form, and in-conversation settings page. The driver-specific sections
/// (Anthropic / OpenAI / Google extras) and capability gating (Thinking
/// section) are the variant axes that must keep rendering correctly across
/// all entry points.
///
/// Snapshotted at `default` and `minColumn` widths. The `minColumn`
/// variant is critical — segmented `Picker`s inside the form historically
/// clipped leading characters when the host column went narrow (the
/// "GeometryReader-pin" bug). Catch any regression of that class here.
@MainActor
struct CallSettingsFormSnapshots {

    // MARK: - Wrapper

    /// Wraps `CallSettingsForm` with a `@State` binding so SwiftUI can
    /// drive its segmented pickers + sliders against a stable initial
    /// value. The form expects a non-empty padded container and a
    /// vertical scroll path; we simulate that with a ScrollView wrapper
    /// matching the production callsites.
    private struct Wrapper: View {
        @State var settings: ReeveCallSettings
        let inheritedSettings: ReeveCallSettings?
        let driverType: String
        let modelCapabilities: ReeveModelCapabilities?

        init(
            settings: ReeveCallSettings = ReeveCallSettings(),
            inheritedSettings: ReeveCallSettings? = nil,
            driverType: String,
            modelCapabilities: ReeveModelCapabilities? = SnapshotFixtures.capabilitiesAllOn()
        ) {
            self._settings = State(initialValue: settings)
            self.inheritedSettings = inheritedSettings
            self.driverType = driverType
            self.modelCapabilities = modelCapabilities
        }

        var body: some View {
            ScrollView {
                CallSettingsForm(
                    settings: $settings,
                    inheritedSettings: inheritedSettings,
                    driverType: driverType,
                    modelCapabilities: modelCapabilities
                )
                .padding(20)
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Driver variants

    /// Anthropic driver — Anthropic extras section visible (cache enabled,
    /// cache TTL); OpenAI / Google sections hidden. Top K row visible
    /// because Anthropic is one of the two TopK-supporting drivers.
    /// Thinking section visible because the model capability is on.
    @Test
    func anthropicDriver() {
        let view = Wrapper(driverType: "anthropic")
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// OpenAI-compatible driver — OpenAI extras section visible (seed,
    /// penalties, logprobs, parallel tool calls, service tier, response
    /// format, logit bias). Anthropic / Google sections hidden. No Top K
    /// row (driver doesn't expose it).
    @Test
    func openaiCompatibleDriver() {
        let view = Wrapper(driverType: "openai-compatible")
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// Google driver — Google extras section visible (safety settings,
    /// response MIME, response schema, candidate count). Anthropic /
    /// OpenAI sections hidden. Top K row visible (Google is a TopK
    /// driver).
    @Test
    func googleDriver() {
        let view = Wrapper(driverType: "google")
        assertViewSnapshots(view, sizes: columnSizes)
    }

    // MARK: - Inheritance + capability gating

    /// Inherited chips visible — the form has `inheritedSettings`
    /// non-nil and the user's own `settings` is empty, so every row
    /// shows its "Inherits …" hint instead of an active value.
    @Test
    func anthropicWithInheritedChips() {
        let view = Wrapper(
            settings: ReeveCallSettings(),
            inheritedSettings: SnapshotFixtures.commonInheritedCallSettings(),
            driverType: "anthropic"
        )
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// Capability-gated thinking — model reports `thinking: false` so the
    /// Thinking section is hidden even though the Anthropic driver
    /// would otherwise translate it. Verifies the gate path through
    /// `showsThinking`.
    @Test
    func capabilityGatedNoThinking() {
        let view = Wrapper(
            driverType: "anthropic",
            modelCapabilities: SnapshotFixtures.capabilitiesNoThinking()
        )
        assertViewSnapshots(view, sizes: columnSizes)
    }
}
