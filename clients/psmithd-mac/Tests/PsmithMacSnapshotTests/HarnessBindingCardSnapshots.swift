import PsmithKit
import PsmithUI
import SnapshotHarness
import SwiftUI
import Testing

/// `HarnessBindingCard` is prose whose whole job is to make three restrictions
/// feel like a property of the tool rather than a fault. That makes it a
/// wrapping risk first and foremost: every line is a full sentence composed
/// around a provider label the user chose, so a long label or a narrow column
/// is where it breaks.
///
/// Snapshotted at `minColumn` as well as default because the card lives at the
/// top of the conversation settings pane, which is the narrowest place it can
/// appear.
@MainActor
struct HarnessBindingCardSnapshots {

    /// The card carries its own accent-tinted fill, which only reads correctly
    /// over the pane it sits on. The harness renders dark with no backdrop, so
    /// without this the baseline would be light text on a light wash: unreadable,
    /// and worse, unable to catch a real contrast regression because it starts
    /// broken.
    private func onPane(_ card: HarnessBindingCard) -> some View {
        card
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func binding(
        label: String,
        driver: String = "codex-app-server",
        frozenPrompt: Bool = true,
        attachments: Bool = false
    ) -> PsmithHarnessBinding {
        PsmithHarnessBinding(
            providerID: "prov-1",
            providerLabel: label,
            driverType: driver,
            systemPromptFrozen: frozenPrompt,
            acceptsAttachments: attachments
        )
    }

    @Test("every constraint, ordinary label")
    func allConstraints() {
        assertViewSnapshots(
            onPane(HarnessBindingCard(binding: binding(label: "Codex"))),
            sizes: columnSizes
        )
    }

    /// Labels are user-supplied and people write long ones. The card must wrap
    /// rather than clip: it names the provider four times.
    @Test("a long provider label wraps rather than clips")
    func longLabel() {
        assertViewSnapshots(
            onPane(HarnessBindingCard(
                binding: binding(label: "Claude Code on the work laptop (staging credentials)",
                                 driver: "claude-code-subprocess")
            )),
            sizes: columnSizes
        )
    }

    /// A harness that grows file support drops one bullet. Pinned so the card
    /// is checked for what it looks like with a hole in the middle, not only
    /// in its full form.
    @Test("a harness that accepts attachments drops that constraint")
    func attachmentsAllowed() {
        assertViewSnapshots(
            onPane(HarnessBindingCard(binding: binding(label: "Codex", attachments: true))),
            sizes: columnSizes
        )
    }
}
