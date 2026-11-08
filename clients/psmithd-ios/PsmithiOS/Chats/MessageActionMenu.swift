import SwiftUI
import PsmithKit
import PsmithUI

/// The long-press menu for a transcript message (MessageMenu): the
/// message lifted into a card at the top, the actions under it, a quick
/// row of Copy, Read and Regenerate first.
///
/// Ours rather than `.contextMenu`: the system menu's lift portals the
/// pressed row into an unflipped container, and inside the inverted
/// transcript (scroll view and row each carry a y-flip) the row renders
/// upside down for the length of the lift. No public API reaches the
/// portal. Presented from the conversation screen through
/// `model.actionMenuMessage`, outside the flipped scroll view.
struct MessageActionMenu: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    let ui: ConversationUIState
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.clipboard) private var clipboard
    @Environment(\.openConversationPage) private var open
    @State private var appeared = false
    /// Set the moment dismissal starts: the overlay stays in the tree for
    /// its fade and must not swallow the next tap.
    @State private var dismissing = false
    @State private var previewHeight: CGFloat = 250

    var body: some View {
        ZStack(alignment: .topLeading) {
            theme.menuBackdrop
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            VStack(alignment: .leading, spacing: 0) {
                preview
                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { previewHeight = $0 }
                // The actions sit at a fixed line under a short preview, so
                // they don't jump with the message's length; a tall one
                // pushes them down.
                actions.padding(.top, max(24, 274 - previewHeight))
            }
            .padding(.horizontal, 16)
            .padding(.top, 91)
            .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
            .opacity(appeared ? 1 : 0)
        }
        .allowsHitTesting(!dismissing)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { appeared = true }
        }
    }

    // MARK: Preview

    private var text: String { message.displayContent ?? message.content }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            CappedHeight(limit: 250 - 32 - (footer == nil ? 0 : 30)) {
                let excerpt = MarkdownBudget.head(text, limit: 600) ?? text
                if ProseText.isPlain(excerpt) {
                    ProseText(text: excerpt, gap: 12).foregroundStyle(IK.text)
                } else {
                MarkdownText(excerpt)
                    .environment(\.fontScale, 16.0 / 17)
                    .lineSpacing(23 - 19.09)
                    .environment(\.markdownTextSelectable, false)
                    .foregroundStyle(IK.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .clipped()
            if let footer {
                HStack(spacing: 6) {
                    Image(systemName: "cpu").font(.system(size: 11))
                    Text(footer).font(.system(size: 12.5)).lineLimit(1)
                }
                .foregroundStyle(IK.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.chrome))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(IK.ring(0.06), lineWidth: 1))
        .shadow(color: IK.shadow, radius: 25, y: 18)
    }

    private var footer: String? {
        let time = UsageFormat.time(message.createdAt)
        if message.role == .assistant, let name = model.modelDisplayName(providerID: message.providerID, modelID: message.modelID) {
            return [name, time].compactMap { $0 }.joined(separator: " · ")
        }
        return time
    }

    // MARK: Actions

    private var editable: Bool {
        switch message.role {
        case .user, .assistant, .system, .context: return true
        case .compressionSummary: return message.errorText == nil
        default: return false
        }
    }

    private var regenerable: Bool {
        (message.role == .user || message.role == .assistant) && !model.isStreaming && !model.sending
    }

    private var speaking: Bool {
        app.speech.isPlaying(messageID: message.id) || app.speech.isLoading(messageID: message.id)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                quick("doc.on.doc", "Copy") {
                    clipboard.write(text)
                    dismiss()
                }
                quick(speaking ? "speaker.slash" : "speaker.wave.2", speaking ? "Stop" : "Read") {
                    Haptics.impact(.light)
                    app.speech.toggle(messageID: message.id, content: text)
                    dismiss()
                }
                .disabled(model.isStreaming || message.errorText != nil)
                quick("arrow.clockwise", "Regenerate") {
                    dismiss()
                    Task { await model.reloadFromMessage(id: message.id) }
                }
                .disabled(!regenerable)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.dynamic(light: Color(red: 16 / 255, green: 26 / 255, blue: 38 / 255).opacity(0.06),
                                        dark: Color.black.opacity(0.22)))
                    .frame(height: 6)
            }
            row("Select Text", "character.cursor.ibeam") {
                dismiss()
                if message.role == .assistant && message.errorText == nil {
                    model.selectingTextMessageID = message.id
                } else {
                    open(.fullText(title: "Message text", markdown: text))
                }
            }
            row("Edit", "pencil") {
                dismiss()
                ui.beginEdit(message, model: model)
            }
            .disabled(!editable)
            if message.role == .assistant && message.usage != nil {
                row("Usage and Cost", "chart.bar") {
                    dismiss()
                    ui.usageExpanded.insert(message.id)
                }
            }
            row("Delete", "trash", destructive: true, separator: model.hasDescendants(message.id)) {
                dismiss()
                ui.requestDelete(message)
            }
            if model.hasDescendants(message.id) {
                row("Delete from Here", "trash.slash", destructive: true, separator: false) {
                    dismiss()
                    ui.requestDelete(message, cascade: true)
                }
            }
        }
        .frame(width: 264)
        .ikGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: IK.shadow, radius: 25, y: 18)
    }

    private func quick(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(IK.strong)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }

    private func row(_ title: String, _ symbol: String, destructive: Bool = false, separator: Bool = true,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16))
                Spacer(minLength: 12)
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(destructive ? IK.red : IK.strong)
            }
            .foregroundStyle(destructive ? IK.red : IK.text)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
        .overlay(alignment: .bottom) {
            if separator { Rectangle().fill(IK.wash(0.08)).frame(height: 0.5) }
        }
    }

    private func dismiss() {
        dismissing = true
        withAnimation(.snappy(duration: 0.2)) { model.actionMenuMessage = nil }
    }
}

private struct MenuPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? IK.wash(0.08) : .clear)
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Sizes its child to the child's ideal height, capped at `limit`,
/// top-aligned. A max-height frame would take the whole cap whatever the
/// content needs.
private struct CappedHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let ideal = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: ideal.height))
    }
}
