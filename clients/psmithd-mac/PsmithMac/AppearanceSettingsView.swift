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
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                switch section {
                case .theme:
                    textSizePane
                    themePane
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Text size

    private var textSizePane: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Text size")
                    .scaledFont(.title2, weight: .semibold)
                Text("Scales every label, message, and control in the app. Cmd-plus and Cmd-minus work anywhere; Cmd-0 resets.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Theme")
                    .scaledFont(.title2, weight: .semibold)
                Text("Picks the accent color, message-bubble tint, and selection highlight. Light/dark mode follows your system setting.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

// `ThemeCard` extracted to PsmithUI/Composite/ThemeCard.swift for iOS
// reuse. The Mac call site uses the same init shape.
#if false
private struct ThemeCard_Legacy: View {
    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(theme.name)
                            .scaledFont(.headline)
                            .foregroundStyle(.primary)
                        Text(theme.blurb)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .scaledFont(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                }

                bubblePreview

                swatchRow
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.chrome)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.primary.opacity(0.10)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var bubblePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            previewBubble(text: "What's the capital of Japan?", role: .user)
            previewBubble(text: "Tokyo.", role: .assistant)
        }
    }

    private enum PreviewRole { case user, assistant }

    @ViewBuilder
    private func previewBubble(text: String, role: PreviewRole) -> some View {
        Text(text)
            .scaledFont(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(role == .user
                          ? AnyShapeStyle(theme.bubbleTint.opacity(0.18))
                          : AnyShapeStyle(Color.primary.opacity(0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    private var swatchRow: some View {
        HStack(spacing: 6) {
            swatch(theme.accent,    label: "accent")
            swatch(theme.bubbleTint,label: "bubble")
            swatch(theme.highlight, label: "highlight")
            swatch(theme.chrome,    label: "chrome")
        }
    }

    private func swatch(_ color: Color, label: String) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .frame(height: 22)
            Text(label)
                .scaledFont(size: 9)
                .foregroundStyle(.tertiary)
        }
    }
}
#endif
