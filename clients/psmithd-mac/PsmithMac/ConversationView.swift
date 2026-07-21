import SwiftUI
import PsmithKit
import PsmithUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Outer shell

struct ConversationView: View {
    let conversation: PsmithConversation
    let profiles: ProfilesViewModel
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.notifier) private var notifier
    @State private var model: ConversationViewModel?

    /// Always read the latest snapshot from the sidebar list so auto-generated
    /// titles propagate without re-mounting the view.
    private var liveConversation: PsmithConversation {
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
        .onAppear {
            // Mirror iOS: while this conversation is on screen, suppress
            // the sidebar's "new message" dot for it and clear any
            // pending unseen flag — selecting it is the user's "I've
            // seen it" gesture.
            app.streamHub.markViewing(conversationID: conversation.id)
        }
        .onDisappear {
            app.streamHub.markStoppedViewing(conversationID: conversation.id)
        }
        .sheet(item: Binding(
            get: { app.streamHub.activeStream(conversationID: conversation.id)?.pendingElicitations.first },
            set: { _ in /* dismiss handled by ElicitSheet via clearPendingElicitation */ }
        )) { pending in
            ElicitSheet(conversationID: conversation.id, pending: pending)
        }
        .task(id: conversation.id) {
            // Capture the env-injected notifier into the closure so the
            // VM-side firing path doesn't reach into a global. iOS will
            // bind a different `Notifier` here at app construction time.
            let liveNotifier = notifier
            let m = ConversationViewModel(
                conversation: conversation,
                client: app.client,
                hub: app.streamHub,
                outboundQueue: app.outboundQueue,
                connectivity: app.connectivity,
                onTerminal: { [weak convos] in await convos?.refresh() },
                onAssistantTurnComplete: { convID, title, msgID, preview in
                    liveNotifier.generationCompleted(
                        conversationID: convID,
                        conversationTitle: title,
                        messageID: msgID,
                        preview: preview
                    )
                },
                localTitler: AppleFoundationTitler()
            )
            m.speechPlayer = app.speech
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
    let liveConversation: PsmithConversation
    @Environment(AppModel.self) private var app
    /// Drives keyboard focus into the composer the moment the conversation
    /// pane mounts (and again when the conversation switches). Without
    /// this the user has to click into the field after every navigation —
    /// the spec asks for "on entering a chat, the message box should be
    /// immediately focused." The bool is the focus payload (single-field
    /// scope); flipping false→true re-focuses.
    @FocusState private var composerFocused: Bool
    /// System open panel for the paperclip. Drag-and-drop onto the
    /// composer is the other attach path.
    @State private var showingFileImporter = false

    /// While true, the scroll view auto-pins to the streaming bubble's
    /// bottom as new tokens arrive. Flipped false the moment the user
    /// scrolls — no surprise scroll-jacking while they're reading earlier
    /// turns. Re-enabled when the user submits the next message and when
    /// a fresh stream begins.
    @State private var autoFollow = true
    /// Throttle anchor for the streaming-text scroll. Limits scrollTo to
    /// ~10Hz so a 200tok/s stream doesn't pile up animation requests and
    /// produce the jerky stairstep we used to see.
    @State private var lastAutoScroll: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            if model.showingContextList {
                ContextListPane(model: model)
            } else if model.showingCompactView {
                CompactPane(model: model)
            } else if model.showingSettingsView {
                ConversationSettingsView(model: model)
            } else if model.showingModelPicker {
                ConversationModelPicker(model: model)
            } else {
                statusStrip
                if let err = model.compactError {
                    compactErrorBanner(err)
                }
                // loadError surfaced as a dismissible banner above the
                // composer when there ARE messages — replacing the whole
                // pane with "Failed to load" would hide the user's
                // conversation history just because a Send/Regenerate
                // RPC failed. The full-pane error view inside
                // messageScroll only fires when the message list is
                // empty (true initial-load failure).
                if let err = model.loadError, !model.messages.isEmpty {
                    loadErrorBanner(err)
                }
                if let speechErr = app.speech.playbackError {
                    speechErrorBanner(speechErr)
                }
                messageScroll
                if let archivedAt = liveConversation.archivedAt {
                    // The server refuses every mutation on an archived
                    // conversation — the transcript is view-only, so the
                    // composer gives way to the restore affordance.
                    ArchivedBarMac(conversationID: liveConversation.id, archivedAt: archivedAt)
                } else if let pending = model.pendingCompressionSummary {
                    // A pending summary limits the conversation (the
                    // server refuses sends and compacts until it's
                    // resolved) — the composer gives way to the review
                    // verdict.
                    CompressionReviewBar(message: pending, model: model)
                } else {
                    composer
                }
            }
        }
        // Top inset keeps scroll content from bleeding up into the
        // title-bar overlay region. The space itself is filled by the
        // window's solid backgroundColor (set in PsmithMacApp); the AppKit
        // title bar renders its title + buttons over that. Scoped to this
        // pane so the sidebar still extends Notes-style.
        .padding(.top, 28)
        .navigationTitle(navTitle)
        .navigationSubtitle(navSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                leadingToolbarItem
            }
            if !model.showingContextList && !model.showingCompactView && !model.showingSettingsView && !model.showingModelPicker {
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

    private func contextLabel(_ ctx: PsmithContext) -> String {
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
        if model.showingModelPicker { return "Choose model" }
        let raw = liveConversation.title ?? ""
        let base = raw.isEmpty ? "Untitled" : raw
        let cost = model.conversationCost
        if cost > 0 {
            return "\(base) — \(cost.formatted(.currency(code: "USD").precision(.fractionLength(4))))"
        }
        return base
    }

    /// Window-title-bar subtitle. Hidden (empty) on the page-swap screens so
    /// the chrome stays clean — those screens render their own structure.
    private var navSubtitle: String {
        if model.showingContextList || model.showingCompactView || model.showingSettingsView || model.showingModelPicker { return "" }
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
            .scaledFont(.caption)
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
        } else if model.showingModelPicker {
            Button {
                model.showingModelPicker = false
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
                .scaledFont(.caption)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { model.compactError = nil }
                .buttonStyle(.borderless)
                .scaledFont(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    /// Banner shown above the composer when a Send/Regenerate RPC fails
    /// AND there are existing messages to keep visible. Mirrors the
    /// compactError banner's style — dismissible, two-line cap, orange
    /// accent — so the entire pane doesn't blank out for a transient
    /// upstream / RPC failure.
    private func loadErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            // Let the message wrap to natural height — the earlier
            // `.lineLimit(2)` ellipsized server errors right at the
            // noun the user needs to see. fixedSize wins against the
            // HStack layout pressure from the Dismiss button.
            Text(message)
                .scaledFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") { model.loadError = nil }
                .buttonStyle(.borderless)
                .scaledFont(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    /// Read-aloud failure strip. App-wide state (one playback at a
    /// time) surfaced in whichever conversation is frontmost.
    private func speechErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "speaker.slash.fill").foregroundStyle(.orange)
            Text(message)
                .scaledFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") { app.speech.clearError() }
                .buttonStyle(.borderless)
                .scaledFont(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Message scroll

    @ViewBuilder
    private var messageScroll: some View {
        // Full-pane error only when the conversation truly has no
        // messages to show — i.e. a real initial-load failure. For
        // mid-conversation send/regenerate failures, the loadError
        // banner above the composer carries the message and the user
        // keeps their history visible.
        if let err = model.loadError, model.messages.isEmpty {
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
                        // Offline queue — sends captured while the server
                        // was unreachable, waiting for connectivity to
                        // drain them. Rendered like pending user turns so
                        // the user sees their words weren't lost.
                        ForEach(model.queuedEntries) { entry in
                            PendingUserRow(text: entry.content, badge: "Queued")
                                .id("__queued_\(entry.id)__")
                        }
                        if model.isCompacting {
                            CompactingRow(text: model.streamingText).id("__compacting__")
                        } else if !model.streamingText.isEmpty || model.isStreaming {
                            // The shared StreamingRow renders bare (that
                            // matches iOS, where settled assistant turns
                            // have no bubble). The Mac's settled rows DO
                            // bubble, so wrap the live row in the same
                            // chrome — otherwise the text streams naked
                            // and visibly snaps into a bubble at terminal.
                            AssistantBubbleChrome {
                                StreamingRow(
                                    text: model.streamingText,
                                    thinkingText: model.streamingThinking,
                                    thinkingStartedAt: model.streamingThinkingStartedAt,
                                    thinkingFinishedAt: model.streamingThinkingFinishedAt,
                                    thinkingExpanded: $model.streamingThinkingExpanded,
                                    toolCalls: model.streamingToolCalls,
                                    streamingComponents: model.conversation.streamingComponents
                                )
                            }
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
                    if text != nil {
                        // User just submitted — they're on the latest turn,
                        // re-engage auto-follow so their reply scrolls in.
                        autoFollow = true
                        withAnimation { proxy.scrollTo("__pending__", anchor: .top) }
                    }
                }
                .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                    // Fresh stream → assume the user wants to follow it.
                    // (User-initiated scroll below flips this back off.)
                    if !wasStreaming && isStreaming { autoFollow = true }
                }
                .onChange(of: model.streamingText) { _, _ in
                    guard autoFollow else { return }
                    let now = Date()
                    // 100ms throttle: animations span the gap so the eye
                    // sees continuous motion instead of stuttered jumps.
                    if now.timeIntervalSince(lastAutoScroll) >= 0.1 {
                        lastAutoScroll = now
                        withAnimation(.linear(duration: 0.12)) {
                            proxy.scrollTo("__streaming__", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.isCompacting) { _, compacting in
                    if compacting { proxy.scrollTo("__compacting__", anchor: .bottom) }
                }
                .onScrollPhaseChange { _, newPhase in
                    // Any user-initiated motion (drag, wheel, momentum
                    // fling) cancels follow-mode. Programmatic .animating
                    // scrolls (our own scrollTo) are intentionally ignored.
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        autoFollow = false
                    case .idle, .animating:
                        break
                    @unknown default:
                        break
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
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            if app.connectivity.state == .offline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                        .scaledFont(.caption2)
                    Text("Server unreachable — messages queue and send when it's back")
                        .scaledFont(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
            }
            if !model.pendingAttachments.isEmpty || model.attachmentUploadCount > 0 {
                pendingAttachmentStrip
            }
            // One floating glass surface: input on top, model picker + send
            // button on a footer row inside the same capsule. Reads as a
            // single Messages-style composer instead of a stack of widgets.
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 6) {
                    TextField("Send a message — shift-return for newline", text: $model.draft, axis: .vertical)
                        .lineLimit(1...8)
                        .textFieldStyle(.plain)
                        .scaledFont(.body)
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
                        .onKeyPress(KeyEquivalent("v")) {
                            // ⌘V with a file or image on the pasteboard
                            // attaches it (same route as drag-and-drop);
                            // plain text falls through to the field's own
                            // paste. onKeyPress is the working seam here —
                            // onPasteCommand never fires while the AppKit
                            // field editor is first responder.
                            guard NSEvent.modifierFlags.contains(.command) else { return .ignored }
                            return pasteAttachmentIfPresent()
                        }
                        .disabled(model.sending || model.hasPendingCompression || model.isCompacting)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)

                    HStack(spacing: 8) {
                        paperclipButton
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
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: attachableTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                Task { @MainActor in await attach(url: url) }
            }
        }
        // Drag-and-drop is the Mac-native attach path: files from
        // Finder land on the composer.
        .dropDestination(for: URL.self) { urls, _ in
            guard attachmentsSupported else { return false }
            for url in urls {
                Task { @MainActor in await attach(url: url) }
            }
            return true
        }
    }

    // MARK: - Attachments

    /// Kinds the active provider accepts — same table the iOS composer
    /// gates on: Anthropic images+PDFs, Google everything, OpenAI-
    /// compatible images only.
    private var acceptedAttachmentTypes: (image: Bool, document: Bool, audioVideo: Bool) {
        guard let pid = model.selectedProviderID else { return (false, false, false) }
        switch model.providerTypes[pid] {
        case "anthropic":          return (true, true, false)
        case "google":             return (true, true, true)
        case "openai-compatible":  return (true, false, false)
        default:                   return (false, false, false)
        }
    }

    private var attachmentsSupported: Bool {
        let ok = acceptedAttachmentTypes
        return ok.image || ok.document || ok.audioVideo
    }

    private var attachableTypes: [UTType] {
        let ok = acceptedAttachmentTypes
        var types: [UTType] = []
        if ok.image { types.append(.image) }
        if ok.document { types.append(.pdf) }
        if ok.audioVideo { types.append(contentsOf: [.audio, .movie]) }
        return types
    }

    /// Routes a picked/dropped file to the right VM upload: images go
    /// through the preprocessor (resize + thumbnail), everything else
    /// uploads verbatim.
    @MainActor
    private func attach(url: URL) async {
        let isImage = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
        if isImage {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            await model.attachImage(data: data, originalFilename: url.lastPathComponent)
        } else {
            await model.attachFile(from: url)
        }
    }

    /// Attach whatever file/image content is on the general pasteboard.
    /// Returns .handled when an attachment was taken (the field must not
    /// also paste), .ignored for text-only pasteboards so the normal
    /// paste proceeds. Files win over image data — a Finder copy puts
    /// both a file URL and a preview image on the pasteboard, and the
    /// URL is the real payload.
    private func pasteAttachmentIfPresent() -> KeyPress.Result {
        guard attachmentsSupported else { return .ignored }
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            for url in urls {
                Task { @MainActor in await attach(url: url) }
            }
            return .handled
        }
        // Raw image bytes — a screenshot on the clipboard, or "Copy
        // Image" from a browser. Normalized to PNG; the VM's
        // preprocessor handles resize + thumbnail from there.
        if acceptedAttachmentTypes.image,
           pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
           let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            Task { @MainActor in await model.attachImage(data: png, originalFilename: nil) }
            return .handled
        }
        return .ignored
    }

    private var paperclipButton: some View {
        Button {
            showingFileImporter = true
        } label: {
            Image(systemName: "paperclip")
                .scaledFont(.callout)
                .foregroundStyle(attachmentsSupported ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!attachmentsSupported)
        .help(attachmentsSupported
            ? "Attach files — or drop them on the composer"
            : "Attachments not supported by this model")
    }

    /// Pending-attachment strip above the composer: image thumbnails
    /// from the in-memory preview bytes, icon chips for the rest, an
    /// inline ✕ per chip, and a spinner chip while uploads are in
    /// flight.
    private var pendingAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { att in
                    pendingChip(att)
                }
                if model.attachmentUploadCount > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Uploading…")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func pendingChip(_ att: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            if att.mimeType.hasPrefix("image/"), let nsImage = NSImage(data: att.previewData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: att.mimeType == "application/pdf" ? "doc.richtext" : "doc")
                        .foregroundStyle(.secondary)
                    Text(att.originalFilename ?? "File")
                        .scaledFont(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .frame(height: 56)
                .frame(maxWidth: 180)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Button {
                model.removePendingAttachment(fileID: att.fileID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .scaledFont(size: 14)
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove attachment")
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
            // Attachment-only sends are legal (empty text + ≥1 pending
            // attachment); in-flight uploads block Send so a message
            // can't race its own attachment.
            .disabled(
                (model.draft.trimmingCharacters(in: .whitespaces).isEmpty
                    && model.pendingAttachments.isEmpty)
                || model.attachmentUploadCount > 0
                || model.sending
                || model.hasPendingCompression
                || model.isCompacting
            )
        }
    }

    // Groups available models by provider for the picker menu.
    private var groupedModels: [(providerID: String, label: String, models: [PsmithUserModel])] {
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

    /// Logo slug for the currently-selected model's provider. Drives
    /// the composer chip's icon. Native drivers map by type; openai-
    /// compatible providers carry the slug in their preset id (parsed
    /// out of the JSON config and exposed via providerPresetIDs). Nil
    /// when nothing is selected or when we have no logo for the
    /// configured provider — caller falls back to the cpu glyph.
    private var selectedProviderLogoSlug: String? {
        guard let pid = model.selectedProviderID else { return nil }
        return providerLogoSlug(providerID: pid,
                                type: model.providerTypes[pid],
                                presetID: model.providerPresetIDs[pid])
    }

    @ViewBuilder
    private var modelPickerChip: some View {
        if !model.availableModels.isEmpty {
            // The system Menu (legacy) showed a flat dropdown — fine for
            // a few models, awful for many providers × many models. Now
            // a button that opens a full-pane picker page (sibling to
            // Compact / Contexts / Settings) that lists models with
            // their metadata strip + popover, matching the providers
            // settings UX.
            Button {
                model.showingModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    if let slug = selectedProviderLogoSlug {
                        ProviderLogo(slug: slug, size: 14)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "cpu")
                    }
                    Text(selectedModelLabel)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .help("Choose model")
            .fixedSize()
        }
    }

    /// Logo slug for a provider — anthropic and google have static
    /// slugs; openai-compatible providers carry the slug in their
    /// preset id. Returns nil for custom (no preset) configs so the
    /// caller can render a fallback (cpu glyph in the chip, generic
    /// globe in ProviderLogo).
    fileprivate func providerLogoSlug(providerID: String, type: String?, presetID: String?) -> String? {
        switch type {
        case "anthropic": return "anthropic"
        case "google":    return "google-color"
        case "openai-compatible":
            return presetID
        default:
            return nil
        }
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: PsmithMessage
    let model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.clipboard) private var clipboard
    @State private var showDeleteConfirm = false
    @State private var showUsageDetail = false
    @State private var editDraft: String = ""
    /// Editor's role choice — defaults to the message's current role on
    /// edit start. Surfaces a picker in the inline editor so the user can
    /// flip a row between user/assistant when forking. Not persisted to
    /// the original row; only carried into the fork at "Save and Resend".
    @State private var editRoleDraft: PsmithMessageRole = .user
    @State private var showPartialContent = false
    /// Hover state for the in-bubble quick-action menu (Edit / Reload /
    /// Copy). Tracked per-MessageRow @State so each bubble shows its own
    /// menu independently.
    @State private var isHovering: Bool = false
    /// Per-bubble "Copied" toast visibility. Set true in copyToClipboard,
    /// auto-clears after 1.4s. Drives both the swap of the copy icon to
    /// a checkmark and the floating "Copied" capsule overlay.
    @State private var showCopiedToast: Bool = false
    /// Per-bubble expand state for system + context message bodies.
    /// These rows can carry long pasted content (system prompts) or
    /// a compressed prior conversation (context). Default collapsed
    /// to ~4 lines; tap "Show more" to expand. Only relevant when
    /// `isCollapsibleRole` is true; ignored otherwise.
    @State private var bodyExpanded: Bool = false
    /// Pending choice text waiting on a fork confirmation. Set when
    /// the user taps a `send:` choice on a non-tip message; cleared
    /// when the confirmation dialog resolves either way.
    @State private var pendingForkText: String?
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
        .confirmationDialog(
            "Submit choice on an earlier message?",
            isPresented: Binding(
                get: { pendingForkText != nil },
                set: { if !$0 { pendingForkText = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingForkText
        ) { text in
            Button("Fork & Send") {
                Task { await model.sendForking(content: text, parentMessageID: message.id) }
                pendingForkText = nil
            }
            Button("Cancel", role: .cancel) { pendingForkText = nil }
        } message: { _ in
            Text("This will fork the conversation from this message and submit your choice as a new branch — the current branch stays intact.")
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
                        .scaledFont(.caption2, weight: .semibold)
                }
                .buttonStyle(.plain)
                .help("Previous branch")

                Text("\(info.index + 1)/\(info.siblingIDs.count)")
                    .scaledFont(.caption2, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    let nextIdx = (info.index + 1) % info.siblingIDs.count
                    Task { await model.switchToBranch(siblingID: info.siblingIDs[nextIdx]) }
                } label: {
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption2, weight: .semibold)
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
                    .scaledFont(.caption2)
                    .foregroundStyle(isErrored ? .orange : .secondary)
                    .fontWeight(isErrored ? .semibold : .regular)
                if isErrored {
                    Text("FAILED")
                        .scaledFont(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
                if message.editedAt != nil {
                    Text("edited")
                        .scaledFont(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let label = modelDisplayLabel {
                    Text(label)
                        .scaledFont(.caption2)
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
            // Historical tool calls — one settled disclosure per call.
            // Index disambiguates Gemini's reused synthetic ids; the
            // expanded-state set on the view-model is keyed by
            // "<messageID>:<index>".
            if !isEditing, message.role == .assistant, !message.toolCalls.isEmpty {
                ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { idx, call in
                    ToolCallSettledDisclosure(
                        call: call,
                        isExpanded: toolCallExpandedBinding(index: idx)
                    )
                }
            }
            // Attachments — images as inline thumbnails ahead of the
            // text (matches the wire order drivers emit), other kinds
            // as icon-and-filename chips.
            if !isEditing, !imageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(imageAttachments) { att in
                            MessageAttachmentImageMac(attachment: att)
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            if !isEditing, !nonImageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(nonImageAttachments) { att in
                            MessageAttachmentChipMac(attachment: att)
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            if isEditing {
                inlineEditor
            } else if isErrored {
                erroredBody
            } else if !message.uiFragments.isEmpty {
                // Server's ContentRenderer pipeline produced a
                // structured rendering — surface that instead of
                // the markdown fallback. Interactive components
                // (choice_list, card_list links) route their
                // actions through `model` so a tap drops into
                // the composer / opens a URL.
                FragmentView(
                    fragments: message.uiFragments,
                    onAction: handleFragmentAction
                )
            } else {
                let displayText = message.displayContent ?? message.content
                if displayText.isEmpty {
                    Text("(empty)").foregroundStyle(.secondary)
                } else if isCollapsibleRole {
                    collapsibleBody(displayText)
                } else if message.isWelcome && !model.welcomePlayed.contains(message.id) {
                    // First render of a profile-welcome message in this
                    // app session — animate the reveal. Mark played
                    // when the reveal completes so subsequent renders
                    // (scroll, navigation back) show static text.
                    WelcomeReveal(text: displayText) {
                        model.welcomePlayed.insert(message.id)
                    }
                } else {
                    MarkdownText(displayText)
                }
            }
            // Usage summary footer — assistant messages only, when data is present.
            if !isEditing, message.role == .assistant, let usage = message.usage {
                Button { showUsageDetail = true } label: {
                    HStack(spacing: 5) {
                        if let grade = cacheEfficiencyGrade(usage) {
                            // Small dot — green/yellow/red — signals at a
                            // glance how much of the prompt was served
                            // from cache. Tooltip carries the percentage.
                            Circle()
                                .fill(grade.color)
                                .frame(width: 7, height: 7)
                                .help(grade.tooltip)
                        }
                        Text(usageSummary(usage))
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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
            // Kept visible while speaking so a stop control always
            // exists without hunting for the hover position.
            if (isHovering || isSpeaking), isEditableRole, !isEditing {
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
            // Reload is meaningful on assistant rows (regenerate this
            // turn) but not on user rows — there's no semantic for "send
            // my message again" that the user reaches for, and the
            // composer's Send → Reload swap covers the "redo last user
            // turn" case anyway. Hidden entirely (not just disabled) on
            // user rows to keep the pill compact.
            if message.role != .user {
                hoverButton(
                    systemImage: "arrow.clockwise",
                    help: "Reload — re-send this message (forks the conversation)",
                    disabled: !isReloadable
                ) {
                    Task { await model.reloadFromMessage(id: message.id) }
                }
            }
            hoverButton(
                systemImage: showCopiedToast ? "checkmark" : "doc.on.doc",
                help: "Copy to clipboard"
            ) {
                copyToClipboard()
            }
            if message.role == .assistant, message.errorText == nil {
                hoverButton(
                    systemImage: isSpeaking ? "speaker.slash" : "speaker.wave.2",
                    help: isSpeaking ? "Stop speaking" : "Read aloud",
                    tint: isSpeaking ? theme.accent : nil
                ) {
                    app.speech.toggle(
                        messageID: message.id,
                        content: message.displayContent ?? message.content
                    )
                }
            }
            hoverButton(
                systemImage: "trash",
                help: "Delete — children stitch to this message's parent",
                tint: .red
            ) {
                showDeleteConfirm = true
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
        .overlay(alignment: .topTrailing) {
            if showCopiedToast {
                Text("Copied")
                    .scaledFont(.caption2, weight: .medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.thickMaterial))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
                    // Tuck above the pill, slightly inset from its right edge.
                    .offset(x: -4, y: -22)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    /// Single 22pt icon button used inside the hover actions pill.
    /// `.buttonStyle(.plain)` strips the default macOS button chrome so
    /// each icon reads as a flat affordance — the pill background is the
    /// shared chrome.
    private func hoverButton(
        systemImage: String,
        help: String,
        disabled: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(size: 11, weight: .semibold)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            disabled
                ? AnyShapeStyle(.tertiary)
                : (tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
        )
        .disabled(disabled)
        .help(help)
    }

    /// True for system + context rows — both can carry pasted long-form
    /// content (a verbose system prompt, a compressed prior conversation)
    /// that crowds the conversation scroll. We collapse their bodies to
    /// ~4 lines by default with an inline expand affordance.
    private var isCollapsibleRole: Bool {
        message.role == .system || message.role == .context
    }

    /// Approx height for ~4 lines of body text. Body uses .scaledFont(.body)
    /// (~13pt + line spacing); 80pt fits comfortably.
    private static let collapsedBodyHeight: CGFloat = 80

    /// Body for system / context rows. Renders the full MarkdownText but
    /// caps the height + clips when collapsed. A clean clip looked
    /// better than the previous fade-overlay (which tinted the bottom
    /// line yellow on top of the bubble's already-yellow background);
    /// the explicit "Show more" affordance below makes the cut
    /// unambiguous on its own.
    @ViewBuilder
    private func collapsibleBody(_ text: String) -> some View {
        let collapsed = !bodyExpanded
        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: collapsed ? Self.collapsedBodyHeight : .infinity,
                    alignment: .topLeading
                )
                .clipped()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { bodyExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: bodyExpanded ? "chevron.up" : "chevron.down")
                    Text(bodyExpanded ? "Show less" : "Show more")
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                // Without contentShape, Button hits register only on
                // opaque pixels — taps in the gap between the
                // chevron and the text label fell through silently
                // (same bug we hit on the model picker chips).
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    /// Body for an errored assistant turn: shows the error text in full,
    /// plus a disclosure-style group for whatever partial content streamed
    /// Routes a `FragmentAction` from a renderer into the right
    /// per-conversation handler. `.compose` drops into the
    /// composer for the user to edit + send; `.external` opens
    /// a URL via the system browser. Falls through silently for
    /// any future cases the renderer might emit before the
    /// handler grows them.
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
            // append onto a stale branch (or unintentionally extend an
            // older turn the user was just re-reading). Confirm + fork
            // off this message instead — the new user reply becomes a
            // sibling under this assistant turn rather than under the
            // active leaf. On tip, behave as before: replace draft and
            // submit so one tap resolves the choice.
            if let latestID = model.latestAssistantMessageID, latestID != message.id {
                pendingForkText = text
            } else {
                model.draft = text
                Task { await model.send() }
            }
        case .external(let url):
            // System link-safety check + handoff. The host's
            // browser owns final security policy from here.
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
        }
    }

    /// before the failure. Reads as a clear "this attempt failed" surface
    /// that the user can review and retry from. The Retry button forks
    /// off the same parent — produces a new sibling assistant so the
    /// failed turn stays in history (the user can delete it if desired).
    @ViewBuilder
    private var erroredBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errText = message.errorText, !errText.isEmpty {
                Text(errText)
                    .scaledFont(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            let partial = message.displayContent ?? message.content
            if !partial.isEmpty {
                DisclosureGroup(isExpanded: $showPartialContent) {
                    MarkdownText(partial)
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } label: {
                    Text("Partial output streamed before failure")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if message.role == .assistant {
                HStack {
                    Spacer()
                    Button {
                        Task { await model.reloadFromMessage(id: message.id) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .scaledFont(.callout)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(model.isStreaming || model.sending)
                    .help("Re-fire the same turn — produces a new sibling assistant under the same parent.")
                }
                .padding(.top, 2)
            }
        }
    }

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Role picker — server only allows user ↔ assistant flips
            // (system/context/summary are locked). For those roles we hide
            // the picker entirely.
            if showsRolePicker {
                Picker("Role", selection: $editRoleDraft) {
                    Text("User").tag(PsmithMessageRole.user)
                    Text("Assistant").tag(PsmithMessageRole.assistant)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            TextEditor(text: $editDraft)
                .scaledFont(.body)
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
                if showsRolePicker {
                    // Resend forks a new turn — meaningless for framing
                    // roles (system/context), which save content only.
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
        }
        .onAppear {
            editDraft = message.content
            editRoleDraft = (message.role == .assistant) ? .assistant : .user
        }
    }

    /// Save handler shared by Save and Save-and-Resend.
    ///
    /// - `thenResend == false`: in-place edit via EditMessage. Mutates
    ///   the existing row; the role override is honoured server-side.
    /// - `thenResend == true`: behavior depends on `editRoleDraft`:
    ///     - `.user`: fork at the user level — issue SendMessage with the
    ///       edited content under the original's parent. Leaves the
    ///       original row untouched. The new user gets a fresh assistant
    ///       under it; both branches live as siblings.
    ///     - `.assistant`: in-place edit on the existing assistant row,
    ///       then regenerate a NEW assistant chained AFTER the edited
    ///       one. Result: the user sees two assistant messages in a row
    ///       — the edited version, then the freshly generated one. The
    ///       edit's role is preserved exactly. Server-side this maps to
    ///       SendMessage(regenerate=true, parent=editedAssistant);
    ///       upstream LLMs that don't support a wire prefix ending in
    ///       assistant will surface their own error verbatim.
    private func saveEdit(thenResend: Bool) {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Role rides along only for user/assistant — the server rejects
        // role writes on system/context rows even when the value is
        // unchanged, so framing-role edits must send content only.
        let role: PsmithMessageRole? = showsRolePicker ? editRoleDraft : nil
        let messageID = message.id
        let parentForFork = message.parentID
        model.editingMessage = nil

        if thenResend, role == .assistant {
            // Save the edit on the existing assistant row, then chain a
            // new assistant under it. The edit stays; the new generation
            // continues from there. Two assistants in a row is intended.
            Task {
                await model.editMessage(id: messageID, content: trimmed, role: .assistant)
                await model.regenerateAssistant(parentMessageID: messageID)
            }
        } else if thenResend, role == .user {
            // Fork-at-user via SendMessage.
            Task { await model.sendForking(content: trimmed, parentMessageID: parentForFork) }
        } else {
            // Plain save — also the resend path for framing roles, where
            // "resend" has no meaning.
            Task { await model.editMessage(id: messageID, content: trimmed, role: role) }
        }
    }

    /// Cache-efficiency grade rendered as a small colored dot next to
    /// the usage summary. Only present when the assistant's prompt
    /// went through provider-side caching machinery (cache_read OR
    /// cache_write reported); silent otherwise.
    ///
    /// Provider conventions differ on whether `input_tokens` includes
    /// cached tokens or not:
    ///   - Anthropic: input excludes cached. Total prompt =
    ///     input + cache_read.
    ///   - Google / OpenAI: input INCLUDES cached. Total prompt =
    ///     input.
    /// Heuristic: if cache_read > input the source must be the
    /// "separate" shape (otherwise ratio would exceed 1). Else assume
    /// "includes" shape. Same answer for both interpretations on real
    /// data — the heuristic just picks the right denominator.
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

    /// One-line summary: "(in: 1,234 (920 cached)  out: 567  cost: $0.0023)"
    /// — surfaces cache_read inline so cache hits are visible without
    /// clicking through to the popover. Cache-write is rare enough to
    /// only render when present.
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
            parts.append("cache write: \(cw.formatted())")
        }
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
    private func thinkingDurationSeconds(for message: PsmithMessage) -> Double? {
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

    /// One Set entry per (message, tool-call-index) pair. Index, not id,
    /// because Gemini reuses synthetic ids across tool-loop rounds and the
    /// disclosure state must distinguish them.
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

    /// User / assistant turns are editable + reloadable. System and
    /// context rows are also editable (so the user can fix a typo in
    /// their system message without re-editing the profile) — same
    /// matrix as iOS; the clients agreeing on this is the point.
    /// Compression summaries never reach MessageRow (they render as
    /// CompressionSummaryCard, which carries its own standard menu).
    private var isEditableRole: Bool {
        switch message.role {
        case .user, .assistant, .system, .context: return true
        default: return false
        }
    }

    /// Role flipping is only meaningful between user and assistant;
    /// system / context roles aren't interchangeable and the server
    /// rejects the attempt.
    private var showsRolePicker: Bool {
        message.role == .user || message.role == .assistant
    }

    /// Reload makes sense for any turn we can fork from — same set as
    /// editable. Disabled mid-stream so the user can't double-fire.
    private var isReloadable: Bool {
        isEditableRole && !model.isStreaming
    }

    /// This row is currently being read aloud (or its audio is loading).
    private var isSpeaking: Bool {
        app.speech.isPlaying(messageID: message.id)
            || app.speech.isLoading(messageID: message.id)
    }

    private var imageAttachments: [PsmithMessageAttachment] {
        message.attachments.filter { $0.kind == "image" }
    }

    private var nonImageAttachments: [PsmithMessageAttachment] {
        message.attachments.filter { $0.kind != "image" }
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
    /// displayContent. Surfaces a "Copied" toast briefly above the pill
    /// so the user gets confirmation that the action fired (clipboard
    /// writes succeed silently otherwise).
    private func copyToClipboard() {
        let text = message.displayContent ?? message.content
        clipboard.write(text)
        withAnimation(.easeOut(duration: 0.15)) { showCopiedToast = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeIn(duration: 0.2)) { showCopiedToast = false }
        }
    }
}

// MARK: - Pending user row (optimistic, pre-RPC)


// MARK: - Compression summary card


// MARK: - Streaming / compacting / pending rows


private struct CompactingRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.orange)
                Text("COMPACTING")
                    .scaledFont(.caption2, weight: .semibold)
                    .foregroundStyle(.orange)
                ProgressView().controlSize(.mini)
            }
            if text.isEmpty {
                Text("Summarizing conversation…")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                MarkdownText(text)
                    .scaledFont(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Color + tooltip pair for the cache-efficiency dot rendered next to
/// the assistant message's usage summary. Computed by
/// MessageRow.cacheEfficiencyGrade(_:); rendered as a small Circle.
private struct CacheGrade {
    let color: Color
    let tooltip: String
}

// MARK: - Message usage popover

private struct MessageUsagePopover: View {
    let message: PsmithMessage
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

                // Cache section. Renders whenever there's any cache
                // signal — cache_read tokens OR an explicit-cache
                // toggle outcome to report. The "Source" / "Explicit
                // cache" rows let the user distinguish implicit hits
                // (Gemini's automatic) from explicit ones (Psmith
                // attached a cachedContents reference) AND see when
                // the toggle was on but no cache attached this turn
                // (most often: prefix below the per-model minimum).
                let cacheRead = u.cacheReadTokens ?? 0
                let hasExplicitFlag = u.explicitCacheAttached != nil
                if cacheRead > 0 || hasExplicitFlag {
                    section("Cache") {
                        if cacheRead > 0 {
                            row("Cache read", cacheRead.formatted())
                        }
                        if let cw = u.cacheWriteTokens, cw > 0 {
                            row("Cache write", cw.formatted())
                        }
                        if let attached = u.explicitCacheAttached {
                            row(
                                "Explicit cache",
                                attached
                                    ? "Attached"
                                    : "Enabled — not attached this turn"
                            )
                        } else if cacheRead > 0 {
                            row("Source", "Implicit (provider-side)")
                        }
                        if cacheRead > 0,
                           let savings = cacheSavings(message: message, cacheReadTokens: cacheRead) {
                            row("Estimated savings", costStr(savings), bold: true)
                        }
                    }
                }

                // Costs
                let hasCosts = u.inputCostUsd != nil || u.outputCostUsd != nil
                    || u.cacheReadCostUsd != nil || u.cacheWriteCostUsd != nil
                    || u.toolCostUsd != nil
                    || u.totalCostUsd != nil
                if hasCosts {
                    section("Cost (USD)") {
                        if let c = u.inputCostUsd      { row("Input",       costStr(c)) }
                        if let c = u.outputCostUsd     { row("Output",      costStr(c)) }
                        if let c = u.cacheReadCostUsd  { row("Cache read",  costStr(c)) }
                        if let c = u.cacheWriteCostUsd { row("Cache write", costStr(c)) }
                        if let c = u.toolCostUsd       { row("Tools",       costStr(c)) }
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
    private func cacheSavings(message: PsmithMessage, cacheReadTokens: Int32) -> Double? {
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
                .scaledFont(.caption)
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
        .scaledFont(.callout)
    }
}

// MARK: - Env keys

/// Width of the chat pane (the ScrollView's outer frame), measured by a
/// GeometryReader at the messageScroll level and stamped into the env so
/// MessageRow / StreamingRow can constrain bubble width as a fraction of
/// it. Using GeometryReader → env is the boring-but-reliable alternative
/// to `.containerRelativeFrame`, which we tried first and which silently
/// failed to constrain bubble width in this layout.


/// Replaces the composer while the conversation is archived: a
/// thin-material band naming the state, with the restore action. The
/// transcript above stays readable; every mutating control is moot
/// because the server rejects writes on archived conversations.
struct ArchivedBarMac: View {
    let conversationID: String
    let archivedAt: Date
    @Environment(ConversationsModel.self) private var convos

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Archived")
                    .scaledFont(.callout, weight: .semibold)
                Text(archivedAt, style: .date)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unarchive") {
                Task { await convos.unarchive(conversationID) }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}


/// Wraps live streaming content in exactly the chrome the settled
/// assistant MessageRow bubble uses — width cap, material, hairline
/// border, clip — so the StreamingRow → MessageRow swap at terminal
/// is invisible. Keep the values in lockstep with MessageRow's
/// `roleAlignedContainer` + `bubble`; a drift here is a visible jolt
/// at the end of every turn.
struct AssistantBubbleChrome<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.chatPaneWidth) private var paneWidth

    var body: some View {
        let cap: CGFloat = paneWidth > 0 ? paneWidth * 0.85 : 720
        HStack(alignment: .top, spacing: 8) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: cap, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
