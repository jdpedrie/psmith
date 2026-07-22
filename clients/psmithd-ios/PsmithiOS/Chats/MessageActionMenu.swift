import SwiftUI
import PsmithKit
import PsmithUI

/// Custom long-press action menu for transcript messages, replacing
/// `.contextMenu` on MessageRow. The system menu's lift animation
/// portals the pressed row into an unflipped window-level container,
/// and inside the inverted transcript (scroll view and row each carry
/// a y-flip) that portal renders the row upside down for the duration
/// of the lift. No public API reaches the portal, so the menu is ours:
/// dimmed backdrop, upright excerpt card, glass action card — no
/// portal anywhere, so the flash cannot occur.
///
/// Presented from ConversationBody via `model.actionMenuMessage`
/// (hoisted like `editingMessage` so the overlay renders OUTSIDE the
/// flipped scroll view). Delete confirmations morph the action card
/// in place instead of stacking a system alert on the overlay — the
/// alert's presentation anchor would be a view mid-dismissal.
struct MessageActionMenu: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    /// Opens the full-document reader (selection lives there — the
    /// transcript disables in-bubble selection so this menu's gesture
    /// can win the long-press; see MessageRow).
    let onSelectText: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.clipboard) private var clipboard

    private enum DeleteConfirm { case single, cascade }
    @State private var confirmingDelete: DeleteConfirm?
    /// Drives the card pop-in. The overlay's insertion transition is a
    /// plain fade (the backdrop scaling with the cards reads wrong);
    /// the cards get their spring here instead.
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Backdrop: dims the transcript and intercepts every touch
            // under the cards. Tap anywhere outside to dismiss.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 12) {
                excerptCard
                actionCard
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 24)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }

    // MARK: - Excerpt card

    /// Upright preview of the pressed message — same excerpt budget the
    /// old context-menu preview used. Head cut, not BoundedMarkdownText:
    /// its "Show full text" affordance would be a live button here and
    /// the card is a preview, not a reader. Height-capped so a huge
    /// message on a small screen can't crowd out the actions.
    private var excerptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(roleLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            let body = message.displayContent ?? message.content
            MarkdownText(MarkdownBudget.head(body, limit: 600) ?? body)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: 300, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Action card

    private var actionCard: some View {
        VStack(spacing: 0) {
            if confirmingDelete == nil {
                actionRows
            } else {
                confirmRows
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .animation(.snappy(duration: 0.2), value: confirmingDelete == nil)
    }

    @ViewBuilder
    private var actionRows: some View {
        row("Edit", systemImage: "pencil", enabled: isEditableRole) {
            dismiss()
            model.editingMessage = message
        }
        if message.role != .user {
            hairline
            row("Reload", systemImage: "arrow.clockwise", enabled: isReloadable) {
                dismiss()
                Task { await model.reloadFromMessage(id: message.id) }
            }
        }
        hairline
        row("Copy", systemImage: "doc.on.doc") {
            clipboard.write(message.displayContent ?? message.content)
            dismiss()
        }
        hairline
        row("Select text", systemImage: "character.cursor.ibeam") {
            dismiss()
            onSelectText()
        }
        if message.role == .assistant && message.errorText == nil {
            hairline
            if app.speech.isPlaying(messageID: message.id) || app.speech.isLoading(messageID: message.id) {
                row("Stop speaking", systemImage: "speaker.slash") { toggleSpeech() }
            } else {
                row("Read aloud", systemImage: "speaker.wave.2", enabled: !model.isStreaming) { toggleSpeech() }
            }
        }
        groupBreak
        row("Delete", systemImage: "trash", destructive: true) {
            confirmingDelete = .single
        }
        if model.hasDescendants(message.id) {
            hairline
            row("Delete from here…", systemImage: "trash.slash", destructive: true) {
                confirmingDelete = .cascade
            }
        }
    }

    /// Delete confirmation, morphed into the card. Copy matches the
    /// alerts this flow replaced.
    @ViewBuilder
    private var confirmRows: some View {
        let cascade = confirmingDelete == .cascade
        VStack(alignment: .leading, spacing: 4) {
            Text(cascade ? "Delete from here?" : "Delete message?")
                .font(.subheadline.weight(.semibold))
            Text(confirmBody(cascade: cascade))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        hairline
        row(
            cascade ? "Delete from here" : "Delete",
            systemImage: cascade ? "trash.slash" : "trash",
            destructive: true
        ) {
            Haptics.notify(.warning)
            let id = message.id
            dismiss()
            Task { await model.deleteMessage(id: id, cascade: cascade) }
        }
        hairline
        row("Cancel", systemImage: "xmark") { confirmingDelete = nil }
    }

    private func confirmBody(cascade: Bool) -> String {
        if cascade {
            let count = model.descendantCount(of: message.id)
            return "This deletes the message and \(count) repl\(count == 1 ? "y" : "ies") underneath it."
        }
        return "This message will be removed. Children stitch to its parent."
    }

    // MARK: - Row chrome

    private func row(
        _ title: String,
        systemImage: String,
        enabled: Bool = true,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Image(systemName: systemImage)
            }
            .font(.body)
            .foregroundStyle(
                !enabled
                    ? AnyShapeStyle(.tertiary)
                    : (destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    /// Thicker band separating the destructive group — the custom-menu
    /// equivalent of UIMenu's chunky section separator.
    private var groupBreak: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 7)
    }

    // MARK: - Capability logic (mirrors MessageRow)

    private var isEditableRole: Bool {
        switch message.role {
        case .user, .assistant, .system, .context: return true
        default: return false
        }
    }

    private var isReloadable: Bool {
        isEditableRole && !model.isStreaming
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "USER"
        case .assistant: return "ASSISTANT"
        case .system: return "SYSTEM"
        case .context: return "CONTEXT"
        case .compressionSummary: return "SUMMARY"
        case .unknown: return "?"
        @unknown default: return "?"
        }
    }

    // MARK: - Actions

    private func toggleSpeech() {
        Haptics.impact(.light)
        app.speech.toggle(
            messageID: message.id,
            content: message.displayContent ?? message.content
        )
        dismiss()
    }

    private func dismiss() {
        withAnimation(.snappy(duration: 0.2)) {
            model.actionMenuMessage = nil
        }
    }
}
