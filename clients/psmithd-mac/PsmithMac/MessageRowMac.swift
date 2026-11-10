import SwiftUI
import AppKit
import PsmithKit
import PsmithUI

/// One transcript turn on the Mac, drawn the way iOS draws it: your
/// messages in a themed bubble on the right that fits its text, replies
/// as page content with no bubble, framing rows (system, context) folded
/// to a one-line strip. Metadata is quiet by default: the role label,
/// the model on every reply, token counts and timestamps show only with
/// "Show turn details" on. Off, the transcript keeps only signals: a
/// model change, a poor cache on a prompt big enough to matter, a reply
/// that stopped early.
///
/// Actions live in a row under the message, shown on hover. The newest
/// reply keeps them visible, since it's the one you act on most.
struct MessageRow: View {
    let message: PsmithMessage
    /// Whoever spoke immediately before, so a repeated speaker's name can
    /// collapse. nil means "no predecessor", which always shows the label.
    var previousMessage: PsmithMessage? = nil
    let model: ConversationViewModel
    /// This reply came from a different model than the reply before it.
    /// Computed once per transcript by the list, not once per row.
    var modelChanged: Bool = false
    /// The conversation's first metered reply: nothing earlier could
    /// have warmed its cache, so a miss isn't worth a red dot.
    var isFirstMeteredReply: Bool = false

    @Environment(AppModel.self) private var app
    @Environment(AppPreferences.self) private var prefs
    @Environment(\.theme) private var theme
    @Environment(\.clipboard) private var clipboard
    @Environment(\.chatPaneWidth) private var paneWidth

    @State private var confirmingDelete = false
    /// The delete asked for takes everything under the message too.
    @State private var deleteCascades = false
    @State private var showUsageDetail = false
    @State private var editDraft = ""
    /// The inline editor's role. Only user and assistant can flip, and
    /// the choice rides into the fork at "Save and Resend".
    @State private var editRoleDraft: PsmithMessageRole = .user
    @State private var showPartialContent = false
    @State private var isHovering = false
    @State private var showCopied = false
    /// Choice text waiting on a fork confirmation: a `send:` choice
    /// tapped on a message that isn't the tip.
    @State private var pendingForkText: String?
    /// The live text view while in selection mode, for the drag that
    /// began on the markdown rendering to extend into.
    @State private var selectionHandle = SelectableMessageText.Handle()

    // MARK: - State

    private var isErrored: Bool { message.errorText != nil }
    private var isEditing: Bool { model.editingMessage?.id == message.id }
    private var isUser: Bool { message.role == .user }
    private var isFraming: Bool { message.role == .system || message.role == .context }
    private var isHeaderExpanded: Bool { model.expandedHeaderMessageIDs.contains(message.id) }

    /// Selection mode swaps the body to an AppKit text view holding the
    /// whole message as one attributed string, so any range selects and
    /// ⌘C copies it. SwiftUI's own selection stops at each paragraph.
    private var selectingText: Bool { model.selectingTextMessageID == message.id }

    private var isEditableRole: Bool {
        switch message.role {
        case .user, .assistant, .system, .context: return true
        default: return false
        }
    }

    private var isReloadable: Bool { isEditableRole && !model.isStreaming }

    private var canSelectText: Bool {
        !isErrored && message.uiFragments.isEmpty && !bodyText.isEmpty
    }

    private var showsRolePicker: Bool { message.role == .user || message.role == .assistant }

    private var isSpeaking: Bool {
        app.speech.isPlaying(messageID: message.id) || app.speech.isLoading(messageID: message.id)
    }

    private var isLatestReply: Bool {
        message.role == .assistant && message.id == model.latestAssistantMessageID && !model.isStreaming
    }

    private var bodyText: String { message.displayContent ?? message.content }

    /// The transcript column's width; user bubbles take at most most of it.
    private var bubbleCap: CGFloat { paneWidth > 0 ? paneWidth * 0.8 : 600 }

    // MARK: - Body

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            content
            if !model.isDraft, !isEditing {
                actionRow
            }
            if showUsageDetail, !isEditing {
                MessageUsageDetails(message: message, model: model)
                    .padding(.top, 4)
            }
            if confirmingDelete {
                MKStrip(systemImage: "exclamationmark.triangle",
                        lead: deleteCascades ? "Delete from here?" : "Delete this \(isUser ? "message" : "reply")?",
                        detail: deleteDetail) {
                    Button("Cancel") { confirmingDelete = false }.skButton(small: true).keyboardShortcut(.cancelAction)
                    Button("Delete") {
                        confirmingDelete = false
                        let cascade = deleteCascades
                        Task { await model.deleteMessage(id: message.id, cascade: cascade) }
                    }
                    .skButton(.destructiveFilled, small: true)
                }
                .padding(.top, 4)
            }
            if let text = pendingForkText {
                MKStrip(systemImage: "arrow.triangle.branch", lead: "Send “\(text)” from this earlier reply?",
                        detail: "It starts a new branch here. The current one stays.",
                        tint: theme.accentInk, fill: theme.accent.opacity(0.18), ring: theme.accent.opacity(0.45)) {
                    Button("Cancel") { pendingForkText = nil }.skButton(small: true).keyboardShortcut(.cancelAction)
                    Button("Fork and Send") {
                        pendingForkText = nil
                        Task { await model.sendForking(content: text, parentMessageID: message.id) }
                    }
                    .skButton(.primary, small: true)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .contentShape(Rectangle())
        // A plain state write: wrapping it in withAnimation has crashed
        // mid-stream on macOS 26.
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if isFraming && !isHeaderExpanded && !isEditing {
            collapsedStrip
        } else if isUser && !isErrored && !isEditing {
            userBubble
        } else if message.role == .assistant && !isErrored && !isEditing {
            inner
                .frame(maxWidth: .infinity, alignment: .leading)
                .personaRail(index: message.personaSlot)
                .contextMenu { contextMenuItems }
                .accessibilityActions { contextMenuItems }
        } else {
            framedBubble
        }
    }

    // MARK: - Shapes

    private var userBubble: some View {
        HuggingWidth(maxWidth: bubbleCap) {
            inner
                .contextMenu { contextMenuItems }
                .accessibilityActions { contextMenuItems }
                .modifier(UserBubbleChrome())
        }
    }

    /// Errored turns, the inline editor, and expanded framing rows keep
    /// a bubble: each is a state worth a boundary around it.
    private var framedBubble: some View {
        inner
            .contextMenu { contextMenuItems }
                .accessibilityActions { contextMenuItems }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12).fill(
                    isEditing ? theme.accent.opacity(0.08)
                        : isErrored ? SK.orange.opacity(0.08)
                        : MK.card
                )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    isEditing ? theme.accent.opacity(0.45)
                        : isErrored ? SK.orange.opacity(0.5)
                        : SK.line,
                    lineWidth: isEditing || isErrored ? 1.5 : 1
                )
            )
    }

    /// System and context rows fold to one line: framing you read once
    /// when setting up a turn, not on every scroll back.
    private var collapsedStrip: some View {
        Button {
            model.expandedHeaderMessageIDs.insert(message.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: message.role == .system ? "gearshape" : "tray.full")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SK.secondary)
                    .frame(width: 13)
                Text(roleLabel).sk(10.5, SK.secondary, weight: .semibold)
                Text(previewLine).sk(12, SK.tertiary).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SK.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(MK.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SK.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenuItems }
                .accessibilityActions { contextMenuItems }
        .help("Show the \(roleLabel.lowercased()) message")
    }

    // MARK: - Inner content

    @ViewBuilder
    private var inner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if headerHasContent {
                headerRow
            }
            if !isEditing, message.role == .assistant, message.hasThinking {
                ThinkingDisclosure(
                    phase: .settled(durationSec: message.thinkingDurationMs.map { Double($0) / 1000 }),
                    renderedText: message.thinkingRenderedText ?? "",
                    isExpanded: setBinding(\.expandedThinkingMessageIDs, message.id)
                )
            }
            if !isEditing, message.role == .assistant, !message.toolCalls.isEmpty {
                ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { idx, call in
                    ToolCallSettledDisclosure(
                        call: call,
                        isExpanded: setBinding(\.expandedToolCallKeys, "\(message.id):\(idx)")
                    )
                }
            }
            if !isEditing, !imageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(imageAttachments) { MessageAttachmentImageMac(attachment: $0, messageID: message.id) }
                    }
                }
            }
            if !isEditing, !nonImageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(nonImageAttachments) { MessageAttachmentChipMac(attachment: $0) }
                    }
                }
            }
            if isEditing {
                inlineEditor
            } else if isErrored {
                erroredBody
            } else if !message.uiFragments.isEmpty {
                FragmentView(fragments: message.uiFragments, onAction: handleFragmentAction, onPluginAction: { plugin, action, params in
                    // The transcript reloads to show the effect; a failure
                    // leaves it as it was, which is what the user sees.
                    Task { try? await model.invokeFragmentAction(plugin: plugin, action: action, params: params) }
                })
            } else {
                markdownBody
            }
            if prefs.showTurnDetails, !isEditing {
                detailsFooter
            }
        }
    }

    /// The markdown body. A drag anywhere on it selects text: the first
    /// movement swaps in the native text view and the drag continues as
    /// its selection. The stack is what the gesture lives on, so it
    /// survives the swap.
    private var markdownBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bodyText.isEmpty {
                Text("(empty)").foregroundStyle(.secondary)
            } else if selectingText {
                SelectableMessageText(markdown: bodyText, handle: selectionHandle) {
                    if selectingText { model.selectingTextMessageID = nil }
                }
            } else if message.isWelcome && !model.welcomePlayed.contains(message.id) {
                WelcomeReveal(text: bodyText) {
                    model.welcomePlayed.insert(message.id)
                }
            } else {
                BoundedMarkdownText(bodyText)
            }
        }
        // SwiftUI's per-paragraph selection would take the mouse before
        // the drag below, and it's what selection mode replaces.
        .environment(\.markdownTextSelectable, false)
        .dragToSelectText(handle: selectionHandle) {
            guard canSelectText else { return }
            model.selectingTextMessageID = message.id
        }
    }

    @ViewBuilder
    private var erroredBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errText = message.errorText, !errText.isEmpty {
                Text(errText)
                    .sk(13, SK.red)
                    .textSelection(.enabled)
            }
            if !bodyText.isEmpty {
                DisclosureGroup(isExpanded: $showPartialContent) {
                    BoundedMarkdownText(bodyText)
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } label: {
                    Text("Partial output streamed before failure").sk(12, SK.secondary)
                }
            }
            if message.role == .assistant {
                HStack {
                    Spacer()
                    Button {
                        Task { await model.reloadFromMessage(id: message.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold))
                            Text("Retry")
                        }
                    }
                    .skButton(.primary, small: true)
                    .disabled(model.isStreaming || model.sending)
                    .help("Run this turn again. The retry is a new branch; the failed turn stays.")
                }
            }
        }
    }

    // MARK: - Header

    private var showsRoleLabel: Bool {
        prefs.showTurnDetails || isErrored || isFraming
    }

    private var showsModelLabel: Bool {
        modelDisplayLabel != nil && message.role == .assistant && (prefs.showTurnDetails || modelChanged)
    }

    private var hasPersonaLabel: Bool {
        message.personaSlot != nil && message.persona != nil && !isErrored
    }

    private var headerHasContent: Bool {
        showsRoleLabel || hasPersonaLabel || showsModelLabel || message.editedAt != nil
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if isErrored {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SK.orange)
            }
            if isFraming {
                Button {
                    model.expandedHeaderMessageIDs.remove(message.id)
                } label: {
                    HStack(spacing: 4) {
                        Text(roleLabel)
                        Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                    }
                    .sk(10.5, SK.secondary, weight: .semibold)
                }
                .buttonStyle(.plain)
                .help("Fold the \(roleLabel.lowercased()) message")
            } else if let slot = message.personaSlot, let name = message.persona, !isErrored {
                PersonaLabel(name: name, index: slot, showsName: message.showsPersonaLabel(after: previousMessage))
            } else if showsRoleLabel {
                Text(roleLabel).sk(11, isErrored ? SK.orange : SK.tertiary, weight: isErrored ? .semibold : nil)
            }
            if isErrored {
                Text("FAILED").sk(11, SK.orange, weight: .semibold)
            }
            if message.editedAt != nil {
                Text("edited").sk(11, SK.tertiary)
            }
            if showsModelLabel, let label = modelDisplayLabel {
                if !isUser { Spacer(minLength: 6) }
                HStack(spacing: 4) {
                    Image(systemName: modelChanged && !prefs.showTurnDetails ? "arrow.left.arrow.right" : "cpu").font(.system(size: 9.5))
                    Text(label).sk(11, SK.tertiary)
                }
                    .foregroundStyle(SK.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(modelChanged ? "This reply came from a different model than the one before it" : label)
            }
        }
    }

    // MARK: - Footer (turn details on)

    @ViewBuilder
    private var detailsFooter: some View {
        HStack(spacing: 6) {
            if message.role == .assistant, let usage = message.usage {
                Text(usageSummary(usage))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let stamp = formattedTimestamp {
                Text(stamp)
            }
        }
        .sk(11, SK.tertiary)
        .monospacedDigit()
    }

    // MARK: - Action row

    /// Signals on one side (always), actions beside them (on hover). The
    /// row keeps its height either way, so hovering never moves the
    /// transcript.
    private var actionRow: some View {
        HStack(spacing: 6) {
            if isUser {
                actions.opacity(actionsVisible ? 1 : 0).allowsHitTesting(actionsVisible)
                branchSwitcher
            } else {
                branchSwitcher
                actions.opacity(actionsVisible ? 1 : 0).allowsHitTesting(actionsVisible)
                Spacer(minLength: 8)
                signals
            }
        }
        .frame(height: 24)
        .padding(.leading, isUser ? 0 : -4)
        .animation(.easeInOut(duration: 0.12), value: actionsVisible)
    }

    private var actionsVisible: Bool {
        isHovering || isLatestReply || isSpeaking || selectingText || showUsageDetail || showCopied
    }

    @ViewBuilder
    private var signals: some View {
        let grade = message.role == .assistant ? message.usage.flatMap(cacheGrade) : nil
        let stop = message.role == .assistant ? unexpectedFinishReasonLabel : nil
        if !prefs.showTurnDetails, let grade {
            HStack(spacing: 5) {
                Circle().fill(grade.color).frame(width: 7, height: 7)
                Text(grade.short).sk(11, SK.tertiary)
            }
            .help(grade.tooltip)
        }
        if let stop {
            Text(stop).sk(11, SK.orange).lineLimit(1)
        }
    }

    /// The common three as icons, everything else in a menu.
    private var actions: some View {
        HStack(spacing: 0) {
            ActionIcon(systemImage: showCopied ? "checkmark" : "doc.on.doc", help: "Copy") {
                copyToClipboard()
            }
            if message.role == .assistant, !isErrored {
                ActionIcon(
                    systemImage: isSpeaking ? "speaker.slash" : "speaker.wave.2",
                    help: isSpeaking ? "Stop reading aloud" : "Read aloud",
                    tint: isSpeaking ? theme.accentInk : nil
                ) {
                    app.speech.toggle(messageID: message.id, content: bodyText)
                }
            }
            if !isUser {
                ActionIcon(systemImage: "arrow.clockwise", help: "Regenerate from here (a new branch)", disabled: !isReloadable) {
                    Task { await model.reloadFromMessage(id: message.id) }
                }
            }
            if selectingText {
                ActionIcon(systemImage: "character.cursor.ibeam", help: "Done selecting", tint: theme.accentInk) {
                    model.selectingTextMessageID = nil
                }
            }
            Menu {
                moreMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(showUsageDetail ? Color.white.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(SK.secondary)
            .help("More")
        }
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        if canSelectText {
            Button(selectingText ? "Done Selecting" : "Select Text") {
                model.selectingTextMessageID = selectingText ? nil : message.id
            }
        }
        if isEditableRole {
            Button("Edit") { startEdit() }
        }
        if message.role == .assistant, message.usage != nil || message.modelID != nil {
            Button(showUsageDetail ? "Hide Usage and Cost" : "Usage and Cost") { showUsageDetail.toggle() }
        }
        if isEditableRole {
            Divider()
            Button("Delete…", role: .destructive) { askDelete(cascade: false) }
            if model.hasDescendants(message.id) {
                Button("Delete From Here…", role: .destructive) { askDelete(cascade: true) }
            }
        }
    }

    private func askDelete(cascade: Bool) {
        deleteCascades = cascade
        confirmingDelete = true
    }

    private var deleteDetail: String {
        if deleteCascades {
            let n = model.descendantCount(of: message.id)
            return "This message and the \(n) repl\(n == 1 ? "y" : "ies") under it go."
        }
        return "Replies after it attach to the message before."
    }

    /// "‹ 2/3 ›" when this message has siblings.
    @ViewBuilder
    private var branchSwitcher: some View {
        if let info = model.branchInfo(for: message.id) {
            HStack(spacing: 4) {
                Button {
                    let i = (info.index - 1 + info.siblingIDs.count) % info.siblingIDs.count
                    Task { await model.switchToBranch(siblingID: info.siblingIDs[i]) }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Previous branch")
                .accessibilityLabel("Previous branch")
                Text("\(info.index + 1)/\(info.siblingIDs.count)").sk(11, SK.secondary).monospacedDigit()
                Button {
                    let i = (info.index + 1) % info.siblingIDs.count
                    Task { await model.switchToBranch(siblingID: info.siblingIDs[i]) }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Next branch")
                .accessibilityLabel("Next branch")
            }
            .foregroundStyle(SK.secondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if !model.isDraft {
            Button("Copy") { copyToClipboard() }
            Button(selectingText ? "Done Selecting" : "Select Text") {
                model.selectingTextMessageID = selectingText ? nil : message.id
            }
            .disabled(!canSelectText)
            Button("Edit") { startEdit() }
                .disabled(!isEditableRole)
            Button("Regenerate From Here") {
                Task { await model.reloadFromMessage(id: message.id) }
            }
            .disabled(!isReloadable || isUser)
            Divider()
            Button("Delete…", role: .destructive) { askDelete(cascade: false) }
                .disabled(!isEditableRole)
            if model.hasDescendants(message.id) {
                Button("Delete From Here…", role: .destructive) { askDelete(cascade: true) }
                    .disabled(!isEditableRole)
            }
        }
    }

    // MARK: - Inline editor

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if showsRolePicker {
                    SKSegmented(options: [(PsmithMessageRole.user, "User"), (.assistant, "Assistant")], selection: $editRoleDraft)
                }
                Spacer(minLength: 0)
                Text("Editing").sk(11, SK.tertiary)
            }
            SKTextArea(text: $editDraft, lines: 3)
            HStack(spacing: 8) {
                if showsRolePicker {
                    Text("Save and Resend starts a new branch beside this one.").sk(11.5, SK.tertiary)
                }
                Spacer(minLength: 0)
                Button("Cancel") { model.editingMessage = nil }
                    .skButton()
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveEdit(thenResend: false) }
                    .skButton()
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if showsRolePicker {
                    // Resend forks a new turn, which means nothing for
                    // framing roles; those save content only.
                    Button("Save and Resend") { saveEdit(thenResend: true) }
                        .skButton(.primary)
                        .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isStreaming)
                        .keyboardShortcut(.defaultAction)
                        .help("Save the edit and send it again as a new branch beside the original.")
                }
            }
        }
        .onAppear {
            editDraft = message.content
            editRoleDraft = message.role == .assistant ? .assistant : .user
        }
    }

    private func startEdit() {
        model.selectingTextMessageID = nil
        editDraft = message.content
        editRoleDraft = message.role
        model.editingMessage = message
    }

    /// Save, or save and resend. Resending a user turn forks at the user
    /// level (a sibling under the original's parent). Resending an
    /// assistant turn keeps the edit in place and chains a new reply
    /// after it, so two assistant turns in a row is intended.
    private func saveEdit(thenResend: Bool) {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The server refuses role writes on framing rows even when
        // unchanged, so those send content only.
        let role: PsmithMessageRole? = showsRolePicker ? editRoleDraft : nil
        let id = message.id
        model.editingMessage = nil
        if thenResend, role == .assistant {
            Task {
                await model.editMessage(id: id, content: trimmed, role: .assistant)
                await model.regenerateAssistant(parentMessageID: id)
            }
        } else if thenResend, role == .user {
            let msg = message
            Task { await model.resendBeside(msg, content: trimmed) }
        } else {
            Task { await model.editMessage(id: id, content: trimmed, role: role) }
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        clipboard.write(bodyText)
        showCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            showCopied = false
        }
    }

    private func handleFragmentAction(_ action: FragmentAction) {
        switch action {
        case .compose(let text):
            model.draft = model.draft.isEmpty ? text : model.draft + "\n" + text
        case .send(let text):
            // Off the tip, submitting would extend a stale branch:
            // confirm and fork from this message instead.
            if let latest = model.latestAssistantMessageID, latest != message.id {
                pendingForkText = text
            } else {
                model.draft = text
                Task { await model.send() }
            }
        case .external(let url):
            NSWorkspace.shared.open(url)
        case .plugin:
            // A plugin action only means something inside the panel that
            // rendered it; a transcript fragment has no owner to route to.
            break
        }
    }

    // MARK: - Helpers

    private func setBinding(_ path: ReferenceWritableKeyPath<ConversationViewModel, Set<String>>, _ key: String) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: path].contains(key) },
            set: { on in
                if on { model[keyPath: path].insert(key) } else { model[keyPath: path].remove(key) }
            }
        )
    }

    private var imageAttachments: [PsmithMessageAttachment] { message.attachments.filter { $0.kind == "image" } }
    private var nonImageAttachments: [PsmithMessageAttachment] { message.attachments.filter { $0.kind != "image" } }

    private var roleLabel: String {
        switch message.role {
        case .user: return "USER"
        case .assistant: return "ASSISTANT"
        case .system: return "SYSTEM"
        case .context: return "CONTEXT"
        case .compressionSummary: return "SUMMARY"
        case .unknown: return "?"
        }
    }

    /// First non-empty line of the body, markdown leaders stripped, for
    /// the folded strip.
    private var previewLine: String {
        guard let first = bodyText.split(whereSeparator: \.isNewline).first else { return bodyText }
        var s = String(first).trimmingCharacters(in: .whitespaces)
        for leader in ["# ", "## ", "### ", "- ", "* ", "> "] where s.hasPrefix(leader) {
            s = String(s.dropFirst(leader.count))
            break
        }
        return s.isEmpty ? "(empty)" : s
    }

    private var modelDisplayLabel: String? {
        guard let mid = message.modelID, !mid.isEmpty else { return nil }
        let pid = message.providerID
        let providerLabel = pid.flatMap { model.providerLabels[$0] }
        let modelDisplay = model.availableModels
            .first(where: { $0.modelID == mid && (pid == nil || $0.providerID == pid) })?
            .displayName
        switch (providerLabel, modelDisplay) {
        case let (p?, m?): return "\(p) \(m)"
        case let (p?, nil): return "\(p) \(mid)"
        case let (nil, m?): return m
        case (nil, nil): return mid
        }
    }

    /// A stop reason worth noticing. Clean stops return nil, so the line
    /// is absent on almost every turn.
    private var unexpectedFinishReasonLabel: String? {
        guard let raw = message.finishReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "stop", "end_turn", "tool_use", "tool_calls": return nil
        default: return "Stopped: \(raw.replacingOccurrences(of: "_", with: " ").lowercased())"
        }
    }

    /// Cache-efficiency dot. Providers split on whether `inputTokens`
    /// includes cached tokens: if cache_read > input the source must
    /// report them separately, otherwise they're included.
    private func cacheGrade(_ u: PsmithMessageUsage) -> CacheGrade? {
        guard let input = u.inputTokens, input > 0 else { return nil }
        // No cache fields at all: the provider doesn't report caching.
        guard u.cacheReadTokens != nil || u.cacheWriteTokens != nil else { return nil }
        let cacheRead = u.cacheReadTokens ?? 0
        if cacheRead == 0 && isFirstMeteredReply { return nil }
        let totalPrompt: Int32 = cacheRead > input ? cacheRead + input : input
        // Providers don't cache prompts under roughly 1-4k tokens, so a
        // grade there is noise that teaches you to ignore the dot.
        guard totalPrompt >= Self.cacheGradeFloorTokens else { return nil }
        let ratio = Double(cacheRead) / Double(totalPrompt)
        let pct = Int((ratio * 100).rounded())
        let short = "\(pct)% cached"
        switch ratio {
        case 0.8...: return CacheGrade(color: SK.green, tooltip: "Excellent cache hit: \(pct)% of the prompt served from cache", short: short)
        case 0.3..<0.8: return CacheGrade(color: Color(hex: 0xF5C451), tooltip: "Partial cache hit: \(pct)% of the prompt served from cache", short: short)
        default: return CacheGrade(color: SK.red, tooltip: "Poor cache hit: \(pct)% of the prompt served from cache", short: short)
        }
    }

    /// Prompt size below which the cache dot isn't shown. Above every
    /// major provider's minimum cacheable prefix. Same floor as iOS.
    static let cacheGradeFloorTokens: Int32 = 4_096

    private func usageSummary(_ u: PsmithMessageUsage) -> String {
        var parts: [String] = []
        if let n = u.inputTokens {
            var s = "in \(n.formatted())"
            if let cr = u.cacheReadTokens, cr > 0 { s += " (\(cr.formatted()) cached)" }
            parts.append(s)
        }
        if let cw = u.cacheWriteTokens, cw > 0 { parts.append("cache write \(cw.formatted())") }
        if let n = u.outputTokens { parts.append("out \(n.formatted())") }
        if let c = u.totalCostUsd { parts.append(String(format: "$%.4f", c)) }
        return parts.joined(separator: " · ")
    }

    /// Today: "3:47 PM". Yesterday: "Yesterday 3:47 PM". Older:
    /// "Apr 2 · 3:47 PM".
    private var formattedTimestamp: String? {
        let stamp = message.createdAt
        guard stamp.timeIntervalSince1970 > 0 else { return nil }
        let time = stamp.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(stamp) { return time }
        if Calendar.current.isDateInYesterday(stamp) { return "Yesterday \(time)" }
        return "\(stamp.formatted(date: .abbreviated, time: .omitted)) · \(time)"
    }
}

/// One icon in a message's action row: borderless, with a hover wash.
struct ActionIcon: View {
    let systemImage: String
    let help: String
    var tint: Color? = nil
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && !disabled ? Color.white.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? SK.tertiary.opacity(0.5) : (tint ?? SK.secondary))
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// The user bubble: the theme's bubble color, 16pt corners, a faint ring.
struct UserBubbleChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background { ThemedUserBubbleBackground(cornerRadius: 16) }
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// A message in flight, drawn as the bubble it will become.
struct UserBubble: View {
    let text: String
    var body: some View {
        MarkdownText(text).modifier(UserBubbleChrome())
    }
}

/// Lays its content out at its natural width, capped: a short message
/// gets a short bubble, a long one wraps at the cap.
struct HuggingWidth<Content: View>: View {
    let maxWidth: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HugLayout(maxWidth: maxWidth) { content }
    }

    private struct HugLayout: Layout {
        let maxWidth: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let sub = subviews.first else { return .zero }
            let cap = min(maxWidth, proposal.width ?? maxWidth)
            let ideal = sub.sizeThatFits(.unspecified).width
            let width = min(ideal, cap)
            let height = sub.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            return CGSize(width: width, height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
        }
    }
}

struct CacheGrade {
    let color: Color
    let tooltip: String
    /// "94% cached", beside the dot.
    var short: String = ""
}
