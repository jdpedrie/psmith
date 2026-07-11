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
    @Environment(\.theme) private var theme
    @Environment(\.chatPaneWidth) private var paneWidth

    public init(text: String, badge: String? = nil) {
        self.text = text
        self.badge = badge
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
                Text("USER")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(0.7)
    }
}
