import SwiftUI

/// Detail-column content for `SettingsCategory.notifications`. Houses
/// every Reeve preference that controls when / how the OS notification
/// center is invoked. Today: a single toggle for the
/// generation-completed notification; room for future toggles
/// (per-conversation mute, sound override, …) as those needs land.
struct NotificationsSettingsView: View {
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                generationFinishSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notifications")
                .font(.title2.weight(.semibold))
            Text("Controls when Reeve posts macOS notifications. Stored locally on this Mac; not synced.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var generationFinishSection: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 8) {
            Text("Generation finished")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Toggle(isOn: $p.notifyOnUnfocusedCompletion) {
                Text("Ring on generation finish")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("Posts a macOS notification when an assistant turn completes while Reeve is in the background. Suppressed when Reeve is the active app — you're already looking at the result. Permission is requested the first time a notification would fire.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
