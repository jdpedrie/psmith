import SwiftUI

/// Detail-column content for `SettingsCategory.appearance`. Renders a grid
/// of theme cards; clicking a card swaps the active palette immediately and
/// persists the choice via ThemeStore. Each card carries a mini-bubble
/// preview so the user can see how the palette feels before committing.
struct AppearanceSettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                themeSection
                Divider()
                fontSizeSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Appearance")
                .font(.title2.weight(.semibold))
            Text("Theme + typography. Stored locally on this Mac; not synced.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("Picks the accent color, message-bubble tint, and selection highlight. Light/dark mode follows your system setting.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private var fontSizeSection: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 8) {
            Text("Font size")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack {
                Text("App-wide font scale")
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
}

/// Single theme tile. Top: name + blurb + selected check. Middle: preview
/// row with the three mock chat bubbles tinted in the theme's accent.
/// Bottom: four colored swatches showing accent / bubble tint / highlight /
/// chrome so the user can read the palette at a glance.
private struct ThemeCard: View {
    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(theme.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(theme.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
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
            .font(.caption)
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
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}
