import SwiftUI
import PsmithUI

/// Detail-column content for `SettingsCategory.appearance`. Renders a grid
/// of theme cards; clicking a card swaps the active palette immediately and
/// persists the choice via ThemeStore. Each card carries a mini-bubble
/// preview so the user can see how the palette feels before committing.
struct AppearanceSettingsView: View {
    let section: AppearanceSection
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "How the app looks and how much it shows. Stored on this Mac.",
            maxWidth: 900
        ) {
            switch section {
            case .theme:
                SettingsSection(title: "Text size") { textSizePane }
                SettingsSection(title: "Transcript") { turnDetailsPane }
                SettingsSection(title: "Theme", card: false) { themePane }
            }
        }
    }

    // MARK: - Turn details

    private var turnDetailsPane: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Show turn details", isOn: $prefs.showTurnDetails)
                .toggleStyle(.switch)
            Text("Role labels, the model on every reply, token counts and times, inline in the transcript. Off, the transcript keeps only what's worth noticing: a model change, a poor cache on a large prompt, a reply that stopped early. The details are always one click away under a reply's info button.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Text size

    private var textSizePane: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 10) {
            Text("Scales every label, message, and control in the app. ⌘+ and ⌘− work anywhere; ⌘0 resets.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                // The two "A"s stay deliberately UNscaled — they label
                // the slider's range, not the current size.
                Text("A")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(
                    value: $prefs.fontScale,
                    in: AppPreferences.minFontScale...AppPreferences.maxFontScale,
                    step: AppPreferences.fontScaleStep
                )
                .frame(maxWidth: 320)
                Text("A")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", prefs.fontScale * 100))
                    .scaledFont(.callout, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                if prefs.fontScale != 1.0 {
                    Button("Reset") { prefs.fontScale = 1.0 }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Theme

    private var themePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sets the accent color, your message bubbles, the selection highlight, the window's tint, and the app icon. Light and dark follow your system setting.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(Theme.allThemes) { theme in
                    ThemeCard(
                        theme: theme,
                        isSelected: themeStore.current.id == theme.id,
                        onSelect: { themeStore.current = theme }
                    )
                }
            }
        }
    }

}
