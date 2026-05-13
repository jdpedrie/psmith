import SwiftUI
import ReeveKit
import ReeveUI

/// iOS message bubble. Phase 5f wires per-message actions:
///
///  - **Long-press** → context menu: Edit, Reload (assistant only),
///    Copy, Delete. Mirrors the Mac hover-pill set.
///  - **Edit-in-place**: Edit replaces the bubble's body with a
///    TextField + Save / Cancel buttons. Save updates the message via
///    `model.reloadFromMessage` (forks a new branch from the edit).
///  - **Branch switcher**: chevrons + index ("1/2") rendered inline at
///    the bubble's role-opposite edge. Always visible (iOS has no
///    hover signal); tap to navigate siblings.
///  - **Tap model chip** → `MessageUsageSheet` (`.medium` detent) with
///    the per-turn token + cost + cache breakdown.
struct MessageRow: View {
    let message: ReeveMessage
    let model: ConversationViewModel
    @Environment(\.theme) private var theme
    @Environment(\.chatPaneWidth) private var paneWidth
    @Environment(\.clipboard) private var clipboard

    @State private var showDeleteConfirm: Bool = false
    @State private var showCascadeDeleteConfirm: Bool = false
    @State private var showUsageSheet: Bool = false

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
        // Edit sheet is hoisted to ConversationView via
        // `.sheet(item: $model.editingMessage)` so a single sheet
        // owns the lifecycle. Per-row `.sheet(isPresented:)` with a
        // computed binding raced with @Observable updates and
        // produced an open/close loop on dismiss.
        .alert(
            "Delete message?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                Haptics.notify(.warning)
                Task { await model.deleteMessage(id: message.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This message will be removed. Children stitch to its parent.")
        }
        .alert(
            "Delete this message and all replies?",
            isPresented: $showCascadeDeleteConfirm
        ) {
            Button("Delete all", role: .destructive) {
                Haptics.notify(.warning)
                Task { await model.deleteMessage(id: message.id, cascade: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = descendantCount
            Text("This deletes the message and \(count) repl\(count == 1 ? "y" : "ies") underneath it.")
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
    /// the regular bubble. Long-press still surfaces the full
    /// context menu (edit/delete/copy) so the user can act on the
    /// message without expanding it.
    @ViewBuilder
    private var collapsedHeaderBubble: some View {
        Button(action: toggleHeaderExpansion) {
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
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu { contextMenuItems }
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
            // Anthropic's multimodal grounding guidance). Documents +
            // audio land in later phases; render those silently as
            // nothing here.
            if !imageAttachments.isEmpty {
                attachmentStrip
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
                    MarkdownText(bodyText, cacheKey: markdownCacheKey)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !bodyText.isEmpty {
                MarkdownText(bodyText, cacheKey: markdownCacheKey)
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
            .contextMenu { contextMenuItems }
    }

    /// Image-kind attachments only — the only kind v1 renders inline.
    /// Documents / audio / video fall through; future slices add chip
    /// renderers for them.
    private var imageAttachments: [ReeveMessageAttachment] {
        message.attachments.filter { $0.kind == "image" }
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
            .contextMenu { contextMenuItems }
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
        }
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

    // MARK: - Context menu items

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            startEdit()
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        .disabled(!isEditableRole)

        if message.role != .user {
            Button {
                Task { await model.reloadFromMessage(id: message.id) }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(!isReloadable)
        }

        Button {
            copyToClipboard()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("Delete", systemImage: "trash")
        }

        // "Delete all replies…" only surfaces when the message has at
        // least one descendant — for a leaf, cascade delete behaves
        // identically to plain Delete and the extra item would just be
        // noise. Use the cheap `hasDescendants` check here (single pass
        // / first-match exit) rather than the full `descendantCount`
        // walk; the count is only needed inside the alert message and
        // gets computed lazily there.
        if hasDescendants {
            Button(role: .destructive) {
                showCascadeDeleteConfirm = true
            } label: {
                Label("Delete all replies…", systemImage: "trash.slash")
            }
        }
    }

    /// O(1) probe used by the context menu to decide whether the cascade
    /// affordance is worth surfacing. Backed by the view model's
    /// pre-computed `descendantCountCache`. The precise number comes
    /// from `descendantCount` only when the user opens the cascade alert.
    private var hasDescendants: Bool {
        model.hasDescendants(message.id)
    }

    /// O(1) descendant count for the cascade-delete confirmation alert.
    private var descendantCount: Int {
        model.descendantCount(of: message.id)
    }

    private func startEdit() {
        model.editingMessage = message
    }

    private func copyToClipboard() {
        let text = message.displayContent ?? message.content
        clipboard.write(text)
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
    /// Includes the edited-at timestamp so an in-place edit invalidates
    /// the cache automatically. Settled messages share this key with
    /// every realization, so scroll-back skips parsing entirely.
    private var markdownCacheKey: String {
        let stamp = message.editedAt?.timeIntervalSince1970 ?? 0
        return "\(message.id):\(stamp)"
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
    private func cacheEfficiencyGrade(_ u: ReeveMessageUsage) -> CacheGrade? {
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
    private func usageSummary(_ u: ReeveMessageUsage) -> String {
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
    let message: ReeveMessage
    let model: ConversationViewModel
    @State private var editDraft: String
    @State private var editRoleDraft: ReeveMessageRole
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    init(message: ReeveMessage, model: ConversationViewModel) {
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
                Text("User").tag(ReeveMessageRole.user)
                Text("Assistant").tag(ReeveMessageRole.assistant)
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
