import SwiftUI

/// Detail-column content for `SettingsCategory.general`. App-wide
/// preferences that don't belong to any single conversation / profile /
/// provider: font scale, notification toggle, future global toggles.
/// Backed by AppPreferences (UserDefaults under the hood).
struct GeneralSettingsView: View {
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                section("Appearance") {
                    fontScaleRow
                }

                section("Notifications") {
                    notificationsRow
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("General")
                .font(.title2.weight(.semibold))
            Text("App-wide preferences. Stored locally on this Mac; not synced.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            body()
        }
    }

    @ViewBuilder
    private var fontScaleRow: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Font size")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(prefs.fontScaleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(prefs.fontScaleIndex) },
                    set: { prefs.fontScaleIndex = Int($0.rounded()) }
                ),
                in: 0...Double(AppPreferences.dynamicTypeStops.count - 1),
                step: 1
            ) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Text("Scales every SwiftUI semantic font (.body, .callout, .caption, …) across the app. Takes effect immediately.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var notificationsRow: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 6) {
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
