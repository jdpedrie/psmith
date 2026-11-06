import SwiftUI

/// Optimistic user message bubble shown while the send RPC is in
/// flight. Right-aligned + width-capped exactly like the materialised
/// `MessageRow` — without the role-aligned wrap, the in-flight bubble
/// pops out as a full-width strip the moment between send-click and the
/// RPC return, which reads as visually jarring.
///
/// Renders identically on Mac and iOS; the spinner in the header signals
/// "still in flight" and the 0.7 opacity reinforces it.
public struct PendingUserRow: View {
    let text: String
    /// Optional label rendered next to the spinner — "Queued" for
    /// offline-queue entries, nil for in-flight sends.
    let badge: String?
    let style: Style
    @Environment(\.theme) private var theme

    public enum Style: Sendable {
        /// Role label, material-washed tint: the Mac transcript's bubble.
        case classic
        /// No role label, the themed fill: matches the iOS transcript's
        /// user bubble, so the row doesn't change look when it lands.
        case themed
    }
    @Environment(\.chatPaneWidth) private var paneWidth

    public init(text: String, badge: String? = nil, style: Style = .classic) {
        self.text = text
        self.badge = badge
        self.style = style
    }

    public var body: some View {
        let cap: CGFloat = paneWidth > 0 ? paneWidth * 0.85 : 720
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            bubble
                .frame(maxWidth: cap, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if style == .classic {
                    Text("USER")
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                ProgressView().controlSize(.mini)
                if let badge {
                    Text(badge)
                        .scaledFont(.caption2, weight: .medium)
                        .foregroundStyle(.orange)
                }
            }
            MarkdownText(text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background { fill }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(0.7)
    }

    @ViewBuilder
    private var fill: some View {
        switch style {
        case .classic:
            RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
                .background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        case .themed:
            ThemedUserBubbleBackground(cornerRadius: 10)
        }
    }
}
