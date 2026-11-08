import SwiftUI
import PsmithKit
import PsmithUI

/// One transcript message (boards Conversation, MessageStates,
/// MessageUsage, Thinking, SelectText, SystemStrip, Attachments, Council,
/// LongReply, Fragments). Your messages are tinted bubbles on the right;
/// replies read as page text. The latest reply carries its action row;
/// every message gets the rest from a long-press (MessageActionMenu).
/// Delete and edit happen in place: the row turns into its own question
/// or editor.
struct MessageRow: View {
    let message: PsmithMessage
    /// Whoever spoke immediately before, so a repeated speaker's name can
    /// collapse.
    var previousMessage: PsmithMessage? = nil
    let model: ConversationViewModel
    let ui: ConversationUIState
    /// This reply came from a different model than the one before it.
    var modelChanged: Bool = false
    /// The conversation's first metered reply: nothing earlier could
    /// have warmed its cache, so a miss isn't worth a red dot.
    var isFirstMeteredReply: Bool = false
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.chatPaneWidth) private var paneWidth

    private var isErrored: Bool { message.errorText != nil }
    private var isEditing: Bool { model.editingMessage?.id == message.id }
    private var isSelecting: Bool { model.selectingTextMessageID == message.id }
    private var deleteRequest: ConversationUIState.DeleteRequest? {
        ui.confirmingDelete?.messageID == message.id ? ui.confirmingDelete : nil
    }

    var body: some View {
        Group {
            if let req = deleteRequest {
                IKConfirmCard(
                    question: req.cascade ? "Delete from here?" : "Delete this message?",
                    detail: deleteDetail(cascade: req.cascade),
                    onCancel: { ui.cancelDelete() },
                    onConfirm: { ui.confirmDelete(model: model) }
                )
            } else if isEditing {
                MessageEditCard(message: message, model: model)
            } else {
                content
            }
        }
        .environment(\.markdownTextSelectable, false)
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            UserMessageRow(message: message, model: model, onLongPress: presentMenu)
        case .assistant:
            if isErrored {
                FailedReplyCard(message: message, model: model, onLongPress: presentMenu)
            } else if let slot = message.personaSlot, let name = message.persona {
                CouncilTurn(message: message, name: name, slot: slot,
                            showsName: message.showsPersonaLabel(after: previousMessage),
                            onLongPress: presentMenu)
            } else {
                AssistantReply(message: message, model: model, ui: ui,
                               isFirstMeteredReply: isFirstMeteredReply,
                               modelChanged: modelChanged,
                               onLongPress: presentMenu)
            }
        case .system, .context:
            HeaderMessageStrip(message: message, model: model, onLongPress: presentMenu)
        default:
            MessageBody(message: message).messageActionsOnLongPress(presentMenu)
        }
    }

    private func deleteDetail(cascade: Bool) -> String {
        if cascade {
            let n = model.descendantCount(of: message.id)
            return "This message and the \(n) repl\(n == 1 ? "y" : "ies") under it go."
        }
        let excerpt = Self.excerpt(message.displayContent ?? message.content)
        return "“\(excerpt)” goes. Its replies attach to the message before it."
    }

    static func excerpt(_ s: String, limit: Int = 40) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }

    /// A new conversation's rows are a preview of what creating it will
    /// seed; there is nothing on the server to act on yet.
    private func presentMenu() {
        guard !model.isDraft, !isSelecting else { return }
        Haptics.impact(.medium)
        withAnimation(.snappy(duration: 0.22)) { model.actionMenuMessage = message }
    }

    /// The cache key prewarm sites must match.
    static func markdownKey(id: String, body: String) -> String {
        "\(id):\(body.count):\(body.hashValue)"
    }
}

// MARK: - Body text

/// A message's markdown at the boards' 16pt. Past the inline budget it
/// shows the head under a fade with "Show full text", which pushes the
/// full-text page (LongReply).
struct MessageBody: View {
    let message: PsmithMessage
    var size: CGFloat = 16
    var limit: Int = MarkdownBudget.inlineLimit
    var title: String = "Full text"
    @Environment(\.openConversationPage) private var open
    @Environment(\.theme) private var theme

    private var text: String { message.displayContent ?? message.content }

    /// A reply past the inline budget shows just its opening; the rest
    /// is a page away.
    static let previewLimit = 485

    var body: some View {
        let key = MessageRow.markdownKey(id: message.id, body: text)
        Group {
            if text.count > limit, let head = MarkdownBudget.head(text, limit: Self.previewLimit) {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        if ProseText.isPlain(head) {
                            ProseText(text: head, size: size)
                        } else {
                            ChunkedMarkdownText(head, cacheKey: key + ":head")
                        }
                    }
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [theme.chrome.opacity(0), theme.chrome], startPoint: .top, endPoint: .bottom)
                                .frame(height: 56)
                                .allowsHitTesting(false)
                        }
                    FullTextButton(size: text.utf8.count) {
                        open(.fullText(title: title, markdown: text))
                    }
                }
            } else if ProseText.isPlain(text) {
                ProseText(text: text, size: size, lineHeight: size == 16 ? 23 : 21, gap: size == 16 ? 14 : 8)
            } else {
                ChunkedMarkdownText(text, cacheKey: key)
            }
        }
        .environment(\.fontScale, Double(size) / 17)
        // MarkdownUI's paragraphs inherit SwiftUI line spacing: the
        // boards set 16pt type on 23pt lines.
        .lineSpacing(size * 1.4375 - size * 1.193)
        .foregroundStyle(IK.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Prose, simple lists and code fences, set the way the boards set them:
/// exact line heights and gaps, which MarkdownUI's theme can't take.
/// Inline emphasis, code and links still render. Anything richer
/// (headings, quotes, tables, nesting) goes to MarkdownUI instead.
struct ProseText: View {
    let text: String
    var size: CGFloat = 16
    var lineHeight: CGFloat = 23
    var gap: CGFloat = 14

    enum Block {
        case paragraph(String)
        case list(ordered: Bool, items: [String])
        case code(String)
    }

    static func isPlain(_ s: String) -> Bool { parse(s) != nil }

    static func parse(_ s: String) -> [Block]? {
        guard s.utf8.count < 6_000 else { return nil }
        var blocks: [Block] = []
        var para: [String] = []
        var items: [String] = []
        var ordered = false
        var code: [String]?
        func flushPara() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushList() { if !items.isEmpty { blocks.append(.list(ordered: ordered, items: items)); items = [] } }
        func marker(_ line: Substring) -> (Bool, Substring)? {
            for m in ["- ", "* ", "+ "] where line.hasPrefix(m) { return (false, line.dropFirst(2)) }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot > line.startIndex,
               line[line.startIndex..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ") {
                return (true, line[line.index(dot, offsetBy: 2)...])
            }
            return nil
        }
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if var c = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { blocks.append(.code(c.joined(separator: "\n"))); code = nil }
                else { c.append(String(line)); code = c }
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { flushPara(); flushList(); code = []; continue }
            if t.isEmpty { flushPara(); flushList(); continue }
            if t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("|") || t.hasPrefix("~~~") { return nil }
            let indented = line.first == " " || line.first == "\t"
            if !indented, let (isOrdered, rest) = marker(line) {
                flushPara()
                if !items.isEmpty && isOrdered != ordered { flushList() }
                ordered = isOrdered
                items.append(String(rest))
            } else if indented && !items.isEmpty {
                if marker(Substring(t)) != nil { return nil }
                items[items.count - 1] += " " + t
            } else {
                if indented && marker(Substring(t)) != nil { return nil }
                flushList()
                para.append(String(line))
            }
        }
        if code != nil { return nil }
        flushPara(); flushList()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array((Self.parse(text) ?? [.paragraph(text)]).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let p):
                    inline(p)
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(ordered ? "\(n + 1)." : "•").font(.system(size: size))
                                    .frame(width: 22, alignment: .leading)
                                inline(item)
                            }
                        }
                    }
                case .code(let c):
                    UnwrappedLines {
                        Text(c).cssLines(size: 13.5, lineHeight: 19).fontDesign(.monospaced)
                            .foregroundStyle(IK.strong)
                            .fixedSize()
                    }
                    .clipped()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(IK.wash(0.06)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ p: String) -> some View {
        var a = (try? AttributedString(markdown: p, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(p)
        // The boards' bold is semibold.
        for run in a.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            a[run.range].font = .system(size: size, weight: .semibold)
        }
        return Text(a)
            .cssLines(size: size, lineHeight: lineHeight)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct FullTextButton: View {
    let size: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 14))
                Text("Show full text (\(UsageFormat.bytes(size)))").font(.system(size: 14))
            }
            .foregroundStyle(IK.strong)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(IK.wash(0.08)))
            .overlay(Capsule().strokeBorder(IK.ring(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Your message

struct UserMessageRow: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    let onLongPress: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.chatPaneWidth) private var paneWidth

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                MessageAttachments(message: message)
            }
            let text = message.displayContent ?? message.content
            if !text.isEmpty {
                UserBubble(text: text)
                    .messageActionsOnLongPress(onLongPress)
            }
            if let info = model.branchInfo(for: message.id) {
                BranchPill(info: info, model: model)
                    .padding(.top, -2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Your words in the accent-tinted bubble, 80% of the pane at most.
struct UserBubble: View {
    let text: String
    @Environment(\.theme) private var theme
    @Environment(\.chatPaneWidth) private var paneWidth

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(text)
                .cssLines(size: 16, lineHeight: 22)
                .foregroundStyle(IK.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.bubble))
                .frame(maxWidth: paneWidth > 0 ? (paneWidth - 32) * 0.8 : 300, alignment: .trailing)
                // Ahead of the spacer, or the stack splits the row between them.
                .layoutPriority(1)
        }
    }
}

/// "2 of 3" with chevrons: switches between sibling branches.
struct BranchPill: View {
    let info: (siblingIDs: [String], index: Int)
    let model: ConversationViewModel

    var body: some View {
        HStack(spacing: 0) {
            Button {
                let i = (info.index - 1 + info.siblingIDs.count) % info.siblingIDs.count
                Task { await model.switchToBranch(siblingID: info.siblingIDs[i]) }
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 32, height: 32)
            }
            .accessibilityLabel("Previous branch")
            Text("\(info.index + 1) of \(info.siblingIDs.count)")
                .font(.system(size: 13)).monospacedDigit()
            Button {
                let i = (info.index + 1) % info.siblingIDs.count
                Task { await model.switchToBranch(siblingID: info.siblingIDs[i]) }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).frame(width: 32, height: 32)
            }
            .accessibilityLabel("Next branch")
        }
        .buttonStyle(.plain)
        .foregroundStyle(IK.secondary)
        .frame(height: 32)
        .background(Capsule().fill(IK.wash(0.06)))
    }
}

// MARK: - A reply

struct AssistantReply: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    let ui: ConversationUIState
    var isFirstMeteredReply = false
    var modelChanged = false
    let onLongPress: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.openConversationPage) private var open

    private var isSelecting: Bool { model.selectingTextMessageID == message.id }
    private var usageOpen: Bool { ui.usageExpanded.contains(message.id) }
    private var isSpeaking: Bool {
        app.speech.isPlaying(messageID: message.id) || app.speech.isLoading(messageID: message.id)
    }

    /// The reply that ends the transcript keeps its actions in view; any
    /// other shows them only while something on it is live (reading
    /// aloud, selecting, usage open).
    private var showsActions: Bool {
        // Hidden while something else holds the composer's place.
        guard !model.isDraft, !model.isCompacting, !model.showingCompactView, !model.hasPendingCompression, !ui.trayOpen,
              model.conversation.archivedAt == nil else { return false }
        return message.id == model.messages.last?.id
            || isSpeaking || isSelecting || usageOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if modelChanged, let name = model.modelDisplayName(providerID: message.providerID, modelID: message.modelID) {
                Label(name, systemImage: "cpu")
                    .font(.system(size: 12.5))
                    .foregroundStyle(IK.tertiary)
            }
            ReplyPills(message: message, model: model)
            Group {
                if isSelecting {
                    SelectableMessageText(text: message.displayContent ?? message.content)
                } else if !message.uiFragments.isEmpty {
                    FragmentView(fragments: message.uiFragments, onAction: handleFragment)
                } else if message.isWelcome && !model.welcomePlayed.contains(message.id) {
                    WelcomeReveal(text: message.displayContent ?? message.content) {
                        model.welcomePlayed.insert(message.id)
                    }
                    .font(.system(size: 16))
                } else if !(message.displayContent ?? message.content).isEmpty {
                    MessageBody(message: message)
                }
            }
            .contentShape(Rectangle())
            .messageActionsOnLongPress(onLongPress)
            if let fork = ui.pendingFork, fork.messageID == message.id {
                ForkConfirmCard(text: fork.text) { ui.pendingFork = nil } onConfirm: {
                    ui.pendingFork = nil
                    Haptics.notify(.success)
                    Task { await model.sendForking(content: fork.text, parentMessageID: message.id) }
                }
            }
            if showsActions {
                ReplyActionRow(message: message, model: model, ui: ui, isFirstMeteredReply: isFirstMeteredReply)
                if usageOpen {
                    UsagePanel(message: message, model: model)
                }
            } else {
                passiveFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An older reply still says what's worth noticing: its branches and
    /// an unexpected stop.
    @ViewBuilder
    private var passiveFooter: some View {
        let stop = message.unexpectedStopLabel
        let branch = model.branchInfo(for: message.id)
        if stop != nil || branch != nil {
            HStack(spacing: 8) {
                if let stop {
                    Text(stop).font(.system(size: 12.5)).foregroundStyle(IK.orange)
                }
                Spacer(minLength: 0)
                if let branch { BranchPill(info: branch, model: model) }
            }
        }
    }

    private func handleFragment(_ action: FragmentAction) {
        switch action {
        case .compose(let text):
            model.draft = model.draft.isEmpty ? text : model.draft + "\n" + text
        case .send(let text):
            // Off the tip, auto-submitting would append onto a stale
            // branch: confirm a fork off this message in place instead.
            if let latest = model.latestAssistantMessageID, latest != message.id {
                ui.pendingFork = (message.id, text)
            } else {
                model.draft = text
                Task { await model.send() }
            }
        case .external(let url):
            UIApplication.shared.open(url)
        case .plugin:
            // Only meaningful inside the panel that rendered it.
            break
        }
    }
}

/// Confirm in place for a fragment choice on an earlier message
/// (Fragments board).
struct ForkConfirmCard: View {
    let text: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Submit choice on an earlier message?").font(.system(size: 15, weight: .semibold)).foregroundStyle(IK.text)
            Text("This forks the conversation here and sends “\(MessageRow.excerpt(text, limit: 30))” as a new branch. The current branch stays as it is.")
                .cssLines(size: 13, lineHeight: 18).foregroundStyle(IK.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).ikButton()
                Button("Fork and Send", action: onConfirm).ikButton(.primary)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.accent.opacity(0.4), lineWidth: 1))
    }
}

/// Copy, read aloud, regenerate, usage; the cache grade or time at the
/// right.
struct ReplyActionRow: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    let ui: ConversationUIState
    var isFirstMeteredReply = false
    @Environment(AppModel.self) private var app
    @Environment(\.clipboard) private var clipboard
    @Environment(\.theme) private var theme

    private var usageOpen: Bool { ui.usageExpanded.contains(message.id) }
    private var isSelecting: Bool { model.selectingTextMessageID == message.id }
    private var speaking: Bool {
        app.speech.isPlaying(messageID: message.id) || app.speech.isLoading(messageID: message.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            iconButton("doc.on.doc", label: "Copy") {
                Haptics.impact(.light)
                clipboard.write(message.displayContent ?? message.content)
            }
            if speaking {
                Button(action: toggleSpeech) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 14))
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        Text("Reading").font(.system(size: 13.5, weight: .medium))
                        Image(systemName: "stop.fill").font(.system(size: 10))
                    }
                    .foregroundStyle(theme.accentInk)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Capsule().fill(theme.accent.opacity(0.18)))
                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .accessibilityLabel("Stop reading aloud")
            } else {
                iconButton("speaker.wave.2", label: "Read aloud", action: toggleSpeech)
                    .disabled(model.isStreaming)
            }
            iconButton("arrow.clockwise", label: "Regenerate") {
                Task { await model.reloadFromMessage(id: message.id) }
            }
            .disabled(model.isStreaming || model.sending)
            iconButton("info.circle", label: usageOpen ? "Hide usage and cost" : "Usage and cost", on: usageOpen) {
                withAnimation(.snappy(duration: 0.2)) { ui.toggleUsage(message.id) }
            }
            if isSelecting {
                Button {
                    model.selectingTextMessageID = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "character.cursor.ibeam").font(.system(size: 13, weight: .semibold))
                        Text("Done selecting").font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(theme.accentInk)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Capsule().fill(theme.accent.opacity(0.18)))
                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            Spacer(minLength: 4)
            if let branch = model.branchInfo(for: message.id) {
                BranchPill(info: branch, model: model).padding(.trailing, 6)
            }
            trailing.padding(.trailing, 10)
        }
        .padding(.horizontal, -10)
    }

    @ViewBuilder
    private var trailing: some View {
        if usageOpen {
            if let t = UsageFormat.time(message.createdAt) {
                Text(t).font(.system(size: 12.5)).foregroundStyle(IK.tertiary)
            }
        } else if let stop = message.unexpectedStopLabel {
            Text(stop).font(.system(size: 12.5)).foregroundStyle(IK.orange).lineLimit(1)
        } else if let u = message.usage, let g = CacheGrade.grade(u, isFirstMetered: isFirstMeteredReply) {
            HStack(spacing: 6) {
                Circle().fill(g.color).frame(width: 7, height: 7)
                Text("\(g.percent)% cached").font(.system(size: 12.5)).foregroundStyle(IK.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(g.label) cache hit, \(g.percent)% of the prompt served from cache")
        }
    }

    private func iconButton(_ symbol: String, label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(on ? theme.accentInk : IK.secondary)
                .frame(width: 44, height: 36)
                .background(RoundedRectangle(cornerRadius: 12).fill(on ? theme.accent.opacity(0.18) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? theme.accent.opacity(0.45) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toggleSpeech() {
        Haptics.impact(.light)
        app.speech.toggle(messageID: message.id, content: message.displayContent ?? message.content)
    }
}

/// Usage and cost, opened under the reply (MessageUsage).
struct UsagePanel: View {
    let message: PsmithMessage
    let model: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.system(size: 13))
                Text(headline).font(.system(size: 13.5)).lineLimit(1)
            }
            .foregroundStyle(IK.strong)
            if let u = message.usage {
                let tiles = tiles(u)
                if !tiles.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(tiles, id: \.1) { value, label in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(IK.text)
                                Text(label).font(.system(size: 12)).foregroundStyle(IK.secondary)
                            }
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(IK.wash(0.04)))
                        }
                    }
                    .padding(.top, 10)
                }
                VStack(spacing: 0) {
                    if let v = u.inputCostUsd, v > 0 { kv("Input", UsageFormat.price(v)) }
                    if let v = u.cacheReadCostUsd, v > 0 { kv("Cache read", UsageFormat.price(v)) }
                    if let v = u.cacheWriteCostUsd, v > 0 { kv("Cache write", UsageFormat.price(v)) }
                    if let v = u.outputCostUsd, v > 0 { kv("Output", UsageFormat.price(v)) }
                    if let v = u.toolCostUsd, v > 0 { kv("Tools", UsageFormat.price(v)) }
                    if let v = u.totalCostUsd { kv("Total", UsageFormat.price(v), weight: .semibold, color: IK.text) }
                    if let saved = savedByCache(u), saved >= 0.005 {
                        kv("Saved by the cache", String(format: "$%.2f", saved), color: IK.green, valueColor: IK.green)
                    }
                    if let attached = u.explicitCacheAttached {
                        kv("Explicit cache", attached ? "Attached" : "Not attached")
                    }
                }
                .padding(.top, 8)
            } else {
                Text("No usage was reported for this reply.").font(.system(size: 13.5)).foregroundStyle(IK.secondary)
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.wash(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.07), lineWidth: 1))
    }

    private var headline: String {
        let name = model.modelDisplayName(providerID: message.providerID, modelID: message.modelID) ?? "Unknown model"
        if let pid = message.providerID, let label = model.providerLabels[pid] { return "\(name) · \(label)" }
        return name
    }

    private func tiles(_ u: PsmithMessageUsage) -> [(String, String)] {
        var out: [(String, String)] = []
        if let n = u.inputTokens { out.append((UsageFormat.tokens(n), "Input")) }
        if let n = u.cacheReadTokens, n > 0 { out.append((UsageFormat.tokens(n), "Cached")) }
        if let n = u.outputTokens { out.append((UsageFormat.tokens(n), "Output")) }
        if let n = u.reasoningTokens, n > 0 { out.append((UsageFormat.tokens(n), "Reasoning")) }
        return out
    }

    /// What the cached tokens would have cost at the input price, less
    /// what reading them did cost.
    private func savedByCache(_ u: PsmithMessageUsage) -> Double? {
        guard let read = u.cacheReadTokens, read > 0,
              let price = model.modelInfo(providerID: message.providerID, modelID: message.modelID)?.pricing?.inputPerMillion
        else { return nil }
        return Double(read) * price / 1_000_000 - (u.cacheReadCostUsd ?? 0)
    }

    private func kv(_ label: String, _ value: String, weight: Font.Weight = .regular,
                    color: Color = IK.secondary, valueColor: Color = IK.text) -> some View {
        HStack {
            Text(label).foregroundStyle(color).fontWeight(weight)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(valueColor).fontWeight(weight == .regular ? .medium : weight).monospacedDigit()
        }
        .font(.system(size: 13.5))
        .frame(height: 22)
    }
}

extension PsmithMessage {
    /// A stop that wasn't a clean finish ("Stopped: max tokens"); nil
    /// for the ordinary ones.
    var unexpectedStopLabel: String? {
        guard let raw = finishReason?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "stop", "end_turn", "tool_use", "tool_calls": return nil
        default: return "Stopped: " + raw.replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }
}

// MARK: - Council

/// A named speaker's turn: a rail in its color, its name above the
/// words (Council).
struct CouncilTurn: View {
    let message: PsmithMessage
    let name: String
    let slot: Int
    var showsName = true
    let onLongPress: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(theme.personaColor(slot).opacity(0.55)).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                if showsName {
                    HStack(spacing: 6) {
                        Circle().fill(theme.personaColor(slot)).frame(width: 7, height: 7)
                        Text(name).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(theme.personaColor(slot))
                }
                MessageBody(message: message)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .messageActionsOnLongPress(onLongPress)
    }
}

// MARK: - Failed reply

/// A reply that failed: the provider's error, the partial output folded
/// away, Retry (MessageStates).
struct FailedReplyCard: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    let onLongPress: () -> Void
    @State private var showPartial = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(IK.orange)
                RoleCaps(text: "FAILED", color: IK.orange)
                Spacer(minLength: 0)
                if let name = model.modelDisplayName(providerID: message.providerID, modelID: message.modelID) {
                    Text(name).font(.system(size: 12.5)).foregroundStyle(IK.tertiary).lineLimit(1)
                }
            }
            if let err = message.errorText, !err.isEmpty {
                Text(err).cssLines(size: 15, lineHeight: 21).foregroundStyle(IK.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if !(message.displayContent ?? message.content).isEmpty {
                Button { withAnimation(.snappy(duration: 0.2)) { showPartial.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showPartial ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold))
                        Text("Partial output before the failure").font(.system(size: 13.5))
                    }
                    .foregroundStyle(IK.secondary)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                if showPartial {
                    MessageBody(message: message, size: 15).foregroundStyle(IK.secondary)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button {
                    Task { await model.reloadFromMessage(id: message.id) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .ikButton(.primary)
                .disabled(model.isStreaming || model.sending)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.orange.opacity(0.55), lineWidth: 1.5))
        .contentShape(Rectangle())
        .messageActionsOnLongPress(onLongPress)
    }
}

// MARK: - System and context messages

/// System and context messages fold to a one-line strip; tap to read
/// them in full (SystemStrip).
struct HeaderMessageStrip: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    let onLongPress: () -> Void

    private var expanded: Bool { model.expandedHeaderMessageIDs.contains(message.id) }
    private var label: String { message.role == .system ? "SYSTEM" : "CONTEXT" }
    private var symbol: String { message.role == .system ? "gearshape" : "tray.full" }

    var body: some View {
        Group {
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 13))
                        RoleCaps(text: label)
                        Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(IK.secondary)
                    .frame(height: 28)
                    .padding(.top, -4)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Fold the \(label.lowercased()) message")
                    MessageBody(message: message, size: 15)
                        .foregroundStyle(IK.strong)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(IK.wash(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.06), lineWidth: 1))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(IK.secondary)
                    RoleCaps(text: label)
                    Text(previewLine).font(.system(size: 13)).foregroundStyle(IK.tertiary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(IK.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(IK.wash(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(IK.ring(0.06), lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Show the \(label.lowercased()) message, \(previewLine)")
            }
        }
        .messageActionsOnLongPress(onLongPress)
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) {
            if expanded { model.expandedHeaderMessageIDs.remove(message.id) } else { model.expandedHeaderMessageIDs.insert(message.id) }
        }
    }

    /// The first line, without a markdown leader, so a message that
    /// opens with a heading reads like a sentence.
    private var previewLine: String {
        let raw = message.displayContent ?? message.content
        guard let first = raw.split(whereSeparator: \.isNewline).first else { return raw }
        var s = String(first).trimmingCharacters(in: .whitespaces)
        for leader in ["# ", "## ", "### ", "- ", "* ", "> "] where s.hasPrefix(leader) {
            s = String(s.dropFirst(leader.count))
            break
        }
        return s.isEmpty ? "(empty)" : s
    }
}

// MARK: - Edit in place

/// The message becomes its own editor (MessageStates). Your messages and
/// replies can swap role; Save keeps the branch, Save and Resend forks
/// a new one from the edit.
struct MessageEditCard: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    @State private var draft: String
    @State private var role: PsmithMessageRole
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    init(message: PsmithMessage, model: ConversationViewModel) {
        self.message = message
        self.model = model
        _draft = State(initialValue: message.content)
        _role = State(initialValue: message.role)
    }

    private var swapsRole: Bool { message.role == .user || message.role == .assistant }
    private var canResend: Bool { message.role == .user || message.role == .assistant }
    private var empty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if swapsRole {
                RolePicker(role: $role)
            }
            TextField("Message", text: $draft, axis: .vertical)
                .font(.system(size: 16))
                .lineSpacing(22 - 19.09)
                .lineLimit(2...12)
                .focused($focused)
                .foregroundStyle(IK.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(IK.well))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { model.editingMessage = nil }.ikButton(.text)
                Button("Save") { save() }.ikButton().disabled(empty)
                if canResend {
                    Button("Save and Resend") { saveAndResend() }.ikButton(.primary).disabled(empty || model.isStreaming || model.sending)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5))
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    func save() {
        let text = trimmed
        let newRole: PsmithMessageRole? = swapsRole && role != message.role ? role : nil
        // The content-hash key makes the post-edit render a cache hit.
        MarkdownCache.shared.prewarm([(key: MessageRow.markdownKey(id: message.id, body: text), source: text)])
        let id = message.id
        model.editingMessage = nil
        Task { await model.editMessage(id: id, content: text, role: newRole) }
    }

    func saveAndResend() {
        let text = trimmed
        let msg = message
        model.editingMessage = nil
        Task {
            if msg.role == .user {
                await model.sendForking(content: text, parentMessageID: msg.parentID)
            } else {
                await model.editMessage(id: msg.id, content: text, role: nil)
                await model.regenerateAssistant(parentMessageID: msg.id)
            }
        }
    }
}

/// You / Assistant, the segmented role switch on an edited message.
struct RolePicker: View {
    @Binding var role: PsmithMessageRole

    var body: some View {
        HStack(spacing: 0) {
            segment("You", .user)
            segment("Assistant", .assistant)
        }
        .padding(2)
        .frame(width: 200, height: 30)
        .background(RoundedRectangle(cornerRadius: 9).fill(IK.wash(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Role")
    }

    private func segment(_ title: String, _ value: PsmithMessageRole) -> some View {
        let on = role == value
        return Button { role = value } label: {
            Text(title)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? IK.text : IK.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? IK.wash(0.16) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Selection

/// Select Text, in place: the reply's text as a read-only text view
/// with the system's own handles and edit menu (SelectText).
struct SelectableMessageText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        // Paragraph spacing makes the gap; a blank line would double it.
        var flat = text
        while flat.contains("\n\n\n") { flat = flat.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        flat = flat.replacingOccurrences(of: "\n\n", with: "\n")
        let attributed = (try? AttributedString(
            markdown: flat,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let ns = NSMutableAttributedString(attributed)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 23
        style.maximumLineHeight = 23
        style.paragraphSpacing = 14
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.paragraphStyle, value: style, range: full)
        ns.addAttribute(.foregroundColor, value: UIColor(IK.text), range: full)
        ns.enumerateAttribute(.font, in: full) { value, range, _ in
            let base = UIFont.systemFont(ofSize: 16)
            if let f = value as? UIFont, let d = base.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits) {
                ns.addAttribute(.font, value: UIFont(descriptor: d, size: 16), range: range)
            } else {
                ns.addAttribute(.font, value: base, range: range)
            }
        }
        if v.attributedText != ns { v.attributedText = ns }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 320
        let s = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: s.height)
    }
}
