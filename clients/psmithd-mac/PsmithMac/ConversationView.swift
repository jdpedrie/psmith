import SwiftUI
import PsmithKit
import PsmithUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Outer shell

/// A conversation, or a new one that doesn't exist on the server until
/// its first message is sent (the draft). The draft's view model gains a
/// server id at that send; the screen stays the same.
struct ConversationView: View {
    private let existing: PsmithConversation?
    private let draftID: UUID?
    /// Called once a draft's first send has created the conversation.
    private let onCreated: (PsmithConversation) -> Void
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.notifier) private var notifier
    @State private var model: ConversationViewModel?

    init(conversation: PsmithConversation) {
        existing = conversation
        draftID = nil
        onCreated = { _ in }
    }

    init(newConversation draftID: UUID, onCreated: @escaping (PsmithConversation) -> Void) {
        existing = nil
        self.draftID = draftID
        self.onCreated = onCreated
    }

    private var conversationID: String { model?.conversation.id ?? existing?.id ?? "" }

    /// The latest snapshot from the sidebar list, so an auto-generated
    /// title propagates without remounting.
    private var liveConversation: PsmithConversation? {
        guard let model else { return nil }
        return convos.conversations.first(where: { $0.id == model.conversation.id }) ?? model.conversation
    }

    var body: some View {
        Group {
            if let model, let live = liveConversation {
                ConversationBody(model: model, liveConversation: live)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // While this conversation is on screen its sidebar row gets
            // no "new message" dot; opening it is the user's "I've seen it".
            if !conversationID.isEmpty {
                app.streamHub.markViewing(conversationID: conversationID)
            }
        }
        .onChange(of: model?.conversation.id) { _, id in
            if let id, !id.isEmpty { app.streamHub.markViewing(conversationID: id) }
        }
        .onDisappear {
            app.streamHub.markStoppedViewing(conversationID: conversationID)
        }
        .sheet(item: Binding(
            get: { app.streamHub.activeStream(conversationID: conversationID)?.pendingElicitations.first },
            set: { _ in /* ElicitSheet clears its own pending entry */ }
        )) { pending in
            ElicitSheet(conversationID: conversationID, pending: pending)
        }
        // Coming back online: the transcript may have moved on another
        // client while this one couldn't hear about it.
        .onChange(of: app.connectivity.state) { old, new in
            guard old == .offline, new == .online, let model, !model.isDraft else { return }
            Task { await model.reloadAfterReconnect() }
        }
        .task(id: existing?.id ?? draftID?.uuidString ?? "") {
            let m = makeModel()
            m.localTitleProfilesByID = Dictionary(uniqueKeysWithValues: convos.profiles.map { ($0.id, $0) })
            if existing == nil {
                m.onConversationCreated = { [weak convos] created in
                    convos?.didCreate(created)
                    onCreated(created)
                }
                model = m
                if let profile = convos.profiles.first(where: { $0.isDefault && !$0.parentOnly }) {
                    await m.chooseDraftProfile(profile)
                } else {
                    await m.loadAvailableModels()
                }
                return
            }
            // Cache-first entry: the cached transcript renders this
            // frame and the network load replaces it.
            await m.hydrateFromCache()
            model = m
            await m.load()
            await m.maybeGenerateLocalTitle(profilesByID: m.localTitleProfilesByID)
        }
    }

    private func makeModel() -> ConversationViewModel {
        let liveNotifier = notifier
        let onTerminal: @MainActor () async -> Void = { [weak convos] in await convos?.refresh() }
        let onComplete: @MainActor (String, String?, String, String) -> Void = { convID, title, msgID, preview in
            liveNotifier.generationCompleted(conversationID: convID, conversationTitle: title, messageID: msgID, preview: preview)
        }
        let m: ConversationViewModel
        if let existing {
            m = ConversationViewModel(
                conversation: existing,
                client: app.client,
                hub: app.streamHub,
                outboundQueue: app.outboundQueue,
                connectivity: app.connectivity,
                onTerminal: onTerminal,
                onAssistantTurnComplete: onComplete,
                localTitler: AppleFoundationTitler()
            )
        } else {
            m = ConversationViewModel.draft(
                client: app.client,
                hub: app.streamHub,
                outboundQueue: app.outboundQueue,
                connectivity: app.connectivity,
                onTerminal: onTerminal,
                onAssistantTurnComplete: onComplete,
                localTitler: AppleFoundationTitler()
            )
        }
        m.speechPlayer = app.speech
        return m
    }
}

// MARK: - Body

/// Scroll metrics written on every geometry tick. A reference box, so the
/// write doesn't invalidate any view body; only the derived flags that
/// change rarely are @State.
private final class ScrollMetricsBox {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var distanceFromBottom: CGFloat = 0
}

/// Internal so snapshot and event tests can render it with a prepared
/// view model, bypassing the load in ConversationView's task.
struct ConversationBody: View {
    @Bindable var model: ConversationViewModel
    let liveConversation: PsmithConversation
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.theme) private var theme

    /// Bumped to move keyboard focus into the composer: on entry and on
    /// every conversation switch.
    @State private var composerFocusRequest = 0
    @State private var showingFileImporter = false
    @State private var showingMenu = false

    // THE TRANSCRIPT. An eager VStack, so every row is laid out at entry
    // and every offset is a fact, not a LazyVStack estimate (the
    // estimate physics behind every scroll bug iOS ever had; see
    // docs/clients/chat-scroll.md). The steady states are rest-edge
    // states: at the bottom, following; or wherever the user put it.
    //
    // Streaming is follow-then-park, as on iOS. While the viewport sits
    // at the bottom, content growth re-pins it there. The streaming row
    // is clipped to one viewport, so once the reply fills the view the
    // content stops growing and the reply's first line rests at the
    // top; the tail accumulates under the clip. At terminal the clip
    // goes, and since nothing re-pins, the viewport stays on the start
    // of the reply. Any user scroll detaches immediately.
    /// Bumped by the jump-to-latest button, which lives outside the
    /// scroll view's reader.
    @State private var bottomRequest = 0
    @State private var metrics = ScrollMetricsBox()
    /// The viewport is at the newest edge and should stay there as
    /// content grows.
    @State private var following = true
    /// A user gesture is moving the viewport.
    @State private var userScrolling = false
    @State private var farFromBottom = false
    /// Height cap for the streaming row, armed at stream start.
    @State private var streamClip: CGFloat?
    /// A reply is streaming (as far as this view has handled it).
    @State private var streamActive = false
    /// The live reply's natural height, to tell whether the clip is cutting.
    @State private var streamRowHeight: CGFloat = 0

    private static let columnMaxWidth: CGFloat = 820
    private static let bottomID = "__newest_edge__"

    private var isPage: Bool {
        model.showingContextList || model.showingCompactView || model.showingSettingsView || model.showingModelPicker
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.showingContextList {
                ContextListPane(model: model).padding(.top, 28)
            } else if model.showingCompactView {
                CompactPane(model: model).padding(.top, 28)
            } else if model.showingSettingsView {
                ConversationSettingsView(model: model).padding(.top, 28)
            } else if model.showingModelPicker {
                ConversationModelPicker(model: model).padding(.top, 28)
            } else {
                transcript
            }
        }
        .background(theme.chrome)
        .navigationTitle(navTitle)
        .navigationSubtitle(navSubtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                leadingToolbarItem
            }
            if !isPage {
                if !model.isDraft {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.showingSettingsView = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .help("Conversation settings")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingMenu = true
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .help("Compress, contexts, and cost")
                        .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
                            ConversationMenuMac(model: model, dismiss: { showingMenu = false })
                        }
                    }
                }
            }
            if model.showingCompactView {
                ToolbarItem(placement: .confirmationAction) {
                    compactSubmitButton
                }
            }
        }
        .task(id: liveConversation.id) {
            guard !model.isDraft else { return }
            await model.loadContexts()
            await model.loadAvailableModels()
        }
        .onAppear {
            // The message box is focused on entering a chat. A selection
            // mode left on from an earlier visit ends first: its text view
            // and the composer would otherwise take key focus from each other.
            model.selectingTextMessageID = nil
            composerFocusRequest += 1
        }
        .onChange(of: liveConversation.id) { _, _ in
            model.selectingTextMessageID = nil
            composerFocusRequest += 1
        }
    }

    // MARK: Titles

    private var navTitle: String {
        if model.showingContextList { return "Contexts" }
        if model.showingCompactView { return "Compress" }
        if model.showingSettingsView { return "Settings" }
        if model.showingModelPicker { return "Choose Model" }
        if model.isDraft { return "New Conversation" }
        let raw = liveConversation.title ?? ""
        return raw.isEmpty ? "Untitled" : raw
    }

    /// The active context, only when there's more than one to tell apart.
    private var navSubtitle: String {
        guard !isPage, model.contexts.count > 1, let ctx = model.activeContext else { return "" }
        if let t = ctx.title, !t.isEmpty { return t }
        if let n = model.contextNumber(for: ctx.id) { return "Context \(n)" }
        return ""
    }

    // MARK: Transcript

    private var transcript: some View {
        GeometryReader { geo in
            let column = min(geo.size.width - 48, Self.columnMaxWidth)
            scrollBody
                .environment(\.chatPaneWidth, column)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isDraft {
                        DraftProfilePaneMac(model: model, profiles: convos.profiles)
                            .frame(maxWidth: column + 32)
                            .frame(maxWidth: .infinity)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 6) {
                        banners
                        bottomBar
                    }
                    .frame(maxWidth: column + 32)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .top) {
                        if farFromBottom && !isPage {
                            jumpToBottomButton.offset(y: -44)
                        }
                    }
                }
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
        // Drag-and-drop is the Mac-native attach path: files from Finder
        // dropped anywhere on the conversation.
        .dropDestination(for: URL.self) { urls, _ in
            guard attachmentsSupported else { return false }
            for url in urls {
                Task { @MainActor in await attach(url: url) }
            }
            return true
        }
    }

    @ViewBuilder
    private var scrollBody: some View {
        if let err = model.loadError, model.messages.isEmpty, !model.isDraft {
            EmptyStateView("Failed to load", systemImage: "exclamationmark.triangle", description: "\(err)")
        } else if model.loading && model.messages.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ChatHistoryAreaMac(model: model)
                    PendingAreaMac(model: model)
                    if model.isCompacting {
                        CompactingRow(text: model.streamingText).id("__compacting__")
                    } else if !model.streamingText.isEmpty || model.isStreaming {
                        streamingRow.id("__streaming__")
                    }
                }
                .frame(maxWidth: Self.columnMaxWidth, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                // The newest edge, as an id: proxy scrolls always run,
                // where re-setting a ScrollPosition to the edge it already
                // holds is a no-op and a single append never followed.
                Color.clear.frame(height: 1).id(Self.bottomID)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollGeometrySample.self) { g in
                ScrollGeometrySample(
                    contentHeight: g.contentSize.height,
                    viewportHeight: g.containerSize.height,
                    // The offset runs against the full visible rect, which
                    // includes the toolbar and composer insets.
                    distanceFromBottom: g.contentSize.height + g.contentInsets.bottom - g.visibleRect.height - g.contentOffset.y
                )
            } action: { old, new in
                // The settled reply replaces the live row in one update,
                // and layout can run before onChange hears the stream
                // end. Whichever sees it first ends the stream, before
                // any pin to the bottom.
                if streamActive, !model.isStreaming { endStream(proxy) }
                metrics.contentHeight = new.contentHeight
                metrics.viewportHeight = new.viewportHeight
                metrics.distanceFromBottom = new.distanceFromBottom
                let far = new.distanceFromBottom > 240
                if far != farFromBottom { farFromBottom = far }
                // Follow: content grew (or the viewport shrank) while the
                // viewport belonged at the bottom.
                if following, !userScrolling, new.distanceFromBottom > 1,
                   new.contentHeight != old.contentHeight || new.viewportHeight != old.viewportHeight {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    userScrolling = true
                    following = false
                case .idle:
                    if userScrolling {
                        userScrolling = false
                        following = metrics.distanceFromBottom < 32
                    }
                case .animating:
                    break
                @unknown default:
                    break
                }
            }
            .onChange(of: model.pendingUserText) { _, text in
                // A send shows the user their own message, wherever they
                // had scrolled to.
                guard text != nil else { return }
                following = true
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: model.isStreaming) { _, now in
                if now {
                    // Armed at stream start, when the viewport is settled.
                    streamActive = true
                    streamClip = max(160, metrics.viewportHeight - 40)
                } else {
                    endStream(proxy)
                }
            }
            .onChange(of: bottomRequest) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            }
        }
    }

    /// The stream is over: the clip lets go, and nothing may pin to the
    /// bottom, so the reply's start stays in view as its tail fills in
    /// below. One exact solve onto the reply's top covers a terminal
    /// that reloaded the transcript instead of appending to it. A reply
    /// shorter than the viewport lands at the bottom and keeps following.
    private func endStream(_ proxy: ScrollViewProxy) {
        guard streamActive else { return }
        streamActive = false
        streamClip = nil
        guard following else { return }
        following = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !userScrolling, let last = model.messages.last, last.role == .assistant else { return }
            proxy.scrollTo(last.id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(250))
            if !userScrolling { following = metrics.distanceFromBottom < 32 }
        }
    }

    /// The live reply. Bare, like the settled reply it becomes, so the
    /// swap at terminal is invisible.
    private var streamingRow: some View {
        StreamingRow(
            text: model.streamingText,
            thinkingText: model.streamingThinking,
            thinkingStartedAt: model.streamingThinkingStartedAt,
            thinkingFinishedAt: model.streamingThinkingFinishedAt,
            thinkingExpanded: $model.streamingThinkingExpanded,
            toolCalls: model.streamingToolCalls,
            streamingComponents: model.conversation.streamingComponents
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        // Ideal height first, then the cap: capping the proposal itself
        // starves MarkdownUI into one ellipsized line per paragraph.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { streamRowHeight = $0 }
        .frame(maxHeight: streamClip ?? .infinity, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            if let clip = streamClip, streamRowHeight > clip {
                StreamClipFade()
            }
        }
    }

    private var jumpToBottomButton: some View {
        Button {
            following = true
            bottomRequest += 1
        } label: {
            Image(systemName: "arrow.down")
                .scaledFont(size: 13, weight: .semibold)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Jump to the latest message")
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if let err = model.compactError {
            InlineBanner(systemImage: "exclamationmark.triangle.fill", text: "Compression failed: \(err)") {
                model.compactError = nil
            }
        }
        if let err = model.loadError, !model.messages.isEmpty {
            InlineBanner(systemImage: "exclamationmark.triangle.fill", text: err) { model.loadError = nil }
        }
        if let err = app.speech.playbackError {
            InlineBanner(systemImage: "speaker.slash.fill", text: err) { app.speech.clearError() }
        }
        if app.connectivity.state == .offline {
            InlineBanner(systemImage: "wifi.exclamationmark", text: "Server unreachable. Messages queue and send when it's back.", onDismiss: nil)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let archivedAt = liveConversation.archivedAt {
            // The server refuses every write to an archived conversation.
            ArchivedBarMac(conversationID: liveConversation.id, archivedAt: archivedAt)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        } else if let pending = model.pendingCompressionSummary {
            // The server refuses sends until the summary is reviewed.
            CompressionReviewBar(message: pending, model: model)
        } else {
            composer
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var leadingToolbarItem: some View {
        if isPage {
            Button {
                model.showingContextList = false
                model.showingCompactView = false
                model.showingSettingsView = false
                model.showingModelPicker = false
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back to the conversation")
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var compactSubmitButton: some View {
        Button {
            let providerID = model.compactProviderID
            let modelID = model.compactModelID
            let trimmed = model.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            // Close the page first so the summary streams into view.
            model.showingCompactView = false
            Task {
                await model.compact(guide: trimmed.isEmpty ? nil : trimmed, providerID: providerID, modelID: modelID)
            }
        } label: {
            if model.isCompacting { ProgressView().controlSize(.small) } else { Text("Compress") }
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!compactFormValid || model.isCompacting || model.sending)
        .help("Compress with the prompt and model above")
    }

    /// Needs a prompt and an enabled model: the server refuses a
    /// compression model that isn't enabled, and catching it here beats
    /// an error a beat later.
    private var compactFormValid: Bool {
        let trimmed = model.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let providerID = model.compactProviderID, !providerID.isEmpty,
              let modelID = model.compactModelID, !modelID.isEmpty
        else { return false }
        return app.profiles.availableModels.contains { $0.providerID == providerID && $0.modelID == modelID }
    }

    // MARK: Composer

    @ViewBuilder
    private var continueChip: some View {
        if model.canContinueDiscussion {
            HStack {
                Button {
                    Task { await model.continueDiscussion() }
                } label: {
                    Label("Continue the discussion", systemImage: "arrow.turn.down.right")
                        .scaledFont(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(app.connectivity.state == .offline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
    }

    private var composerEnabled: Bool {
        !(model.sending || model.hasPendingCompression || model.isCompacting || model.creatingConversation)
    }

    private var placeholder: String {
        if model.isDraft, model.draftProfile == nil { return "Choose a profile to start" }
        if let name = model.draftProfile?.name ?? convos.profiles.first(where: { $0.id == liveConversation.profileID })?.name {
            return "Message \(name)"
        }
        return "Message"
    }

    private var composer: some View {
        VStack(spacing: 6) {
            continueChip
            if !model.pendingAttachments.isEmpty || model.attachmentUploadCount > 0 {
                pendingAttachmentStrip
            }
            // One floating glass island: the text on top, the controls
            // on a footer row inside it.
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 6) {
                    // An AppKit text view: SwiftUI's vertical TextField
                    // stops growing at its line limit but never scrolls on
                    // macOS. Return sends; Shift-Return inserts a newline;
                    // ⌘V with a file or image on the pasteboard attaches it.
                    ComposerTextView(
                        text: $model.draft,
                        isEnabled: composerEnabled && !(model.isDraft && model.draftProfile == nil),
                        focusRequest: composerFocusRequest,
                        maxLines: 10,
                        onSubmit: {
                            if canSend { Task { await model.send() } }
                        },
                        onPasteAttachment: { pasteAttachmentIfPresent() }
                    )
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text(placeholder)
                                .scaledFont(.body)
                                .foregroundStyle(Color(nsColor: .placeholderTextColor))
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                    HStack(spacing: 8) {
                        paperclipButton
                        modelPickerChip
                        if let warning = contextWarning {
                            contextChip(warning)
                        }
                        Spacer()
                        sendOrStopButton
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    /// Nothing under the user's threshold; past it, the size in amber;
    /// near the model's own window, red, whatever the threshold.
    private var contextWarning: ContextWarning? {
        guard !model.isDraft else { return nil }
        return model.contextWarning(threshold: app.preferences.preferences.contextWarningTokens)
    }

    /// Clicking opens Compress: the warning carries its own remedy.
    private func contextChip(_ warning: ContextWarning) -> some View {
        let tint: Color = { if case .nearWindow = warning { return .red }; return .orange }()
        return Button {
            model.showingCompactView = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.needle")
                    .scaledFont(.caption2, weight: .semibold)
                Text(ContextWarning.compact(warning.tokens))
                    .scaledFont(.caption, weight: .semibold, monospacedDigit: true)
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isStreaming || model.isCompacting || model.hasPendingCompression)
        .help(contextChipHelp(warning))
    }

    private func contextChipHelp(_ warning: ContextWarning) -> String {
        switch warning {
        case .overThreshold(let t):
            return "Context is \(t.formatted()) tokens, past your warning level. Click to compress."
        case .nearWindow(let t, let w):
            return "Context is \(t.formatted()) of the model's \(w.formatted()) tokens. Click to compress."
        }
    }

    private var canSend: Bool {
        !model.isStreaming && !model.sending && !model.hasPendingCompression && !model.isCompacting
            && !model.creatingConversation
    }

    /// The trailing message is a user turn waiting on a reply and nothing
    /// is typed: the send button re-sends that turn instead.
    private var canReload: Bool {
        guard !model.isDraft, model.draft.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
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
            .help("Stop (⌘.)")
        } else if canReload {
            Button {
                Task { await model.reloadLastUser() }
            } label: {
                if model.sending { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.sending || model.hasPendingCompression || model.isCompacting)
            .help("Send your last message again (a new branch)")
        } else {
            Button {
                Task { await model.send() }
            } label: {
                if model.sending || model.creatingConversation {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            // Attachment-only sends are legal; an upload in flight blocks
            // the send so a message can't race its own attachment.
            .disabled(
                (model.draft.trimmingCharacters(in: .whitespaces).isEmpty && model.pendingAttachments.isEmpty)
                || model.attachmentUploadCount > 0
                || !canSend
                || (model.isDraft && model.draftProfile == nil)
            )
            .help("Send (Return)")
        }
    }

    private var selectedModelLabel: String {
        if let mid = model.selectedModelID, let pid = model.selectedProviderID,
           let m = model.availableModels.first(where: { $0.modelID == mid && $0.providerID == pid }) {
            return m.displayName
        }
        return model.selectedModelID ?? "Choose model"
    }

    @ViewBuilder
    private var modelPickerChip: some View {
        if !model.availableModels.isEmpty {
            // Opens the full-pane picker, which lists models with their
            // metadata; a system menu was unusable at many providers.
            Button {
                model.showingModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    if let slug = selectedProviderLogoSlug {
                        ProviderLogo(slug: slug, size: 14)
                    } else {
                        Image(systemName: "cpu")
                    }
                    Text(selectedModelLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Choose model")
            .fixedSize()
        }
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

    /// Logo slug for a provider — anthropic and google have static
    /// slugs; openai-compatible providers carry the slug in their
    /// preset id. Returns nil for custom (no preset) configs so the
    /// caller can render a fallback (cpu glyph in the chip, generic
    /// globe in ProviderLogo).
    fileprivate func providerLogoSlug(providerID: String, type: String?, presetID: String?) -> String? {
        switch type {
        case "anthropic": return "anthropic"
        case "google":    return "google"
        case "openai-compatible":
            return presetID
        default:
            return nil
        }
    }

    // MARK: - Attachments

    /// Kinds the active provider accepts — same table the iOS composer
    /// gates on: Anthropic images+PDFs, Google everything, OpenAI-
    /// compatible images only.
    private var acceptedAttachmentTypes: (image: Bool, document: Bool, audioVideo: Bool) {
        // A harness holds its own transcript and takes text only. The type
        // whitelist below would fall through to none for one anyway; asking
        // the binding first means the answer stays right the day a harness
        // grows file support, and says why in the meantime.
        guard model.canAttachFiles else { return (false, false, false) }
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
    /// Returns true when an attachment was taken (the text view must
    /// not also paste), false for text-only pasteboards so the normal
    /// paste proceeds. Files win over image data — a Finder copy puts
    /// both a file URL and a preview image on the pasteboard, and the
    /// URL is the real payload.
    private func pasteAttachmentIfPresent() -> Bool {
        guard attachmentsSupported else { return false }
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            for url in urls {
                Task { @MainActor in await attach(url: url) }
            }
            return true
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
            return true
        }
        return false
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
            : (model.canAttachFiles
               ? "Attachments not supported by this model"
               : "\(model.harness?.providerLabel ?? "This provider") cannot receive attachments"))
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
}

// MARK: - Transcript areas

/// The settled history. Equatable-gated so a stream flush, which
/// invalidates the body above, doesn't re-diff every row; the rows track
/// the view model's messages through observation on their own.
private struct ChatHistoryAreaMac: View, @MainActor Equatable {
    let model: ConversationViewModel

    static func == (_: ChatHistoryAreaMac, _: ChatHistoryAreaMac) -> Bool { true }

    var body: some View {
        let changed = model.modelChangeMessageIDs
        let firstMetered = model.firstMeteredReplyID
        let byID = Dictionary(model.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ForEach(model.messages) { msg in
            if msg.role == .compressionSummary, model.editingMessage?.id != msg.id {
                CompressionSummaryCard(message: msg, model: model)
                    .id(msg.id)
            } else {
                // MessageRow owns the inline editor, which is how the
                // summary card's Edit action works on the Mac.
                MessageRow(
                    message: msg,
                    previousMessage: msg.parentID.flatMap { byID[$0] },
                    model: model,
                    modelChanged: changed.contains(msg.id),
                    isFirstMeteredReply: msg.id == firstMetered
                )
                .id(msg.id)
            }
        }
    }
}

/// Optimistic rows: the message in flight, then anything queued offline.
private struct PendingAreaMac: View {
    let model: ConversationViewModel
    @Environment(\.chatPaneWidth) private var paneWidth

    var body: some View {
        if let pending = model.pendingUserText {
            pendingBubble(pending, badge: nil).id("__pending__")
        }
        ForEach(model.queuedEntries) { entry in
            pendingBubble(entry.content, badge: "Queued").id("__queued_\(entry.id)__")
        }
    }

    /// Drawn exactly like the user bubble it becomes, faded, so the row
    /// doesn't change shape when the send lands.
    private func pendingBubble(_ text: String, badge: String?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HuggingWidth(maxWidth: paneWidth > 0 ? paneWidth * 0.8 : 600) {
                MarkdownText(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background { ThemedUserBubbleBackground(cornerRadius: 16) }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .opacity(0.7)
            HStack(spacing: 6) {
                if let badge {
                    Text(badge)
                        .scaledFont(.caption2, weight: .medium)
                        .foregroundStyle(.orange)
                }
                ProgressView().controlSize(.mini)
            }
            .frame(height: 24)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Fades the last lines above the stream clip, so a parked reply reads
/// as continuing below rather than cut off.
private struct StreamClipFade: View {
    @Environment(\.theme) private var theme

    var body: some View {
        LinearGradient(colors: [theme.chrome.opacity(0), theme.chrome], startPoint: .top, endPoint: .bottom)
            .frame(height: 48)
            .allowsHitTesting(false)
    }
}

private struct ScrollGeometrySample: Equatable {
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var distanceFromBottom: CGFloat
}

/// A strip above the composer for a state worth reading: a failure, or
/// the server being away. Dismissible when the state is.
private struct InlineBanner: View {
    let systemImage: String
    let text: String
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(text)
                .scaledFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.caption2, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }
}

// MARK: - Conversation menu

/// The toolbar's "…": compress, contexts, and what the context has cost.
/// A popover of buttons, because SwiftUI's Menu renders empty rows in
/// this position on macOS 26.
private struct ConversationMenuMac: View {
    @Bindable var model: ConversationViewModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowActionButton(title: "Compress…", systemImage: "wand.and.stars") {
                dismiss()
                model.showingCompactView = true
            }
            .disabled(model.isStreaming || model.isCompacting || model.hasPendingCompression)
            RowActionButton(title: "Contexts", systemImage: "tray.full") {
                dismiss()
                model.showingContextList = true
            }
            Divider().padding(.vertical, 4)
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle")
                    .foregroundStyle(.secondary)
                Text(String(format: "$%.4f", accruedCost))
                    .monospacedDigit()
                Spacer()
                Text("this context")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            if !modelsMissingCost.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Approximate", systemImage: "exclamationmark.triangle")
                        .scaledFont(.caption, weight: .semibold)
                        .foregroundStyle(.orange)
                    Text("No pricing for \(modelsMissingCost.joined(separator: ", ")), so those turns aren't counted.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 260)
        .padding(.vertical, 6)
    }

    /// The server's per-context total, which counts every branch; the
    /// visible chain's sum undercounts once the user forks. The sum is
    /// the fallback until the contexts list loads.
    private var accruedCost: Double {
        if let ctx = model.activeContext, let row = model.contexts.first(where: { $0.id == ctx.id }) {
            return row.cumulativeCostUsd
        }
        return model.messages.reduce(0) { $0 + ($1.usage?.totalCostUsd ?? 0) }
    }

    /// Models that produced metered turns with no price.
    private var modelsMissingCost: [String] {
        var seen = Set<String>()
        for m in model.messages {
            guard m.role == .assistant, m.usage != nil, m.usage?.totalCostUsd == nil, let mid = m.modelID else { continue }
            let display = model.availableModels
                .first(where: { $0.modelID == mid && (m.providerID == nil || $0.providerID == m.providerID) })?
                .displayName ?? mid
            seen.insert(display)
        }
        return seen.sorted()
    }
}

// MARK: - Compacting, usage, archived

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
                // Chunked live view — this re-renders on every stream
                // flush, and a multi-leg summary outgrows what a single
                // document can re-lay out per tick; prefix-stable
                // chunks mean only the growing tail re-parses. The
                // settled card previews the head at terminal.
                ChunkedMarkdownText(text)
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

struct MessageUsagePopover: View {
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

/// Replaces the composer while the conversation is archived. The
/// transcript stays readable; the server refuses writes until it's restored.
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

