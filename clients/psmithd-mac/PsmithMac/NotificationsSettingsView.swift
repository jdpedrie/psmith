import SwiftUI
import PsmithUI

/// Detail-column content for `SettingsCategory.notifications`. Renders the
/// pane for whichever sub-section the middle column currently has selected
/// (today: just `.generationFinished`, but the shape is set up so future
/// notification toggles slot in as new `NotificationsSection` cases without
/// having to restructure the view).
struct NotificationsSettingsView: View {
    let section: NotificationsSection
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch section {
                case .generationFinished: generationFinishedPane
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var generationFinishedPane: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Generation finished")
                    .font(.title2.weight(.semibold))
                Text("Posts a macOS notification when an assistant turn completes while Psmith is in the background. Suppressed when Psmith is the active app — you're already looking at the result. Permission is requested the first time a notification would fire. Stored locally on this Mac; not synced.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $p.notifyOnUnfocusedCompletion) {
                Text("Ring on generation finish")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}
