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

    @State private var editDraft: String = ""
    @State private var editRoleDraft: ReeveMessageRole = .user
    @State private var showDeleteConfirm: Bool = false
    @State private var showUsageSheet: Bool = false

    private var isErrored: Bool { message.errorText != nil }

    private var isEditing: Bool {
        model.editingMessage?.id == message.id
    }

    /// User/assistant turns are editable + reloadable. system/context/
    /// compression-summary are framing devices, not user turns.
    private var isEditableRole: Bool {
        switch message.role {
        case .user, .assistant: return true
        default: return false
        }
    }

    private var isReloadable: Bool {
        isEditableRole && !model.isStreaming
    }

    var body: some View {
        roleAlignedContainer {
            bubble
        }
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

    // MARK: - Role alignment + branch switcher

    @ViewBuilder
    private func roleAlignedContainer<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        let cap: CGFloat = paneWidth > 0 ? paneWidth * 0.85 : 720
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                branchSwitcher
                content()
                    .frame(maxWidth: cap, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                content()
                    .frame(maxWidth: cap, alignment: .leading)
                branchSwitcher
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            content()
        }
    }

    /// Branch switcher chevrons. Always visible (no hover on iOS) but
    /// low-contrast so they don't compete with the bubble. Collapses to
    /// a flexible Spacer when the message has no siblings.
    @ViewBuilder
    private var branchSwitcher: some View {
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
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        } else {
            Spacer(minLength: 0)
        }
    }

    // MARK: - Bubble body

    @ViewBuilder
    private var bubble: some View {
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

            // Body — edit-in-place editor when isEditing, otherwise
            // markdown / error text.
            if isEditing {
                editor
            } else if isErrored, let errText = message.errorText, !errText.isEmpty {
                Text(errText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if !message.content.isEmpty {
                    MarkdownText(message.content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !message.content.isEmpty {
                MarkdownText(message.content)
            }

            // Footer — cache-grade dot + token usage summary +
            // timestamp. Always visible (matches Mac); tap opens the
            // detail sheet for the full per-token breakdown. User
            // turns get a slimmer footer (just timestamp) since they
            // carry no usage data.
            footer
        }
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
            Text(roleLabel)
                .font(.caption2)
                .foregroundStyle(isErrored ? .orange : .secondary)
                .fontWeight(isErrored ? .semibold : .regular)
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
            .padding(.top, 2)
            .accessibilityLabel("Show usage details")
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

    // MARK: - Edit-in-place editor

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Role picker — flips the message's role on save. Useful
            // for fork-from-edit cases where the user wants to rewrite
            // a turn with a different speaker.
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

            TextField(
                "Message",
                text: $editDraft,
                axis: .vertical
            )
            .lineLimit(2...12)
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )

            // Two save modes:
            //   - Save        → editMessage (in-place; role flip
            //     allowed). For tweaks, typo fixes, role corrections.
            //   - Save & fork → sendForking (creates a sibling at this
            //     message's parent + a fresh assistant under it).
            //     Only offered for user turns since assistant
            //     regeneration goes through the Reload action instead.
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.editingMessage = nil
                }
                .buttonStyle(.bordered)

                if message.role == .user {
                    Button {
                        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await model.sendForking(content: trimmed, parentMessageID: parentMessageID)
                            model.editingMessage = nil
                        }
                    } label: {
                        Text("Save & fork")
                    }
                    .buttonStyle(.bordered)
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button {
                    let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let roleChanged = editRoleDraft != message.role
                    Task {
                        await model.editMessage(
                            id: message.id,
                            content: trimmed,
                            role: roleChanged ? editRoleDraft : nil
                        )
                        model.editingMessage = nil
                    }
                } label: {
                    Text("Save")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            editDraft = message.content
            editRoleDraft = message.role
        }
    }

    private var parentMessageID: String? {
        // Fork from this message's parent (or nil if this is a root
        // message — fork from the conversation's root).
        message.parentID
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
    }

    private func startEdit() {
        editDraft = message.content
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
