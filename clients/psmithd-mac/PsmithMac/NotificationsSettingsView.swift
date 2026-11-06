import SwiftUI
import PsmithUI

/// Detail content for `SettingsCategory.notifications`. One section per
/// `NotificationsSection`; today that's generation finished.
struct NotificationsSettingsView: View {
    let section: NotificationsSection
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        @Bindable var p = prefs
        SettingsPage(
            title: "Notifications",
            subtitle: "What Psmith tells you about while you're in another app. Stored on this Mac; not synced."
        ) {
            switch section {
            case .generationFinished:
                SettingsSection(title: "Generation finished") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $p.notifyOnUnfocusedCompletion) {
                            Text("Notify when a reply finishes")
                        }
                        .toggleStyle(.switch)
                        Text("Posts a notification when a reply completes while Psmith is in the background. Nothing posts while Psmith is the active app; you're already looking at the result. macOS asks for permission the first time one would post.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
