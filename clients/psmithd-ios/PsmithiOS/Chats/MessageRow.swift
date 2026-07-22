import SwiftUI
import PsmithKit
import PsmithUI

/// iOS message bubble. Phase 5f wires per-message actions:
///
///  - **Long-press** → MessageActionMenu: Edit, Reload (assistant
///    only), Copy, Read aloud, Delete. Mirrors the Mac hover-pill
///    set. A custom overlay, NOT `.contextMenu` — the system menu's
///    lift portal renders the row upside down inside the inverted
///    transcript (see MessageActionMenu for the mechanism).
///  - **Edit-in-place**: Edit replaces the bubble's body with a
///    TextField + Save / Cancel buttons. Save updates the message via
///    `model.reloadFromMessage` (forks a new branch from the edit).
///  - **Branch switcher**: chevrons + index ("1/2") rendered inline at
///    the bubble's role-opposite edge. Always visible (iOS has no
///    hover signal); tap to navigate siblings.
///  - **Tap model chip** → `MessageUsageSheet` (`.medium` detent) with
///    the per-turn token + cost + cache breakdown.
struct MessageRow: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.chatPaneWidth) private var paneWidth

    @State private var showUsageSheet: Bool = false
    /// Pending choice text waiting on a fork confirmation. Set when
    /// the user taps a `send:` choice on a non-tip message; cleared
    /// when the confirmation alert resolves either way.
    @State private var pendingForkText: String?

    private var isErrored: Bool { message.errorText != nil }

    private var isEditing: Bool {
        model.editingMessage?.id == message.id
    }

    /// User / assistant turns are editable + reloadable. System and
    /// context rows are also editable (so the user can fix a typo
    /// in their system message without re-editing the profile);
    /// compression-summary stays read-only — its body is owned by
    /// the compression flow.
    private var isEditableRole: Bool {
        switch message.role {
        case .user, .assistant, .system, .context: return true
        default: return false
        }
    }

    /// System + context messages render as a collapsed header strip
    /// by default — framing content the user reads once when setting
    /// up a turn, not on every scroll-back. Tap the strip to expand;
    /// tap the expanded bubble's role chip to collapse back.
    private var isCollapsibleHeaderRole: Bool {
        switch message.role {
        case .system, .context: return true
        default: return false
        }
    }

    private var isHeaderExpanded: Bool {
        model.expandedHeaderMessageIDs.contains(message.id)
    }

    private func toggleHeaderExpansion() {
        if isHeaderExpanded {
            model.expandedHeaderMessageIDs.remove(message.id)
        } else {
            model.expandedHeaderMessageIDs.insert(message.id)
        }
    }

    private var isReloadable: Bool {
        isEditableRole && !model.isStreaming
    }

    var body: some View {
        roleAlignedContainer {
            if isCollapsibleHeaderRole && !isHeaderExpanded {
                collapsedHeaderBubble
            } else if message.role == .assistant && !isErrored && !isEditing {
                // Assistant turns drop the bubble — markdown content
                // reads as page content, full-width. Errored / editing
                // states keep the bubble for visual prominence.
                assistantContent
            } else {
                bubble
            }
        }
        // In-bubble text selection is OFF: the selection interaction's
        // UIKit long-press wins over the action-menu gesture, making
        // the menu unreachable anywhere on the message text (under the
        // old `.contextMenu` the menu interaction preempted selection,
        // so in-bubble long-press selection never worked here either).
        // The menu's "Select text" action opens the full-document
        // reader, which keeps selection enabled.
        .environment(\.markdownTextSelectable, false)
        // Edit sheet is hoisted to ConversationView via
        // `.sheet(item: $model.editingMessage)` so a single sheet
        // owns the lifecycle. Per-row `.sheet(isPresented:)` with a
        // computed binding raced with @Observable updates and
        // produced an open/close loop on dismiss.
        // Delete confirmations live inside MessageActionMenu (in-card
        // morph) — the menu overlay dismisses on action, so an alert
        // anchored here would present from a view mid-removal.
        .alert(
            "Submit choice on an earlier message?",
            isPresented: Binding(
                get: { pendingForkText != nil },
                set: { if !$0 { pendingForkText = nil } }
            ),
            presenting: pendingForkText
        ) { text in
            Button("Fork & Send") {
                Haptics.notify(.success)
                Task { await model.sendForking(content: text, parentMessageID: message.id) }
                pendingForkText = nil
            }
            Button("Cancel", role: .cancel) { pendingForkText = nil }
        } message: { _ in
            Text("This will fork the conversation from this message and submit your choice as a new branch — the current branch stays intact.")
        }
        .sheet(isPresented: $showUsageSheet) {
            NavigationStack {
                MessageUsageSheet(message: message, model: model)
                    .navigationTitle("Usage")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showUsageSheet = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Role alignment + fork-switcher pill

    @ViewBuilder
    private func roleAlignedContainer<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let cap: CGFloat = paneWidth > 0 ? paneWidth * 0.85 : 720
        switch message.role {
        case .user:
            // Right-aligned bubble. Fork pill bumps out of the top-right
            // corner — applied OUTSIDE the bubble's clipShape so the
            // pill isn't trimmed to the rounded rect.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                content()
                    .frame(maxWidth: cap, alignment: .trailing)
                    .overlay(alignment: .topTrailing) {
                        forkPill.offset(x: -6, y: -10)
                    }
            }
        case .assistant:
            // Full-width, no bubble. Fork pill floats above the role
            // label in the top-right corner of the message region —
            // gives the same affordance as the user bump-out without
            // a chrome boundary to anchor against.
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    forkPill
                }
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            content()
        }
    }

    /// Fork-switcher pill — chevron-left / "N/M" / chevron-right in a
    /// capsule. Always visible when the message has siblings; nil view
    /// otherwise (no Spacer reservation, since we now position via
    /// overlay rather than HStack).
    @ViewBuilder
    private var forkPill: some View {
        if let info = model.branchInfo(for: message.id) {
            HStack(spacing: 4) {
                Button {
                    let prevIdx = (info.index - 1 + info.siblingIDs.count) % info.siblingIDs.count
                    Task { await model.switchToBranch(siblingID: info.siblingIDs[prevIdx]) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous branch")

                Text("\(info.index + 1)/\(info.siblingIDs.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    let nextIdx = (info.index + 1) % info.siblingIDs.count
                    Task { await model.switchToBranch(siblingID: info.siblingIDs[nextIdx]) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next branch")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
    }

    // MARK: - Collapsed header (system / context)

    /// One-row strip rendered in place of the full bubble for system
    /// and context messages. Shows the role label, the first line of
    /// the content as a preview, plus a chevron. Tap to expand into
    /// the regular bubble. Long-press still surfaces the action menu
    /// (edit/delete/copy) so the user can act on the message without
    /// expanding it.
    @ViewBuilder
    private var collapsedHeaderBubble: some View {
        // Tap/long-press via explicit gestures, NOT a Button: a
        // Button claims the whole touch and fires its action on
        // release even after a long hold (sim-verified — the strip
        // expanded instead of opening the action menu), whereas
        // side-by-side tap + long-press gestures disambiguate on
        // hold duration.
        HStack(spacing: 10) {
            Image(systemName: message.role == .system ? "gear" : "tray.full")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(roleLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(previewLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { toggleHeaderExpansion() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(roleLabel), \(previewLine)")
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onLongPressGesture { presentActionMenu() }
        .accessibilityAction(named: "Message actions") { presentActionMenu() }
        // Swipe-tray temporarily disabled — its DragGesture
        // intercepted vertical scroll on long messages, making
        // the chat unusable. The long-press action menu (above)
        // still exposes the same actions. See MessageActionTray.swift
        // for the implementation; re-enable once the gesture
        // disambiguation is fixed.
    }

    /// Presents the hoisted MessageActionMenu overlay for this row.
    /// The haptic stands in for the system menu's lift bump.
    private func presentActionMenu() {
        Haptics.impact(.medium)
        withAnimation(.snappy(duration: 0.22)) {
            model.actionMenuMessage = message
        }
    }

    /// First non-empty line of the message body, used as the
    /// collapsed-header preview. Strips markdown leaders (`# `, `- `,
    /// `* `, `> `) so a system message that opens with a heading
    /// still reads like a sentence in the strip.
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

    // MARK: - Bubble body

    /// Inner content shared by the bubble (user/errored/editing) and
    /// the bare assistant rendering. Header + thinking + tool calls +
    /// body + footer, no chrome.
    @ViewBuilder
    private var bubbleInner: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow

            // Thinking disclosure for assistant turns that reasoned.
            if message.role == .assistant, hasThinking {
                ThinkingDisclosure(
                    phase: .settled(durationSec: thinkingDurationSeconds),
                    renderedText: message.thinkingRenderedText ?? "",
                    isExpanded: thinkingExpandedBinding
                )
            }

            // Tool calls — settled disclosures, one per call.
            if message.role == .assistant, !message.toolCalls.isEmpty {
                ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { idx, call in
                    ToolCallSettledDisclosure(
                        call: call,
                        isExpanded: toolCallExpandedBinding(index: idx)
                    )
                }
            }

            // Image attachments — show above the text content (matches
            // the wire order drivers emit: image-block-then-text per
            // Anthropic's multimodal grounding guidance). Non-image
            // kinds (PDF / audio / video) render as compact chips
            // below the image strip — same horizontal layout so a
            // message with mixed kinds reads coherently.
            if !imageAttachments.isEmpty {
                attachmentStrip
            }
            if !nonImageAttachments.isEmpty {
                nonImageAttachmentStrip
            }

            // Body — markdown / error text. Edit happens in a sheet
            // (see ConversationView's hoisted `.sheet(item:)`), not
            // in-place. Prefer `displayContent` (post-DisplayTransformer
            // plugin pipeline output, e.g. with basic_grounding's
            // `<grounding>` block stripped) and fall back to raw
            // `content` for messages that haven't been routed through
            // the transformer.
            let bodyText = message.displayContent ?? message.content
            if isErrored, let errText = message.errorText, !errText.isEmpty {
                Text(errText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if !bodyText.isEmpty {
                    BoundedMarkdownText(bodyText, cacheKey: markdownCacheKey)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if message.role == .assistant {
                    HStack {
                        Spacer()
                        Button {
                            Task { await model.reloadFromMessage(id: message.id) }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.callout)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isStreaming || model.sending)
                    }
                    .padding(.top, 2)
                }
            } else if !message.uiFragments.isEmpty {
                // Server's ContentRenderer pipeline produced a
                // structured rendering — surface that instead of
                // the markdown fallback. Same FragmentView the Mac
                // bubble uses; both platforms share the renderer
                // set in PsmithUI.
                FragmentView(
                    fragments: message.uiFragments,
                    onAction: handleFragmentAction
                )
            } else if !bodyText.isEmpty {
                if message.isWelcome && !model.welcomePlayed.contains(message.id) {
                    // First render of a profile-welcome message in
                    // this app session — animate the reveal. Mark
                    // played when complete so scrolling/navigation
                    // back doesn't replay.
                    WelcomeReveal(text: bodyText) {
                        model.welcomePlayed.insert(message.id)
                    }
                } else {
                    // Bounded: an assistant turn near a large
                    // max_output_tokens can exceed what a single
                    // MarkdownUI layout pass survives (see
                    // MarkdownBudget) — same guard as the summary card.
                    BoundedMarkdownText(bodyText, cacheKey: markdownCacheKey)
                }
            }

            // Footer — cache-grade dot + token usage summary +
            // timestamp. Always visible (matches Mac); tap opens the
            // detail sheet for the full per-token breakdown. User
            // turns get a slimmer footer (just timestamp) since they
            // carry no usage data.
            footer
        }
    }

    @ViewBuilder
    private var bubble: some View {
        bubbleInner
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background { bubbleBackground }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isErrored
                            ? AnyShapeStyle(Color.orange.opacity(0.55))
                            : (isEditing
                               ? AnyShapeStyle(theme.accent.opacity(0.6))
                               : AnyShapeStyle(Color.primary.opacity(0.06))),
                        lineWidth: isErrored || isEditing ? 1.5 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onLongPressGesture { presentActionMenu() }
            .accessibilityAction(named: "Message actions") { presentActionMenu() }
            // Swipe-tray temporarily disabled — see other call site
            // for rationale; the long-press action menu still
            // exposes the same actions.
    }

    /// Image-kind attachments only — rendered as inline thumbnails.
    private var imageAttachments: [PsmithMessageAttachment] {
        message.attachments.filter { $0.kind == "image" }
    }

    /// Everything that isn't an image — documents, audio, video.
    /// Rendered as icon-and-filename chips since there's nothing
    /// thumbnailable.
    private var nonImageAttachments: [PsmithMessageAttachment] {
        message.attachments.filter { $0.kind != "image" }
    }

    /// Horizontal scroll of attachment thumbnails. Tap to expand
    /// into a lightbox view (Phase-1 polish; deferred until users
    /// ask for it — for now the thumbnail itself is the affordance).
    @ViewBuilder
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(imageAttachments) { att in
                    MessageAttachmentImage(attachment: att)
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// Horizontal scroll of icon chips for non-image attachments
    /// (PDF / audio / video). No tap action wired yet — for now the
    /// chip is informational so the user knows what was sent /
    /// what the model saw.
    @ViewBuilder
    private var nonImageAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(nonImageAttachments) { att in
                    MessageAttachmentChip(attachment: att)
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// Bare assistant rendering — no bubble chrome, full-width markdown.
    /// The role-aligned container handles outer alignment and the fork
    /// pill; this view just supplies the content with light vertical
    /// padding so successive turns don't crowd each other.
    @ViewBuilder
    private var assistantContent: some View {
        bubbleInner
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onLongPressGesture { presentActionMenu() }
            .accessibilityAction(named: "Message actions") { presentActionMenu() }
            // Swipe-tray temporarily disabled — see other call site
            // for rationale; the long-press action menu still
            // exposes the same actions.
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isErrored {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.10))
        } else if isEditing {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accent.opacity(0.10))
        } else {
            switch message.role {
            case .user:
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 10).fill(theme.accent.opacity(0.18))
                }
            case .assistant:
                RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)
            default:
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04))
            }
        }
    }

    // MARK: - Header row (role label + model chip + tap-to-show-usage)

    private var headerRow: some View {
        HStack(spacing: 6) {
            if isErrored {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
            // For collapsible-header roles (system / context), the role
            // label doubles as a collapse affordance — tap to fold the
            // bubble back into the strip header.
            if isCollapsibleHeaderRole {
                Button(action: toggleHeaderExpansion) {
                    HStack(spacing: 4) {
                        Text(roleLabel)
                            .font(.caption2)
                            .foregroundStyle(isErrored ? .orange : .secondary)
                            .fontWeight(isErrored ? .semibold : .regular)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse \(roleLabel.lowercased())")
            } else {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(isErrored ? .orange : .secondary)
                    .fontWeight(isErrored ? .semibold : .regular)
            }
            if isErrored {
                Text("FAILED")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 6)
            if let label = modelDisplayLabel {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if showsSpeakerAffordance {
                speakerButton
            }
        }
    }

    // MARK: - Read aloud

    /// Inline speaker on the newest assistant turn (the one the user
    /// most likely wants read back), and on any message currently
    /// speaking/loading so there's always a visible stop control.
    /// Older turns keep the action in the long-press menu.
    private var showsSpeakerAffordance: Bool {
        guard message.role == .assistant, !isErrored, !model.isStreaming else { return false }
        return message.id == model.latestAssistantMessageID
            || app.speech.isPlaying(messageID: message.id)
            || app.speech.isLoading(messageID: message.id)
    }

    @ViewBuilder
    private var speakerButton: some View {
        Button {
            toggleSpeech()
        } label: {
            if app.speech.isLoading(messageID: message.id) {
                ProgressView()
                    .controlSize(.mini)
            } else if app.speech.isPlaying(messageID: message.id) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(theme.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } else {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.speech.isPlaying(messageID: message.id) ? "Stop speaking" : "Read aloud")
    }

    private func toggleSpeech() {
        Haptics.impact(.light)
        let text = message.displayContent ?? message.content
        app.speech.toggle(messageID: message.id, content: text)
    }

    /// In-bubble footer — assistant turns get cache dot + token
    /// summary + timestamp (whole footer is the tap target for the
    /// usage sheet); user/system/context get just the timestamp.
    @ViewBuilder
    private var footer: some View {
        if isEditing {
            EmptyView()
        } else if message.role == .assistant, let usage = message.usage {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    showUsageSheet = true
                } label: {
                    HStack(spacing: 5) {
                        if let grade = cacheEfficiencyGrade(usage) {
                            Circle()
                                .fill(grade.color)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel(grade.tooltip)
                        }
                        Text(usageSummary(usage))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let stamp = formattedTimestamp {
                            Text(stamp)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show usage details")

                if let label = unexpectedFinishReasonLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)
        } else if let stamp = formattedTimestamp {
            HStack {
                Spacer(minLength: 0)
                Text(stamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
    }

    /// Returns a human-friendly label for the message's finish_reason
    /// when it's NOT one of the "normal" terminations — clean stops
    /// (`stop`, `end_turn`, `STOP`, empty/nil) return nil so the line
    /// stays invisible on the overwhelming majority of turns.
    /// Examples surfaced: "Stopped: max tokens", "Stopped: length",
    /// "Stopped: content_filter", "Stopped: SAFETY".
    private var unexpectedFinishReasonLabel: String? {
        guard let raw = message.finishReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let normalized = raw.lowercased()
        switch normalized {
        case "stop", "end_turn", "tool_use", "tool_calls":
            return nil
        default:
            let pretty = raw
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()
            return "Stopped: \(pretty)"
        }
    }


    /// Routes a `FragmentAction` from a renderer into the right
    /// per-conversation handler. `.compose` drops into the
    /// composer for the user to edit + send; `.external` opens
    /// a URL via the system browser. Mirrors the Mac handler in
    /// ConversationView so both platforms have parity behaviour.
    private func handleFragmentAction(_ action: FragmentAction) {
        switch action {
        case .compose(let text):
            if model.draft.isEmpty {
                model.draft = text
            } else {
                model.draft += "\n" + text
            }
        case .send(let text):
            // If this row isn't the current tip, auto-submitting would
            // append onto a stale branch. Confirm + fork off this
            // message instead — the new user reply becomes a sibling
            // under this assistant turn. On tip, behave as before:
            // replace draft and submit so one tap resolves the choice.
            if let latestID = model.latestAssistantMessageID, latestID != message.id {
                pendingForkText = text
            } else {
                model.draft = text
                Task { await model.send() }
            }
        case .external(let url):
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Helpers

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

    /// Stable cache key for the message body's parsed MarkdownContent.
    /// Content-hash keyed (NOT edited-at keyed): the rendered string
    /// itself decides identity, so an edit invalidates automatically
    /// AND the edit sheet can pre-warm the new content's parse off the
    /// main thread BEFORE the server assigns the edit timestamp — with
    /// the timestamp key, the post-edit render always missed the cache
    /// and paid a synchronous main-thread parse (the "editing lags"
    /// report). Settled messages share this key with every
    /// realization, so scroll-back skips parsing entirely.
    private var markdownCacheKey: String {
        Self.markdownKey(id: message.id, body: message.displayContent ?? message.content)
    }

    /// Shared key builder — the prewarm sites (ConversationView's
    /// count-change hook, EditMessageSheet's save) must produce the
    /// exact key this row renders with.
    static func markdownKey(id: String, body: String) -> String {
        "\(id):\(body.count):\(body.hashValue)"
    }

    private var hasThinking: Bool {
        if let txt = message.thinkingRenderedText, !txt.isEmpty { return true }
        if let ms = message.thinkingDurationMs, ms > 0 { return true }
        return false
    }

    private var thinkingDurationSeconds: Double? {
        guard let ms = message.thinkingDurationMs else { return nil }
        return Double(ms) / 1000.0
    }

    private var thinkingExpandedBinding: Binding<Bool> {
        Binding(
            get: { model.expandedThinkingMessageIDs.contains(message.id) },
            set: { newValue in
                if newValue {
                    model.expandedThinkingMessageIDs.insert(message.id)
                } else {
                    model.expandedThinkingMessageIDs.remove(message.id)
                }
            }
        )
    }

    private func toolCallExpandedBinding(index: Int) -> Binding<Bool> {
        let key = "\(message.id):\(index)"
        return Binding(
            get: { model.expandedToolCallKeys.contains(key) },
            set: { newValue in
                if newValue {
                    model.expandedToolCallKeys.insert(key)
                } else {
                    model.expandedToolCallKeys.remove(key)
                }
            }
        )
    }

    // MARK: - Cache grade

    /// Cache-efficiency dot rendered next to the usage summary. Same
    /// heuristic the Mac uses (see Mac MessageRow.cacheEfficiencyGrade):
    /// providers split on whether `inputTokens` includes cached tokens
    /// or excludes them; if cache_read > input the source uses the
    /// "separate" shape, otherwise "includes".
    private func cacheEfficiencyGrade(_ u: PsmithMessageUsage) -> CacheGrade? {
        guard let cacheRead = u.cacheReadTokens, cacheRead > 0,
              let input = u.inputTokens, input > 0 else { return nil }
        let totalPrompt: Int32 = (cacheRead > input) ? (cacheRead + input) : input
        let ratio = Double(cacheRead) / Double(totalPrompt)
        let pct = Int((ratio * 100).rounded())
        let color: Color
        let label: String
        switch ratio {
        case 0.8...:
            color = .green;  label = "Excellent"
        case 0.3..<0.8:
            color = .yellow; label = "Partial"
        default:
            color = .red;    label = "Poor"
        }
        return CacheGrade(color: color, tooltip: "\(label) cache hit — \(pct)% of prompt served from cache")
    }

    // MARK: - Usage summary

    /// One-line summary mirroring Mac's format:
    /// "in: 1,234 (920 cached)  out: 567  cost: $0.0023"
    private func usageSummary(_ u: PsmithMessageUsage) -> String {
        var parts: [String] = []
        if let n = u.inputTokens {
            var inputPart = "in: \(n.formatted())"
            if let cr = u.cacheReadTokens, cr > 0 {
                inputPart += " (\(cr.formatted()) cached)"
            }
            parts.append(inputPart)
        }
        if let cw = u.cacheWriteTokens, cw > 0 {
            parts.append("cw: \(cw.formatted())")
        }
        if let n = u.outputTokens { parts.append("out: \(n.formatted())") }
        if let c = u.totalCostUsd {
            parts.append("$\(String(format: "%.4f", c))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Timestamp

    /// Locale-aware time / day label. Today → "3:47 PM"; yesterday →
    /// "Yesterday 3:47 PM"; older → "Apr 2 · 3:47 PM"; unknown → nil.
    private var formattedTimestamp: String? {
        let stamp = message.createdAt
        guard stamp.timeIntervalSince1970 > 0 else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let timeOnly = stamp.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(stamp) {
            return timeOnly
        }
        if calendar.isDateInYesterday(stamp) {
            return "Yesterday \(timeOnly)"
        }
        return "\(stamp.formatted(date: .abbreviated, time: .omitted)) · \(timeOnly)"
    }
}

// MARK: - Cache grade type

private struct CacheGrade {
    let color: Color
    let tooltip: String
}


/// Modal editor for a single message. Replaces the inline-bubble
/// editor that used to swap into the row body. Hosting the input
/// in a sheet means:
///   - The chat scroll behind it stays put — no reflow when the
///     keyboard opens.
///   - The TextEditor scrolls naturally when content runs long.
///   - Cancel / Save are never hidden behind the keyboard.
///
/// Presented from `ConversationView` via `.sheet(item: $model.editingMessage)`
/// so a single sheet owns the lifecycle — the per-row computed-binding
/// approach raced with @Observable updates and produced an open/close
/// loop on dismiss. Drafts live in @State here (initialized from the
/// message) and `.sheet(item:)` instantiates a fresh struct each time
/// the message changes.
struct EditMessageSheet: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    @State private var editDraft: String
    @State private var editRoleDraft: PsmithMessageRole
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    init(message: PsmithMessage, model: ConversationViewModel) {
        self.message = message
        self.model = model
        _editDraft = State(initialValue: message.content)
        _editRoleDraft = State(initialValue: message.role)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showsRolePicker {
                    rolePicker
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                TextEditor(text: $editDraft)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        model.editingMessage = nil
                    }
                }
                if message.role == .user {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Save") { saveInPlace() }
                            Button("Save & fork") { saveAndFork() }
                        } label: {
                            Text("Save").bold()
                        }
                        .disabled(trimmedEmpty)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            saveInPlace()
                        } label: {
                            Text("Save").bold()
                        }
                        .disabled(trimmedEmpty)
                    }
                }
            }
            .onAppear {
                // `.sheet(item:)` instantiates this view fresh each
                // time the bound message changes, so editDraft is
                // already correct from init — just grab focus.
                editorFocused = true
            }
        }
    }

    private var navTitle: String {
        switch message.role {
        case .user: return "Edit user message"
        case .assistant: return "Edit assistant message"
        case .system: return "Edit system message"
        case .context: return "Edit context message"
        default: return "Edit message"
        }
    }

    /// Role flipping is only meaningful between user and assistant;
    /// system / context / summary roles aren't interchangeable.
    private var showsRolePicker: Bool {
        message.role == .user || message.role == .assistant
    }

    private var rolePicker: some View {
        HStack(spacing: 8) {
            Text("Role")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Role", selection: $editRoleDraft) {
                Text("User").tag(PsmithMessageRole.user)
                Text("Assistant").tag(PsmithMessageRole.assistant)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var trimmedEmpty: Bool {
        editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveInPlace() {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleChanged = showsRolePicker && editRoleDraft != message.role
        // Pre-warm the edited body's parse off the main thread while
        // the RPC is in flight — the content-hash cache key makes the
        // post-edit render a guaranteed hit for the common case where
        // no display transform rewrites the content, instead of a
        // synchronous main-thread parse of the whole edited message.
        MarkdownCache.shared.prewarm(
            [(key: MessageRow.markdownKey(id: message.id, body: trimmed), source: trimmed)]
        )
        Task {
            await model.editMessage(
                id: message.id,
                content: trimmed,
                role: roleChanged ? editRoleDraft : nil
            )
            model.editingMessage = nil
        }
    }

    private func saveAndFork() {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentID = message.parentID
        Task {
            await model.sendForking(content: trimmed, parentMessageID: parentID)
            model.editingMessage = nil
        }
    }
}
