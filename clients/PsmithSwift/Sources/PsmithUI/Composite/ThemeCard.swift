import SwiftUI

/// Single theme tile. Top: name + blurb + selected check. Middle:
/// preview row with the two mock chat bubbles tinted in the theme's
/// accent. Bottom: four colored swatches showing accent / bubble tint
/// / highlight / chrome so the user can read the palette at a glance.
public struct ThemeCard: View {
    let theme: Theme
    let isSelected: Bool
    let onSelect: () -> Void

    public init(theme: Theme, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.theme = theme
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
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
