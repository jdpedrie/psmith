import SwiftUI
import ClarkKit
import ClarkUI

// MARK: - Outer shell

struct ConversationView: View {
    let conversation: ClarkConversation
    let profiles: ProfilesViewModel
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @State private var model: ConversationViewModel?

    /// Always read the latest snapshot from the sidebar list so auto-generated
    /// titles propagate without re-mounting the view.
    private var liveConversation: ClarkConversation {
        convos.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    var body: some View {
        Group {
            if let model {
                ConversationBody(model: model, liveConversation: liveConversation)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: conversation.id) {
            let m = ConversationViewModel(
                conversation: conversation,
                client: app.client,
                onTerminal: { [weak convos] in await convos?.refresh() }
            )
            self.model = m
            await m.load()
        }
    }
}

// MARK: - Body

private struct ConversationBody: View {
    @Bindable var model: ConversationViewModel
    let liveConversation: ClarkConversation

    var body: some View {
        VStack(spacing: 0) {
            if model.showingContextList {
                ContextListPane(model: model)
            } else {
                statusStrip
                if let err = model.compactError {
                    compactErrorBanner(err)
                }
                messageScroll
                composer
            }
        }
        .navigationTitle(liveConversation.title?.isEmpty == false ? liveConversation.title! : "Untitled")
        .navigationSubtitle(activeContextSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                contextSwitcherMenu
            }
            ToolbarItem(placement: .primaryAction) {
                overflowMenu
            }
        }
        .confirmationDialog(
            "Compact this conversation?",
            isPresented: $model.showCompactConfirm,
            titleVisibility: .visible
        ) {
            Button("Generate summary") {
                Task { await model.compact() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(compactConfirmMessage)
        }
        .task {
            await model.loadContexts()
            await model.loadAvailableModels()
        }
    }

    /// Thin status row above the message scroll: token count + cost chips.
    /// Hidden when there's nothing to show. Floats as a glass strip so it
    /// reads as chrome above the scroll, matching the toolbar's glass.
    @ViewBuilder
    private var statusStrip: some View {
        if model.tokenCount != nil || model.costToDate > 0 {
            HStack(spacing: 12) {
                tokenCountChip
                costChip
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func contextLabel(_ ctx: ClarkContext) -> String {
        ctx.title?.isEmpty == false ? ctx.title! : "Context \(ctx.id.prefix(8))"
    }

    /// Active context label for the navigation subtitle. Empty string hides
    /// the subtitle when there's no active context yet.
    private var activeContextSubtitle: String {
        guard let ctx = model.activeContext else { return "" }
        return contextLabel(ctx)
    }

    private var compactConfirmMessage: String {
        let count = model.messages.filter { $0.role == .user || $0.role == .assistant }.count
        var s = "\(count) message\(count == 1 ? "" : "s") will be summarised. You'll review the summary before it replaces the active context."
        if let count = model.tokenCount, let window = model.contextWindow, window > 0 {
            let pct = Int(Double(count) / Double(window) * 100)
            s += "\n\nCurrent: \(count.formatted()) / \(window.formatted()) tokens (\(pct)%)."
        }
        return s
    }

    @ViewBuilder
    private var tokenCountChip: some View {
        if let count = model.tokenCount, let window = model.contextWindow, window > 0 {
            let fraction = Double(count) / Double(window)
            let color: Color = fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .secondary
            Label {
                Text("\(count.formatted()) / \(window.formatted())")
            } icon: {
                Image(systemName: "text.word.spacing")
            }
            .font(.caption)
            .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var costChip: some View {
        if model.costToDate > 0 {
            Label {
                Text(model.costToDate, format: .currency(code: "USD").precision(.fractionLength(4)))
            } icon: {
                Image(systemName: "dollarsign.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                model.showCompactConfirm = true
            } label: {
                Label("Compact now…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.hasPendingCompression || model.isCompacting || model.sending)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Compact toolbar Menu that lists every context and offers a
    /// "View contexts…" entry to open the full context-list pane.
    /// Lives in the navigation toolbar slot, next to the sidebar toggle,
    /// so the affordance is visible without cluttering the title pill.
    private var contextSwitcherMenu: some View {
        Menu {
            let sorted = model.contexts.sorted {
                ($0.activationTime ?? .distantPast) > ($1.activationTime ?? .distantPast)
            }
            ForEach(sorted) { ctx in
                Button {
                    if ctx.id != model.activeContext?.id {
                        Task { await model.activateContext(ctx.id) }
                    }
                } label: {
                    if ctx.id == model.activeContext?.id {
                        Label(contextLabel(ctx), systemImage: "checkmark")
                    } else {
                        Text(contextLabel(ctx))
                    }
                }
            }
            if !model.contexts.isEmpty {
                Divider()
            }
            Button {
                model.showingContextList = true
            } label: {
                Label("View contexts…", systemImage: "tray.full")
            }
        } label: {
            Image(systemName: "tray.full")
        }
        .menuIndicator(.hidden)
        .help("Switch context")
    }

    private func compactErrorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Compaction failed: \(message)")
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { model.compactError = nil }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Message scroll

    @ViewBuilder
    private var messageScroll: some View {
        if let err = model.loadError {
            EmptyStateView(
                "Failed to load",
                systemImage: "exclamationmark.triangle",
                description: "\(err)"
            )
        } else if model.loading && model.messages.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { msg in
                            if msg.role == .compressionSummary {
                                CompressionSummaryCard(message: msg, model: model)
                                    .id(msg.id)
                            } else {
                                MessageRow(message: msg, model: model)
                                    .id(msg.id)
                            }
                        }
                        // Optimistic user message — shown while sendMessage RPC is in flight.
                        if let pending = model.pendingUserText {
                            PendingUserRow(text: pending)
                                .id("__pending__")
                        }
                        if model.isCompacting {
                            CompactingRow().id("__compacting__")
                        } else if !model.streamingText.isEmpty || model.isStreaming {
                            StreamingRow(text: model.streamingText).id("__streaming__")
                        }
                    }
                    .padding()
                }
                .onAppear {
                    // Scroll the most recent message to the top of the viewport
                    // when first opening this conversation.
                    if let id = model.messages.last?.id {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
                .onChange(of: model.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(model.messages.last?.id, anchor: .top) }
                }
                .onChange(of: model.pendingUserText) { _, text in
                    if text != nil { withAnimation { proxy.scrollTo("__pending__", anchor: .top) } }
                }
                .onChange(of: model.streamingText) { _, _ in
                    proxy.scrollTo("__streaming__", anchor: .bottom)
                }
                .onChange(of: model.isCompacting) { _, compacting in
                    if compacting { proxy.scrollTo("__compacting__", anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if model.hasPendingCompression {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text("Review the compression summary above before sending.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            // One floating glass surface: input on top, model picker + send
            // button on a footer row inside the same capsule. Reads as a
            // single Messages-style composer instead of a stack of widgets.
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 6) {
                    TextField("Send a message — shift-return for newline", text: $model.draft, axis: .vertical)
                        .lineLimit(1...8)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .onKeyPress(.return) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                return .ignored  // Insert newline (default behaviour).
                            }
                            if !model.isStreaming
                                && !model.sending
                                && !model.hasPendingCompression
                                && !model.isCompacting {
                                Task { await model.send() }
                            }
                            return .handled
                        }
                        .disabled(model.sending || model.hasPendingCompression || model.isCompacting)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)

                    HStack(spacing: 8) {
                        modelPickerChip
                        Spacer()
                        sendOrStopButton
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if model.isStreaming {
            Button {
                model.cancelStream()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .keyboardShortcut(".", modifiers: [.command])
        } else {
            Button {
                Task { await model.send() }
            } label: {
                if model.sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(
                model.draft.trimmingCharacters(in: .whitespaces).isEmpty
                || model.sending
                || model.hasPendingCompression
                || model.isCompacting
            )
        }
    }

    // Groups available models by provider for the picker menu.
    private var groupedModels: [(providerID: String, label: String, models: [ClarkUserModel])] {
        let byProvider = Dictionary(grouping: model.availableModels, by: \.providerID)
        return byProvider.keys.sorted().compactMap { id in
            guard let models = byProvider[id], !models.isEmpty else { return nil }
            return (providerID: id, label: model.providerLabels[id] ?? id, models: models)
        }
    }

    private var selectedModelLabel: String {
        if let mid = model.selectedModelID,
           let pid = model.selectedProviderID,
           let m = model.availableModels.first(where: { $0.modelID == mid && $0.providerID == pid }) {
            return m.displayName
        }
        return model.selectedModelID ?? "Default"
    }

    @ViewBuilder
    private var modelPickerChip: some View {
        if !model.availableModels.isEmpty {
            Menu {
                ForEach(groupedModels, id: \.providerID) { group in
                    Section(group.label) {
                        ForEach(group.models) { m in
                            Button {
                                model.selectedProviderID = m.providerID
                                model.selectedModelID    = m.modelID
                            } label: {
                                if m.modelID == model.selectedModelID
                                    && m.providerID == model.selectedProviderID {
                                    Label(m.displayName, systemImage: "checkmark")
                                } else {
                                    Text(m.displayName)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(selectedModelLabel)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: ClarkMessage
    let model: ConversationViewModel
    @State private var showDeleteConfirm = false
    @State private var showUsageDetail = false
    @State private var editDraft: String = ""

    private var isEditing: Bool {
        model.editingMessage?.id == message.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if message.editedAt != nil {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let modelID = message.modelID {
                    Text(modelID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if isEditing {
                inlineEditor
            } else {
                let displayText = message.displayContent ?? message.content
                if displayText.isEmpty {
                    Text("(empty)").foregroundStyle(.secondary)
                } else {
                    MarkdownText(displayText)
                }
            }
            // Usage summary footer — assistant messages only, when data is present.
            if !isEditing, message.role == .assistant, let usage = message.usage {
                Button { showUsageDetail = true } label: {
                    Text(usageSummary(usage))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .popover(isPresented: $showUsageDetail, arrowEdge: .bottom) {
                    MessageUsagePopover(message: message)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            if isEditing {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.10))
            } else {
                bubbleBackground
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isEditing
                        ? AnyShapeStyle(Color.accentColor.opacity(0.6))
                        : AnyShapeStyle(Color.primary.opacity(0.06))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu { contextMenuItems }
        .confirmationDialog(
            "Delete message?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteMessage(id: message.id) }
            }
        } message: {
            Text("This message will be removed from the conversation. Children will be stitched to its parent.")
        }
    }

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $editDraft)
                .font(.body)
                .frame(minHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    model.editingMessage = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    Task { await model.editMessage(id: message.id, content: trimmed) }
                    model.editingMessage = nil
                }
                .buttonStyle(.glassProminent)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { editDraft = message.content }
    }

    /// One-line summary: "(in: 1,234  out: 567  cost: $0.0023)"
    private func usageSummary(_ u: ClarkMessageUsage) -> String {
        var parts: [String] = []
        if let n = u.inputTokens  { parts.append("in: \(n.formatted())") }
        if let n = u.outputTokens { parts.append("out: \(n.formatted())") }
        if let c = u.totalCostUsd {
            parts.append("cost: \(c.formatted(.currency(code: "USD").precision(.fractionLength(4))))")
        }
        return parts.isEmpty ? "" : "(\(parts.joined(separator: "  ")))"
    }

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

    /// Tinted glass bubble that matches the macOS 26 design language —
    /// user messages get an accent-tinted glass, assistants get neutral glass,
    /// system/context get a subtle warning tint.
    @ViewBuilder
    private var bubbleBackground: some View {
        switch message.role {
        case .user:
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.18))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .assistant:
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        case .system, .context, .compressionSummary:
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.yellow.opacity(0.10))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .unknown:
            Color.clear
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Edit…") {
            model.editingMessage = message
        }
        .disabled(message.role == .system || message.role == .context)

        Divider()

        Button("Copy") {
            let text = message.displayContent ?? message.content
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        Divider()

        Button("Delete", role: .destructive) {
            showDeleteConfirm = true
        }
        .disabled(message.role == .system || message.role == .context)
    }
}

// MARK: - Pending user row (optimistic, pre-RPC)

private struct PendingUserRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("USER")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            }
            MarkdownText(text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(0.7)
    }
}

// MARK: - Compression summary card

private struct CompressionSummaryCard: View {
    let message: ClarkMessage
    let model: ConversationViewModel
    @State private var showDeleteConfirm = false
    @State private var isPromoting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                Text("Compression summary")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                Spacer()
                Text("Review and promote or delete")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            MarkdownText(message.content)
                .font(.callout)

            HStack(spacing: 8) {
                Button("Edit…") {
                    model.editingMessage = message
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Delete") {
                    showDeleteConfirm = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .confirmationDialog(
                    "Delete compression summary?",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete summary", role: .destructive) {
                        Task { await model.deleteMessage(id: message.id) }
                    }
                } message: {
                    Text("The conversation will resume in the current context as if compaction never happened.")
                }

                Button {
                    isPromoting = true
                    Task {
                        await model.promoteCompaction(messageID: message.id)
                        isPromoting = false
                    }
                } label: {
                    if isPromoting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Promote to new context", systemImage: "arrow.up.forward")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isPromoting)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Streaming / compacting / pending rows

private struct StreamingRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ASSISTANT")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            }
            if text.isEmpty {
                Text("…").foregroundStyle(.secondary)
            } else {
                MarkdownText(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct CompactingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Summarizing conversation…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Message usage popover

private struct MessageUsagePopover: View {
    let message: ClarkMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Model / provider identification
            if message.modelID != nil || message.providerID != nil {
                section("Model") {
                    if let id = message.modelID    { row("Model",    id) }
                    if let id = message.providerID { row("Provider", id) }
                }
            }

            if let u = message.usage {
                // Token counts
                let hasTokens = u.inputTokens != nil || u.outputTokens != nil
                    || u.cacheReadTokens != nil || u.cacheWriteTokens != nil
                    || u.reasoningTokens != nil
                if hasTokens {
                    section("Tokens") {
                        if let n = u.inputTokens      { row("Input",       n.formatted()) }
                        if let n = u.outputTokens     { row("Output",      n.formatted()) }
                        if let n = u.cacheReadTokens  { row("Cache read",  n.formatted()) }
                        if let n = u.cacheWriteTokens { row("Cache write", n.formatted()) }
                        if let n = u.reasoningTokens  { row("Reasoning",   n.formatted()) }
                    }
                }

                // Costs
                let hasCosts = u.inputCostUsd != nil || u.outputCostUsd != nil
                    || u.cacheReadCostUsd != nil || u.cacheWriteCostUsd != nil
                    || u.totalCostUsd != nil
                if hasCosts {
                    section("Cost (USD)") {
                        if let c = u.inputCostUsd      { row("Input",       costStr(c)) }
                        if let c = u.outputCostUsd     { row("Output",      costStr(c)) }
                        if let c = u.cacheReadCostUsd  { row("Cache read",  costStr(c)) }
                        if let c = u.cacheWriteCostUsd { row("Cache write", costStr(c)) }
                        if let c = u.totalCostUsd      { row("Total",       costStr(c), bold: true) }
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280)
    }

    private func costStr(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(6)))
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(bold ? .primary : .secondary)
        }
        .font(.callout)
    }
}

