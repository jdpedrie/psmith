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
    /// Drives keyboard focus into the composer the moment the conversation
    /// pane mounts (and again when the conversation switches). Without
    /// this the user has to click into the field after every navigation —
    /// the spec asks for "on entering a chat, the message box should be
    /// immediately focused." The bool is the focus payload (single-field
    /// scope); flipping false→true re-focuses.
    @FocusState private var composerFocused: Bool

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
        .onAppear {
            // Defer to the next runloop so SwiftUI's first layout pass
            // attaches the focus binding to the underlying NSTextField
            // before we set it. Without the defer the assignment lands on
            // a not-yet-mounted field and silently no-ops.
            DispatchQueue.main.async { composerFocused = true }
        }
        .onChange(of: liveConversation.id) { _, _ in
            // Re-focus on every conversation switch — the user navigates
            // between chats with the keyboard and expects to land in the
            // composer immediately.
            DispatchQueue.main.async { composerFocused = true }
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
            // Read the chat pane's actual width once via GeometryReader and
            // hand it down through the env so MessageRow can cap each
            // bubble at a fraction of it. `containerRelativeFrame` looked
            // like the natural fit but proved unreliable here — it didn't
            // constrain the bubble inside the LazyVStack at all (bubbles
            // rendered ~98% of pane regardless of the closure result).
            // GeometryReader + a custom env key is the boring approach
            // that actually works.
            GeometryReader { geo in
                paneScrollBody
                    .environment(\.chatPaneWidth, geo.size.width)
            }
        }
    }

    @ViewBuilder
    private var paneScrollBody: some View {
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
                            StreamingRow(
                                text: model.streamingText,
                                thinkingText: model.streamingThinking,
                                thinkingStartedAt: model.streamingThinkingStartedAt,
                                thinkingFinishedAt: model.streamingThinkingFinishedAt,
                                thinkingExpanded: $model.streamingThinkingExpanded
                            )
                            .id("__streaming__")
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
                        .focused($composerFocused)
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

    /// True when the trailing message in the loaded list is a user turn
    /// awaiting a response — and the composer has nothing typed. Powers
    /// the "Send → Reload" swap: in that state, the prominent button
    /// re-issues the last user message (forking) instead of sending what's
    /// in the composer.
    private var canReload: Bool {
        guard model.draft.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return model.messages.last?.role == .user
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
        } else if canReload {
            Button {
                Task { await model.reloadLastUser() }
            } label: {
                if model.sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(
                model.sending
                || model.hasPendingCompression
                || model.isCompacting
            )
            .help("Reload — re-send the last user message (forks the conversation)")
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
                                Task { await model.selectModel(providerID: m.providerID, modelID: m.modelID) }
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
    @Environment(\.theme) private var theme
    @State private var showDeleteConfirm = false
    @State private var showUsageDetail = false
    @State private var editDraft: String = ""
    /// Editor's role choice — defaults to the message's current role on
    /// edit start. Surfaces a picker in the inline editor so the user can
    /// flip a row between user/assistant when forking. Not persisted to
    /// the original row; only carried into the fork at "Save and Resend".
    @State private var editRoleDraft: ClarkMessageRole = .user
    @State private var showPartialContent = false
    /// Hover state for the in-bubble quick-action menu (Edit / Reload /
    /// Copy). Tracked per-MessageRow @State so each bubble shows its own
    /// menu independently.
    @State private var isHovering: Bool = false
    @Environment(\.chatPaneWidth) private var paneWidth

    private var isEditing: Bool {
        model.editingMessage?.id == message.id
    }

    private var isErrored: Bool {
        message.errorText != nil
    }

    var body: some View {
        roleAlignedContainer {
            bubble
        }
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

    /// Pins user/assistant bubbles to opposite sides of the chat pane and
    /// caps their width at ~85% of the container — matches the Messages
    /// app convention without going edge-to-edge. system / context /
    /// compression-summary rows stay full width since they're framing
    /// devices, not turns. The cap applies to the bubble container only;
    /// text inside still wraps to fit.
    ///
    /// The opposite-side empty space is occupied by the BranchSwitcher
    /// when this message has siblings — "< 1/2 >" sits where the bubble
    /// isn't, so it's always reachable without overlapping content.
    @ViewBuilder
    private func roleAlignedContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // Cap the bubble's width at 85% of the chat pane. Falls back to a
        // reasonable hard cap (720pt) when paneWidth hasn't propagated yet
        // (first-mount race) so the bubble isn't wildly wide for a frame
        // or two before geometry settles.
        let cap: CGFloat = paneWidth > 0 ? paneWidth * 0.85 : 720
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                branchSwitcher  // collapses to flexible Spacer when no siblings
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

    /// Renders the "< 1/2 >" arrows when this message is one of multiple
    /// siblings. Returns an invisible flexible Spacer otherwise so the
    /// HStack still reserves the opposite-side space symmetrically.
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
                }
                .buttonStyle(.plain)
                .help("Previous branch")

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
                }
                .buttonStyle(.plain)
                .help("Next branch")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        } else {
            Spacer(minLength: 0)
        }
    }

    /// The styled message bubble. Extracted so `body` can wrap it in role-
    /// aware horizontal alignment without tangling the visual styling.
    @ViewBuilder
    private var bubble: some View {
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
            // Reasoning disclosure — visible whenever this assistant turn
            // either captured rendered reasoning text or only reported
            // reasoning tokens (provider-without-thoughts case). The
            // disclosure self-disables expansion when there's no text.
            // Expanded state lives on the view-model's
            // `expandedThinkingMessageIDs` set so reloads + the live-row
            // hand-off don't snap it shut.
            if !isEditing, message.role == .assistant, message.hasThinking {
                ThinkingDisclosure(
                    phase: .settled(durationSec: thinkingDurationSeconds(for: message)),
                    renderedText: message.thinkingRenderedText ?? "",
                    isExpanded: thinkingExpandedBinding
                )
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
        // Right-click menu attached HERE — to the inner content VStack
        // BEFORE the bubble's stacked .background(.regularMaterial) +
        // .glassEffect ancestors. Attaching above those modifiers caused
        // macOS 26 to render the menu's anchor preview as a giant black
        // rectangle (Liquid Glass capture path returns black for some
        // material chains). Attached early on bare content the menu
        // host has clean visuals to anchor to and the items render
        // normally.
        .contextMenu { contextMenuItems }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            if isEditing {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.accent.opacity(0.10))
            } else {
                bubbleBackground
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isEditing
                        ? AnyShapeStyle(theme.accent.opacity(0.6))
                        : (isErrored
                            ? AnyShapeStyle(Color.orange.opacity(0.55))
                            : AnyShapeStyle(Color.primary.opacity(0.06))),
                    lineWidth: isErrored ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Hover quick-action menu — overlays a tiny pill of icon buttons
        // in the top-right of the bubble. Overlay (not inline) so it
        // never changes the bubble's footprint as the user mouses over.
        .overlay(alignment: .topTrailing) {
            if isHovering, isEditableRole, !isEditing {
                hoverActions
                    .padding(6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    /// Floating action pill shown on hover. Edit / Reload / Copy. Lives
    /// as an overlay on the bubble so it doesn't change the bubble's
    /// layout — important since the spec calls out the existing bubble
    /// styling and width as something to preserve.
    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 2) {
            hoverButton(systemImage: "pencil", help: "Edit") {
                startEdit()
            }
            hoverButton(
                systemImage: "arrow.clockwise",
                help: "Reload — re-send this message (forks the conversation)",
                disabled: !isReloadable
            ) {
                Task { await model.reloadFromMessage(id: message.id) }
            }
            hoverButton(systemImage: "doc.on.doc", help: "Copy to clipboard") {
                copyToClipboard()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(.thickMaterial)
        )
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1)
    }

    /// Single 22pt icon button used inside the hover actions pill.
    /// `.buttonStyle(.plain)` strips the default macOS button chrome so
    /// each icon reads as a flat affordance — the pill background is the
    /// shared chrome.
    private func hoverButton(
        systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .disabled(disabled)
        .help(help)
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
            // Role picker — server only allows user ↔ assistant flips
            // (system/context/summary are locked). For those roles we hide
            // the picker entirely.
            if isEditableRole {
                Picker("Role", selection: $editRoleDraft) {
                    Text("User").tag(ClarkMessageRole.user)
                    Text("Assistant").tag(ClarkMessageRole.assistant)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
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
                    saveEdit(thenResend: false)
                }
                .buttonStyle(.glass)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Save and Resend") {
                    saveEdit(thenResend: true)
                }
                .buttonStyle(.glassProminent)
                .disabled(
                    editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isStreaming
                )
                .keyboardShortcut(.defaultAction)
                .help("Save the edit and immediately fork — re-send the edited message as a sibling of the original.")
            }
        }
        .onAppear {
            editDraft = message.content
            editRoleDraft = (message.role == .assistant) ? .assistant : .user
        }
    }

    /// Save handler shared by Save and Save-and-Resend.
    ///
    /// - `thenResend == false`: in-place edit via EditMessage. Mutates the
    ///   existing row; the role override is honoured server-side.
    /// - `thenResend == true`: a fork — we issue SendMessage with the
    ///   edited content under the original's parent, leaving the original
    ///   row untouched. This satisfies the spec's "every Reload creates a
    ///   fork, don't edit existing messages" semantics for the resend
    ///   pathway. The plain Save still mutates in place because the spec
    ///   distinguishes the two ("Save" vs "Save and Resend"). If a later
    ///   pass wants Save to also fork, flip both branches to use
    ///   sendForking and drop editMessage from the surface.
    private func saveEdit(thenResend: Bool) {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parentForFork = message.parentID
        let role = editRoleDraft
        model.editingMessage = nil
        if thenResend {
            Task { await model.sendForking(content: trimmed, parentMessageID: parentForFork) }
        } else {
            Task { await model.editMessage(id: message.id, content: trimmed, role: role) }
        }
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

    /// Converts the persisted `thinking_duration_ms` (Int32 ms) into
    /// seconds for the disclosure's "Thought for X.Ys" badge. Returns nil
    /// when the column was unset — older rows from before the column
    /// existed, or live materialisations that didn't observe a thinking
    /// chunk window. The disclosure renders just "Thought" in that case.
    private func thinkingDurationSeconds(for message: ClarkMessage) -> Double? {
        guard let ms = message.thinkingDurationMs else { return nil }
        return Double(ms) / 1000.0
    }

    /// Bridges the disclosure's `isExpanded` Binding to the view-model's
    /// per-message-id set. Reading: contains-check. Writing: insert /
    /// remove the message id depending on the new value. Same semantics
    /// the disclosure would get from a `@State Bool` but the value lives
    /// on the view-model so it survives `load()` reloads and the live-row
    /// hand-off at terminal time.
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
                    .fill(theme.accent.opacity(0.18))
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

    /// Right-click menu items. Mirrors the hover quick-action set MINUS
    /// Copy (Copy is exclusive to the hover affordance because it's the
    /// most-frequent action and keeping it out of the right-click menu
    /// keeps that menu short — closer to a Mac-native context menu). The
    /// hover menu and this menu reuse the same underlying actions; their
    /// disable rules track each other.
    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Edit…") { startEdit() }
            .disabled(!isEditableRole)
        Button("Reload from here") {
            Task { await model.reloadFromMessage(id: message.id) }
        }
        .disabled(!isReloadable)
        Divider()
        Button("Delete", role: .destructive) { showDeleteConfirm = true }
            .disabled(!isEditableRole)
    }

    /// True for user/assistant turns. system/context/compression-summary
    /// rows are framing devices users shouldn't be editing or deleting via
    /// these affordances — admins can still mutate them through other
    /// surfaces.
    private var isEditableRole: Bool {
        switch message.role {
        case .user, .assistant: return true
        default: return false
        }
    }

    /// Reload makes sense for any turn we can fork from — same set as
    /// editable. Disabled mid-stream so the user can't double-fire.
    private var isReloadable: Bool {
        isEditableRole && !model.isStreaming
    }

    /// Click-handler for Edit (hover menu + right-click menu both call
    /// this). Pre-populates the inline editor with the current message
    /// content; the role picker defaults to the row's role.
    private func startEdit() {
        editDraft = message.content
        editRoleDraft = message.role
        model.editingMessage = message
    }

    /// Copy action — used by the hover menu only (intentionally not in the
    /// right-click menu). Falls back to the raw `content` when there's no
    /// displayContent.
    private func copyToClipboard() {
        let text = message.displayContent ?? message.content
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Pending user row (optimistic, pre-RPC)

private struct PendingUserRow: View {
    let text: String
    @Environment(\.theme) private var theme
    @Environment(\.chatPaneWidth) private var paneWidth

    var body: some View {
        // Mirrors `MessageRow`'s role-aligned wrap so the optimistic user
        // bubble is right-aligned + width-capped just like a real one.
        // Without this the pending row pops out as a full-width strip the
        // moment between send-click and the RPC return — visually jarring
        // because every other user row is right-aligned at 85%.
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
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
    /// Reasoning text accumulated during this stream. Populated by the
    /// view-model's `.thinkingDelta` chunk handler. Empty for non-reasoning
    /// turns; non-empty triggers the click-to-expand disclosure.
    let thinkingText: String
    /// Wall-clock the first thinking delta arrived. Nil when reasoning
    /// hasn't started yet (or the model isn't reasoning at all).
    let thinkingStartedAt: Date?
    /// Wall-clock the first text delta arrived after thinking. While this
    /// is nil the badge ticks live; the moment the model flips to producing
    /// the visible answer we freeze the duration display at "Thought for
    /// X.Ys" — same UX the user will see on the materialised history row a
    /// moment later.
    let thinkingFinishedAt: Date?
    /// External binding to the disclosure's open/closed state. Lives on
    /// the ConversationViewModel so the value survives the StreamingRow →
    /// MessageRow swap at terminal time.
    @Binding var thinkingExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("ASSISTANT")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            }
            if let started = thinkingStartedAt {
                ThinkingDisclosure(
                    phase: thinkingFinishedAt.map { f in
                        .settled(durationSec: f.timeIntervalSince(started))
                    } ?? .ticking(since: started),
                    renderedText: thinkingText,
                    isExpanded: $thinkingExpanded
                )
            }
            if text.isEmpty {
                // Don't render a "…" placeholder while thinking is active —
                // the disclosure pill is the visible activity indicator.
                if thinkingStartedAt == nil {
                    Text("…").foregroundStyle(.secondary)
                }
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

// MARK: - Env keys

/// Width of the chat pane (the ScrollView's outer frame), measured by a
/// GeometryReader at the messageScroll level and stamped into the env so
/// MessageRow / StreamingRow can constrain bubble width as a fraction of
/// it. Using GeometryReader → env is the boring-but-reliable alternative
/// to `.containerRelativeFrame`, which we tried first and which silently
/// failed to constrain bubble width in this layout.
private struct ChatPaneWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var chatPaneWidth: CGFloat {
        get { self[ChatPaneWidthKey.self] }
        set { self[ChatPaneWidthKey.self] = newValue }
    }
}

