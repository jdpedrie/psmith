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
                onTerminal: { [weak convos] in await convos?.refresh() },
                localTitler: AppleFoundationTitler()
            )
            self.model = m
            await m.load()
            // After the message list is in hand, decide whether to fire the
            // on-device titler. Builds a profile lookup map so the
            // ConversationViewModel can resolve `title_provider_kind`
            // through the parent chain without hitting the network.
            let profileMap = Dictionary(uniqueKeysWithValues: convos.profiles.map { ($0.id, $0) })
            await m.maybeGenerateLocalTitle(profilesByID: profileMap)
        }
    }
}

// MARK: - Body

/// Internal so snapshot tests can render with a pre-populated
/// ConversationViewModel (bypassing the load() RPC fired by ConversationView's
/// `task(id:)`). Production code constructs this exclusively from
/// ConversationView; tests are the only other caller.
struct ConversationBody: View {
    @Bindable var model: ConversationViewModel
    let liveConversation: ClarkConversation
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if model.showingContextList {
                ContextListPane(model: model)
            } else if model.showingCompactView {
                CompactPane(model: model)
            } else if model.showingSettingsView {
                ConversationSettingsView(model: model)
            } else {
                statusStrip
                if let err = model.compactError {
                    compactErrorBanner(err)
                }
                messageScroll
                composer
            }
        }
        // Top inset keeps scroll content from bleeding up into the
        // title-bar overlay region. The space itself is filled by the
        // window's solid backgroundColor (set in ClarkMacApp); the AppKit
        // title bar renders its title + buttons over that. Scoped to this
        // pane so the sidebar still extends Notes-style.
        .padding(.top, 28)
        .navigationTitle(navTitle)
        .navigationSubtitle(navSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                leadingToolbarItem
            }
            if !model.showingContextList && !model.showingCompactView && !model.showingSettingsView {
                ToolbarItem(placement: .primaryAction) {
                    settingsButton
                }
                ToolbarItem(placement: .primaryAction) {
                    overflowMenu
                }
            }
            if model.showingCompactView {
                ToolbarItem(placement: .confirmationAction) {
                    compactSubmitButton
                }
            }
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
        if model.tokenCount != nil {
            HStack(spacing: 12) {
                tokenCountChip
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func contextLabel(_ ctx: ClarkContext) -> String {
        if let t = ctx.title, !t.isEmpty { return t }
        if let n = model.contextNumber(for: ctx.id) { return "Context \(n)" }
        return "Context \(ctx.id.prefix(8))"
    }

    /// Active context label for the navigation subtitle. Empty string hides
    /// the subtitle when there's no active context yet.
    private var activeContextSubtitle: String {
        guard let ctx = model.activeContext else { return "" }
        return contextLabel(ctx)
    }

    /// Window-title-bar text. Conversation title in chat mode (with the
    /// cumulative conversation cost appended when > 0, e.g. "Markdown Basics
    /// — $0.0046"); "Contexts" while the contexts page is active; "Compact"
    /// while the compact page is active. The page-swap titles match the
    /// Settings/Profiles pattern and tell the AppKit title bar this is a
    /// discrete screen, not a sub-overlay.
    private var navTitle: String {
        if model.showingContextList { return "Contexts" }
        if model.showingCompactView { return "Compact" }
        if model.showingSettingsView { return "Settings" }
        let base = liveConversation.title?.isEmpty == false ? liveConversation.title! : "Untitled"
        let cost = model.conversationCost
        if cost > 0 {
            return "\(base) — \(cost.formatted(.currency(code: "USD").precision(.fractionLength(4))))"
        }
        return base
    }

    /// Window-title-bar subtitle. Hidden (empty) on the page-swap screens so
    /// the chrome stays clean — those screens render their own structure.
    private var navSubtitle: String {
        if model.showingContextList || model.showingCompactView || model.showingSettingsView { return "" }
        return activeContextSubtitle
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

    /// Single-action toolbar button — opens the full-pane Compact view.
    /// Was a Menu with one item, but SwiftUI's macOS Menu renders single-item
    /// content with zero-height rows (the popup chrome shows but the row is
    /// invisible), so this is wired as a direct Button instead. Add a Menu
    /// wrapper back if/when there's a second action to put alongside compact.
    /// Click flow: opens the Compact page (no popup, no sheet) — the user
    /// edits the prompt + picks a model + hits Compact in the toolbar
    /// confirmation slot.
    private var overflowMenu: some View {
        Button {
            model.showingCompactView = true
        } label: {
            Image(systemName: "wand.and.stars")
        }
        .help("Compact conversation…")
        .disabled(model.hasPendingCompression || model.isCompacting || model.sending)
    }

    /// Trailing toolbar slot while the Compact page is active. Glass-prominent
    /// "Compact" button kicks off the RPC with the page's draft prompt + model
    /// selection as overrides. Disabled when the model picker hasn't resolved
    /// (or the user cleared it) — the request would 412 anyway, no point
    /// waiting for the round trip to surface that.
    @ViewBuilder
    private var compactSubmitButton: some View {
        Button {
            let providerID = model.compactProviderID
            let modelID    = model.compactModelID
            let promptDraft = model.compactPromptDraft
            let trimmed = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let guide   = trimmed.isEmpty ? nil : trimmed
            // Close the page first so the user sees the streaming summary
            // land in the message list, same as the old confirmation flow.
            model.showingCompactView = false
            Task {
                await model.compact(guide: guide, providerID: providerID, modelID: modelID)
            }
        } label: {
            if model.isCompacting {
                ProgressView().controlSize(.small)
            } else {
                Text("Compact")
            }
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!compactFormValid || model.isCompacting || model.sending)
        .help("Run compaction with the prompt and model above")
    }

    /// Compact submission needs three things to be valid:
    ///   - a non-empty prompt (whitespace-only doesn't count),
    ///   - both compactProviderID and compactModelID set,
    ///   - the selected (provider, model) pair must exist in the user's
    ///     enabled models list — otherwise the server will reject with
    ///     "compression model X is not enabled" and the user just sees an
    ///     error toast a beat later. Catch it client-side instead.
    private var compactFormValid: Bool {
        let trimmed = model.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let providerID = model.compactProviderID, !providerID.isEmpty,
              let modelID    = model.compactModelID,    !modelID.isEmpty
        else { return false }
        return app.profiles.availableModels.contains {
            $0.providerID == providerID && $0.modelID == modelID
        }
    }

    /// Leading toolbar slot. Four states (per the project's "no popup
    /// windows" rule and the user's "replace popup with a page" instruction):
    ///   - `showingContextList == true`            → back-chevron Button
    ///   - `showingCompactView == true`            → back-chevron Button
    ///   - `contexts.count <= 1`                   → nothing (hidden)
    ///   - otherwise                               → inbox Button that
    ///                                              opens the full-pane
    ///                                              contexts view
    /// We deliberately do NOT use a SwiftUI Menu here — single-item Menus
    /// render with zero-height content on macOS, and the user's flow is
    /// "open page, pick row, dismiss" which is a page swap, not a popover.
    @ViewBuilder
    private var leadingToolbarItem: some View {
        if model.showingContextList {
            Button {
                model.showingContextList = false
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back to conversation")
            .keyboardShortcut(.cancelAction)
        } else if model.showingCompactView {
            Button {
                model.showingCompactView = false
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back to conversation")
            .keyboardShortcut(.cancelAction)
        } else if model.showingSettingsView {
            Button {
                model.showingSettingsView = false
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back to conversation")
            .keyboardShortcut(.cancelAction)
        } else if model.contexts.count > 1 {
            Button {
                model.showingContextList = true
            } label: {
                Image(systemName: "tray.full")
            }
            .help("View contexts")
        }
    }

    /// Trailing toolbar gear that opens the in-conversation Settings page.
    /// Like the Compact button, this is wired as a direct Button rather than
    /// a single-item Menu (which on macOS renders zero-height rows).
    private var settingsButton: some View {
        Button {
            model.showingSettingsView = true
        } label: {
            Image(systemName: "gearshape")
        }
        .help("Conversation settings")
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
                            CompactingRow(text: model.streamingText).id("__compacting__")
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
                    Image(systemName: "wand.and.stars").foregroundStyle(.orange)
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
                            // shift+Return → insert a literal newline. We
                            // explicitly append "\n" instead of returning
                            // `.ignored`; relying on the default produced
                            // a text-selection extend on macOS instead of a
                            // newline (TextField with axis: .vertical doesn't
                            // route shift+Return to the newline handler).
                            if NSEvent.modifierFlags.contains(.shift) {
                                model.draft.append("\n")
                                return .handled
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
    @State private var showPartialContent = false

    private var isEditing: Bool {
        model.editingMessage?.id == message.id
    }

    private var isErrored: Bool {
        message.errorText != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                if message.editedAt != nil {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let label = modelDisplayLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if isEditing {
                inlineEditor
            } else if isErrored {
                erroredBody
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
                    MessageUsagePopover(message: message, model: model)
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
                        : (isErrored
                            ? AnyShapeStyle(Color.orange.opacity(0.55))
                            : AnyShapeStyle(Color.primary.opacity(0.06))),
                    lineWidth: isErrored ? 1.5 : 1
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

    /// Body for an errored assistant turn: shows the error text in full,
    /// plus a disclosure-style group for whatever partial content streamed
    /// before the failure. Reads as a clear "this attempt failed" surface
    /// that the user can review in the history (and, in a future change,
    /// retry from).
    @ViewBuilder
    private var erroredBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errText = message.errorText, !errText.isEmpty {
                Text(errText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            let partial = message.displayContent ?? message.content
            if !partial.isEmpty {
                DisclosureGroup(isExpanded: $showPartialContent) {
                    MarkdownText(partial)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } label: {
                    Text("Partial output streamed before failure")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    /// "<Provider Label> <Model Display Name>" with graceful fallbacks. Looks
    /// up the human-readable strings via the view-model's loaded providers
    /// list; falls back to raw IDs when either lookup misses (legacy rows,
    /// disabled provider, etc.). Returns nil when there's no model on the row.
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

    /// Tinted glass bubble that matches the macOS 26 design language —
    /// user messages get an accent-tinted glass, assistants get neutral glass,
    /// system/context get a subtle warning tint. Errored assistant turns swap
    /// the neutral tint for an orange wash so the failure reads at a glance.
    @ViewBuilder
    private var bubbleBackground: some View {
        if isErrored {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.10))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        } else {
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
    @State private var showPartialContent = false

    private var isErrored: Bool {
        message.errorText != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: isErrored
                      ? "exclamationmark.triangle.fill"
                      : "wand.and.stars")
                    .foregroundStyle(.orange)
                Text(isErrored ? "Compression failed" : "Compression summary")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                Spacer()
                if !isErrored {
                    Text("Review and promote or delete")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let label = compressionModelLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if isErrored {
                erroredBody
            } else {
                MarkdownText(message.content)
                    .font(.callout)
            }

            HStack(spacing: 8) {
                if isErrored {
                    Spacer()
                    Button("Dismiss") {
                        Task { await model.deleteMessage(id: message.id) }
                    }
                    .buttonStyle(.glassProminent)
                    .help("Remove this failed compaction from the history. You can retry compaction at any time.")
                } else {
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
                            Text("Confirm")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(isPromoting)
                    .help("Confirm the summary, open a fresh context, and continue from there")
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    Color.orange.opacity(isErrored ? 0.55 : 0.35),
                    lineWidth: 1.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Body for an errored compression card: error text in red + an optional
    /// disclosure for any partial summary text streamed before the failure.
    @ViewBuilder
    private var erroredBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errText = message.errorText, !errText.isEmpty {
                Text(errText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !message.content.isEmpty {
                DisclosureGroup(isExpanded: $showPartialContent) {
                    MarkdownText(message.content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } label: {
                    Text("Partial summary streamed before failure")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "<Provider Label> <Model Display Name>" with graceful fallbacks.
    /// Mirrors `MessageRow.modelDisplayLabel` so the failed compression
    /// summary header reads consistently with assistant message rows.
    private var compressionModelLabel: String? {
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
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.orange)
                Text("COMPACTING")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                ProgressView().controlSize(.mini)
            }
            if text.isEmpty {
                Text("Summarizing conversation…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                MarkdownText(text)
                    .font(.callout)
            }
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
    let model: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Model / provider identification — show human-readable labels
            // (provider nicename + model display name) instead of UUIDs / raw
            // model_ids; fall back to the raw value when the lookup misses.
            if message.modelID != nil || message.providerID != nil {
                section("Model") {
                    if let mid = message.modelID {
                        let modelDisplay = model.availableModels
                            .first(where: { $0.modelID == mid && (message.providerID == nil || $0.providerID == message.providerID) })?
                            .displayName
                        row("Model", modelDisplay ?? mid)
                    }
                    if let pid = message.providerID {
                        row("Provider", model.providerLabels[pid] ?? pid)
                    }
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

                // Cache savings — surface the dollar value the user
                // wouldn't have spent on un-cached input. Anthropic gets a
                // 90% discount on cache reads, OpenAI / Google ~50%.
                if let cacheRead = u.cacheReadTokens, cacheRead > 0,
                   let savings = cacheSavings(message: message, cacheReadTokens: cacheRead) {
                    section("Cache") {
                        row("Cache read",  cacheRead.formatted())
                        if let cw = u.cacheWriteTokens, cw > 0 {
                            row("Cache write", cw.formatted())
                        }
                        row("Estimated savings", costStr(savings), bold: true)
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

    /// Estimate cache savings in USD for an assistant message. Computes
    /// `cache_read_tokens × input_price_per_M / 1_000_000 × discount_factor`
    /// where the discount factor is 0.9 for Anthropic (90% off) and 0.5 for
    /// OpenAI / Google (50% off). Returns nil when we can't look up the
    /// model's input pricing.
    private func cacheSavings(message: ClarkMessage, cacheReadTokens: Int32) -> Double? {
        guard let mid = message.modelID else { return nil }
        let pid = message.providerID
        guard let model = self.model.availableModels.first(where: { $0.modelID == mid && (pid == nil || $0.providerID == pid) }),
              let inputPrice = model.pricing?.inputPerMillion,
              inputPrice > 0
        else { return nil }
        let discount: Double = isAnthropicProvider ? 0.9 : 0.5
        return Double(cacheReadTokens) * inputPrice / 1_000_000.0 * discount
    }

    /// True when this message came from the Anthropic driver — used to pick
    /// the cache-savings discount factor (90% on Anthropic, 50% elsewhere).
    /// Falls back to false when the provider's driver type isn't loaded.
    private var isAnthropicProvider: Bool {
        guard let pid = message.providerID,
              let type = self.model.providerTypes[pid] else { return false }
        return type == "anthropic"
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

