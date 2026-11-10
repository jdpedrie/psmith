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
    @Environment(\.onConversationModel) private var onModel
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
        // Coming back online: the transcript may have moved on another
        // client while this one couldn't hear about it.
        .onChange(of: app.connectivity.state) { old, new in
            guard old == .offline, new == .online, let model, !model.isDraft else { return }
            Task { await model.reloadAfterReconnect() }
        }
        .task(id: existing?.id ?? draftID?.uuidString ?? "") {
            let m = makeModel()
            onModel(m)
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

extension EnvironmentValues {
    /// Called with each view model a conversation screen builds. The app
    /// leaves it empty; end-to-end tests read the screen's state through it.
    @Entry var onConversationModel: @MainActor (ConversationViewModel) -> Void = { _ in }
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

/// The reading pane: its header, the transcript (or a page in its place),
/// the composer's slot, and the inspector beside it. Internal so snapshot
/// and event tests can render it with a prepared view model.
struct ConversationBody: View {
    @Bindable var model: ConversationViewModel
    let liveConversation: PsmithConversation
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    /// Bumped to move keyboard focus into the composer: on entry and on
    /// every conversation switch.
    @State private var composerFocusRequest = 0
    @State private var showingFileImporter = false
    @State private var dropTargeted = false

    // THE TRANSCRIPT. An eager VStack, so every row is laid out at entry
    // and every offset is a fact, not a LazyVStack estimate (see
    // docs/clients/chat-scroll.md). Streaming is follow-then-park: while
    // the viewport sits at the bottom, growth re-pins it there; the
    // streaming row is clipped to one viewport, so the reply's first line
    // rests at the top and the tail accumulates under the clip. At
    // terminal the clip goes and nothing re-pins. Any user scroll detaches.
    @State private var bottomRequest = 0
    @State private var metrics = ScrollMetricsBox()
    @State private var following = true
    @State private var userScrolling = false
    @State private var farFromBottom = false
    @State private var streamClip: CGFloat?
    @State private var streamActive = false
    @State private var streamRowHeight: CGFloat = 0

    private static let bottomID = "__newest_edge__"

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                // A draft can only pick its model; the header's All Models…
                // leads here before the first send too.
                if let page = navigator.page, !model.isDraft || page == .models {
                    ConversationPageView(page: page, model: model)
                } else {
                    transcript
                        .environment(\.openFullText) { title, markdown in
                            navigator.page = .fullText(title: title, markdown: markdown)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if navigator.inspectorShown && !model.isDraft {
                ConversationInspector(model: model, tab: Binding(
                    get: { navigator.inspectorTab },
                    set: { navigator.inspectorTab = $0 }
                ))
                .frame(width: MK.inspectorWidth)
                .background(MKWell())
                .overlay(alignment: .leading) { Rectangle().fill(SK.line).frame(width: 1) }
            }
        }
        .background(theme.chrome)
        .navigationTitle(navTitle)
        .background {
            // ⌥⌘I, without a toolbar item to hang it on.
            // Zero-size, not .hidden(): a hidden button drops its shortcut.
            Button("") { navigator.inspectorShown.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.isDraft)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: model.showingModelPicker) { _, on in
            guard on else { return }
            model.showingModelPicker = false
            navigator.page = .models
        }
        .onChange(of: model.showingSettingsView) { _, on in
            guard on else { return }
            model.showingSettingsView = false
            openInspector(.settings)
        }
        .onChange(of: model.showingContextList) { _, on in
            guard on else { return }
            model.showingContextList = false
            openInspector(.context)
        }
        // Unsent text outlives the screen: switching away or quitting
        // keeps it, and the next view model restores it.
        .onChange(of: model.draft) { _, text in
            DraftStore.save(conversationID: model.conversation.id, text: text)
        }
        .task(id: liveConversation.id) {
            guard !model.isDraft else { return }
            await model.loadContexts()
            await model.loadAvailableModels()
        }
        .onAppear {
            // A selection mode left on from an earlier visit ends first:
            // its text view and the composer would take focus from each other.
            model.selectingTextMessageID = nil
            composerFocusRequest += 1
        }
        .onChange(of: liveConversation.id) { _, _ in
            model.selectingTextMessageID = nil
            navigator.page = nil
            composerFocusRequest += 1
        }
    }

    private func openInspector(_ tab: InspectorTab) {
        navigator.inspectorTab = tab
        navigator.inspectorShown = true
    }

    // MARK: Header

    private var header: some View {
        MKDetailHeader(title: navTitle, subtitle: navSubtitle) {
            MKCapsule {
                modelMenu
                if !model.isDraft, let tokens = model.contextTokens {
                    MKCapsuleDivider()
                    contextButton(tokens)
                }
            }
            if !model.isDraft {
                MKIconButton(systemImage: "sidebar.trailing", label: "Show the inspector (⌥⌘I)", active: navigator.inspectorShown) {
                    navigator.inspectorShown.toggle()
                }
            }
        }
    }

    /// The model this conversation sends to, as a menu: favorites, then
    /// each provider's models, then the full catalog as a page.
    private var modelMenu: some View {
        let models = model.selectableModels
        let favorites = models.filter(\.favorite).sorted { $0.displayName < $1.displayName }
        let byProvider = Dictionary(grouping: models.filter { !$0.favorite }, by: \.providerID)
            .map { (label: model.providerLabels[$0.key] ?? $0.key, models: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.label < $1.label }
        return Menu {
            if let notice = model.harnessNotice {
                Text(notice)
            }
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites, id: \.self) { modelButton($0) }
                }
            }
            ForEach(byProvider, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.models, id: \.self) { modelButton($0) }
                }
            }
            Divider()
            Button("All Models…") { navigator.page = .models }
        } label: {
            HStack(spacing: 7) {
                ProviderLogo(slug: model.selectedProviderID.flatMap { model.providerTypes[$0] }, size: 12)
                    .frame(width: 12, height: 12)
                Text(selectedModelLabel).sk(12.5).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(SK.secondary)
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model for this conversation")
        .disabled(models.isEmpty)
    }

    private func modelButton(_ m: PsmithUserModel) -> some View {
        let selected = m.providerID == model.selectedProviderID && m.modelID == model.selectedModelID
        return Button {
            Task { await model.selectModel(providerID: m.providerID, modelID: m.modelID) }
        } label: {
            if selected {
                Label(m.displayName, systemImage: "checkmark")
            } else {
                Text(m.displayName)
            }
        }
    }

    /// The context's size, always: a power user wants the number. Past
    /// the user's threshold it turns amber, near the model's own window
    /// red. Opens the inspector's context tab, where the remedy is.
    private func contextButton(_ tokens: Int32) -> some View {
        let warning = model.contextWarning(threshold: app.preferences.preferences.contextWarningTokens)
        let tint: Color = switch warning {
        case .nearWindow: SK.red
        case .overThreshold: SK.orange
        case nil: SK.secondary
        }
        return Button {
            openInspector(.context)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle").font(.system(size: 11.5, weight: .medium))
                Text(ContextWarning.compact(tokens)).sk(12.5, tint, weight: warning == nil ? .medium : .semibold).monospacedDigit()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(warning.map(contextChipHelp) ?? "Context: \(tokens.formatted()) tokens")
        .accessibilityLabel("Context \(ContextWarning.compact(tokens))")
    }

    private func contextChipHelp(_ warning: ContextWarning) -> String {
        switch warning {
        case .overThreshold(let t):
            return "Context is \(t.formatted()) tokens, past your warning level. Click to compress."
        case .nearWindow(let t, let w):
            return "Context is \(t.formatted()) of the model's \(w.formatted()) tokens. Click to compress."
        }
    }

    private var navTitle: String {
        if model.isDraft { return "New Conversation" }
        let raw = liveConversation.title ?? ""
        return raw.isEmpty ? "Untitled" : raw
    }

    /// The profile, and the active context once there's more than one.
    private var navSubtitle: String {
        var parts: [String] = []
        if let name = model.draftProfile?.name ?? convos.profiles.first(where: { $0.id == liveConversation.profileID })?.name {
            parts.append(name)
        }
        if model.contexts.count > 1, let ctx = model.activeContext {
            if let t = ctx.title, !t.isEmpty {
                parts.append(t)
            } else if let n = model.contextNumber(for: ctx.id) {
                parts.append("Context \(n) of \(model.contexts.count)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var selectedModelLabel: String {
        if let mid = model.selectedModelID, let pid = model.selectedProviderID,
           let m = model.availableModels.first(where: { $0.modelID == mid && $0.providerID == pid }) {
            return m.displayName
        }
        return model.selectedModelID ?? "Choose a model"
    }

    // MARK: Transcript

    /// Before its first message a new conversation is a start screen:
    /// pick who you're talking to, then write. After it, the transcript.
    private var showsStartScreen: Bool {
        model.isDraft && !model.messages.contains(where: { $0.role == .user })
            && model.pendingUserText == nil && !model.creatingConversation
    }

    @ViewBuilder
    private var transcript: some View {
        if showsStartScreen {
            VStack(spacing: 0) {
                DraftStartView(model: model, profiles: convos.profiles)
                    .frame(maxHeight: .infinity)
                bottomStack
            }
        } else {
            transcriptBody
        }
    }

    private var transcriptBody: some View {
        GeometryReader { geo in
            let column = min(geo.size.width - 48, MK.column)
            scrollBody
                .environment(\.chatPaneWidth, column)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomStack
                        .overlay(alignment: .top) {
                            if farFromBottom {
                                jumpToBottomButton.offset(y: -48)
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
        } isTargeted: { dropTargeted = $0 && attachmentsSupported }
        .overlay {
            if dropTargeted { DropOverlay(detail: dropDetail) }
        }
    }

    @ViewBuilder
    private var scrollBody: some View {
        if let err = model.loadError, model.messages.isEmpty, !model.isDraft {
            MKEmptyList(systemImage: "exclamationmark.triangle", title: "Couldn’t load this conversation", detail: err, top: 120)
        } else if model.loading && model.messages.isEmpty {
            MKSpinner(size: 18).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxWidth: MK.column, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                // 14 above the composer with the edge marker below: the
                // same space as between rows.
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity)
                Color.clear.frame(height: 1).id(Self.bottomID)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollEdgeEffectHidden(true, for: .top)
            .scrollEdgeEffectHidden(true, for: .bottom)
            .onScrollGeometryChange(for: ScrollGeometrySample.self) { g in
                ScrollGeometrySample(
                    contentHeight: g.contentSize.height,
                    viewportHeight: g.containerSize.height,
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
                guard text != nil else { return }
                following = true
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: model.isStreaming) { _, now in
                if now {
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
    /// below. A reply shorter than the viewport lands at the bottom and
    /// keeps following.
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SK.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(MK.raised))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Jump to the latest message")
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    // MARK: The composer's slot

    /// Banners, then whatever holds the composer's place, in one column
    /// with the transcript's measure.
    private var bottomStack: some View {
        VStack(spacing: 0) {
            banners
            bottomSlot
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var banners: some View {
        if let err = model.compactError {
            bannerRow(MKInlineBanner(systemImage: "exclamationmark.triangle", text: "Compression failed: \(err)") { model.compactError = nil })
        }
        if let err = model.loadError, !model.messages.isEmpty {
            bannerRow(MKInlineBanner(systemImage: "exclamationmark.triangle", text: err) { model.loadError = nil })
        }
        if let err = app.speech.playbackError {
            bannerRow(MKInlineBanner(systemImage: "speaker.slash", text: err) { app.speech.clearError() })
        }
        if app.connectivity.state == .offline {
            bannerRow(MKInlineBanner(systemImage: "wifi.exclamationmark", text: "Server unreachable. Messages wait here and send when it’s back."))
        }
    }

    private func bannerRow(_ b: MKInlineBanner) -> some View {
        MKColumn { b }.padding(.bottom, 8)
    }

    private var pendingElicitation: StreamHub.PendingElicit? {
        app.streamHub.activeStream(conversationID: liveConversation.id)?.pendingElicitations.first
    }

    @ViewBuilder
    private var bottomSlot: some View {
        if let archivedAt = liveConversation.archivedAt {
            // The server refuses every write to an archived conversation.
            MKColumn { ArchivedCard(conversationID: liveConversation.id, archivedAt: archivedAt) }
        } else if let pending = model.pendingCompressionSummary {
            // The server refuses sends until the summary is reviewed.
            MKColumn { ReviewCard(message: pending, model: model) }
        } else if let pending = pendingElicitation {
            MKColumn { ElicitCard(conversationID: liveConversation.id, pending: pending).id(pending.id) }
        } else if model.showingCompactView {
            MKColumn { CompressCard(model: model) }
        } else {
            composer
        }
    }

    // MARK: Composer

    @ViewBuilder
    private var continueChip: some View {
        if model.canContinueDiscussion {
            MKColumn {
                HStack {
                    Button {
                        Task { await model.continueDiscussion() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .medium))
                            Text("Continue the discussion")
                        }
                    }
                    .skButton(.plainQuiet)
                    .disabled(app.connectivity.state == .offline)
                    Spacer(minLength: 0)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var composerEnabled: Bool {
        !(model.sending || model.hasPendingCompression || model.isCompacting || model.creatingConversation)
    }

    private var placeholder: String {
        if model.isDraft, model.draftProfile == nil { return "Choose a profile to start" }
        if model.isCompacting { return "Waiting for the summary…" }
        if let name = model.draftProfile?.name ?? convos.profiles.first(where: { $0.id == liveConversation.profileID })?.name {
            return "Message \(name)"
        }
        return "Message"
    }

    private var composer: some View {
        VStack(spacing: 0) {
            continueChip
            if !model.pendingAttachments.isEmpty || model.attachmentUploadCount > 0 {
                MKColumn { pendingAttachmentStrip }.padding(.bottom, 8)
            }
            MKColumn {
                VStack(alignment: .leading, spacing: 0) {
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
                                .sk(13, SK.tertiary)
                                .allowsHitTesting(false)
                        }
                    }
                    HStack(spacing: 10) {
                        paperclipButton
                        Text("Return to send · ⇧Return for a new line")
                            .sk(11.5, SK.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        sendOrStopButton
                    }
                    .padding(.top, 10)
                    .padding(.leading, -6)
                }
                .padding(.top, 11)
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
                .background(RoundedRectangle(cornerRadius: 18).fill(MK.raised))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(MK.raisedRing, lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
            }
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
                ComposerRoundIcon(systemImage: "stop.fill", fill: SK.destructiveFill, size: 9)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: [.command])
            .help("Stop (⌘.)")
            .accessibilityLabel("Stop")
        } else if canReload {
            Button {
                Task { await model.reloadLastUser() }
            } label: {
                ComposerRoundIcon(systemImage: "arrow.clockwise", fill: theme.accent, busy: model.sending)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.sending || model.hasPendingCompression || model.isCompacting)
            .help("Send your last message again (a new branch)")
            .accessibilityLabel("Send again")
        } else {
            let disabled = (model.draft.trimmingCharacters(in: .whitespaces).isEmpty && model.pendingAttachments.isEmpty)
                || model.attachmentUploadCount > 0
                || !canSend
                || (model.isDraft && model.draftProfile == nil)
            Button {
                Task { await model.send() }
            } label: {
                ComposerRoundIcon(systemImage: "arrow.up",
                                  fill: disabled && !(model.sending || model.creatingConversation) ? Color.white.opacity(0.12) : theme.accent,
                                  busy: model.sending || model.creatingConversation)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            // Attachment-only sends are legal; an upload in flight blocks
            // the send so a message can't race its own attachment.
            .disabled(disabled)
            .help("Send (Return)")
            .accessibilityLabel("Send")
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

    private var dropDetail: String {
        let ok = acceptedAttachmentTypes
        var kinds: [String] = []
        if ok.image { kinds.append("Images") }
        if ok.document { kinds.append("PDFs") }
        if ok.audioVideo { kinds.append("audio and video") }
        let list = ListFormatter.localizedString(byJoining: kinds)
        return "\(list), for \(selectedModelLabel)"
    }

    private var paperclipButton: some View {
        Button {
            showingFileImporter = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(attachmentsSupported ? SK.secondary : SK.tertiary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .contentShape(Circle())
                .opacity(attachmentsSupported ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!attachmentsSupported)
        .help(attachmentsSupported
            ? "Attach files, or drop them on the conversation"
            : (model.canAttachFiles
               ? "Attachments not supported by this model"
               : "\(model.harness?.providerLabel ?? "This provider") cannot receive attachments"))
        .accessibilityLabel("Attach files")
    }

    /// Waiting attachments above the composer: 56pt thumbnails, file
    /// chips, an ✕ on each, and a chip while uploads are in flight.
    private var pendingAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { att in
                    pendingChip(att)
                }
                if model.attachmentUploadCount > 0 {
                    HStack(spacing: 6) {
                        MKSpinner(size: 11)
                        Text("Uploading…").sk(12, SK.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
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
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            } else {
                AttachmentFileChip(
                    name: att.originalFilename ?? "File",
                    detail: att.mimeType == "application/pdf" ? "PDF" : (att.mimeType.split(separator: "/").last.map { $0.uppercased() } ?? "File"),
                    systemImage: att.mimeType == "application/pdf" ? "doc.richtext" : "doc"
                )
                .frame(height: 56)
            }
            Button {
                model.removePendingAttachment(fileID: att.fileID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove attachment")
        }
    }
}

/// The composer's round buttons: send, send again, stop. 28pt.
struct ComposerRoundIcon: View {
    let systemImage: String
    let fill: Color
    var busy = false
    var size: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().fill(fill)
            if busy {
                MKSpinner(size: 12, color: .white)
            } else {
                Image(systemName: systemImage).font(.system(size: size, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Circle())
    }
}

/// Over the conversation while files are dragged onto it.
struct DropOverlay: View {
    let detail: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 24, weight: .light)).foregroundStyle(theme.accentInk)
            Text("Drop to attach").sk(14, weight: .semibold)
            Text(detail).sk(12, SK.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.chrome.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        .padding(12)
        .allowsHitTesting(false)
    }
}

/// The reading column's header: title and subtitle at 20pt, controls on
/// the right. With the list hidden, its show and new buttons move here,
/// clear of the traffic lights.
struct MKDetailHeader<Trailing: View>: View {
    let title: String
    var subtitle: String = ""
    var divider = true
    @ViewBuilder var trailing: Trailing
    @Environment(Navigator.self) private var navigator

    var body: some View {
        MKHeaderBand(divider: divider) {
            if !navigator.listShown {
                Color.clear.frame(width: 72, height: 1)
                MKIconButton(systemImage: "sidebar.leading", label: "Show the conversation list (⌃⌘S)") {
                    withAnimation(.easeInOut(duration: 0.25)) { navigator.listShown = true }
                }
                MKIconButton(systemImage: "square.and.pencil", label: "New conversation (⌘N)") {
                    navigator.startNewConversation()
                }
                Color.clear.frame(width: 6, height: 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).sk(13, weight: .semibold).lineLimit(1).frame(height: 15.6)
                if !subtitle.isEmpty {
                    Text(subtitle).sk(11, SK.secondary).lineLimit(1).frame(height: 13.2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            trailing
        }
        .padding(.leading, navigator.listShown ? 20 : 10)
        .padding(.trailing, 12)
    }
}

extension MKDetailHeader where Trailing == EmptyView {
    init(title: String, subtitle: String = "", divider: Bool = true) {
        self.init(title: title, subtitle: subtitle, divider: divider) { EmptyView() }
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
        VStack(alignment: .trailing, spacing: 0) {
            HuggingWidth(maxWidth: paneWidth > 0 ? paneWidth * 0.8 : 576) {
                UserBubble(text: text)
            }
            HStack(spacing: 6) {
                if let badge {
                    Text(badge).sk(11, SK.orange, weight: .medium)
                }
                MKSpinner(size: 10)
            }
            .frame(height: 22)
            .padding(.horizontal, 4)
        }
        .opacity(0.7)
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

/// The summary streaming in, where the card will land.
private struct CompactingRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.system(size: 10.5, weight: .medium))
                Text("COMPACTING").sk(11, SK.orange, weight: .semibold)
                MKSpinner(size: 10, color: SK.orange)
            }
            .foregroundStyle(SK.orange)
            if text.isEmpty {
                Text("Summarizing the conversation…").sk(13, SK.secondary)
            } else {
                // Chunked: this re-renders on every stream flush, and
                // prefix-stable chunks mean only the growing tail re-parses.
                ChunkedMarkdownText(text)
                    .foregroundStyle(SK.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(SK.orange.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SK.orange.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Usage

/// A reply's model, tokens, cache and cost, opened under the reply from
/// its More menu (board AppMessageUsage). Four columns in one card.
struct MessageUsageDetails: View {
    let message: PsmithMessage
    let model: ConversationViewModel

    private typealias Line = (String, String)

    private var columns: [(String, [Line])] {
        var out: [(String, [Line])] = []
        var m: [Line] = []
        if let mid = message.modelID {
            let name = model.availableModels.first(where: { $0.modelID == mid && (message.providerID == nil || $0.providerID == message.providerID) })?.displayName
            m.append((name ?? mid, ""))
        }
        if let pid = message.providerID { m.append((model.providerLabels[pid] ?? pid, "")) }
        if !m.isEmpty { out.append(("Model", m)) }
        guard let u = message.usage else { return out }
        var t: [Line] = []
        if let n = u.inputTokens { t.append(("Input", n.formatted())) }
        if let n = u.outputTokens { t.append(("Output", n.formatted())) }
        if let n = u.cacheReadTokens { t.append(("Cache read", n.formatted())) }
        if let n = u.cacheWriteTokens, n > 0 { t.append(("Cache write", n.formatted())) }
        if let n = u.reasoningTokens { t.append(("Reasoning", n.formatted())) }
        if !t.isEmpty { out.append(("Tokens", t)) }
        let read = u.cacheReadTokens ?? 0
        if read > 0 || u.explicitCacheAttached != nil {
            var c: [Line] = []
            if read > 0, let input = u.inputTokens, input > 0 {
                let prompt = read > input ? input + read : input
                c.append(("Hit", "\(Int((Double(read) / Double(prompt) * 100).rounded()))%"))
            }
            if let attached = u.explicitCacheAttached {
                c.append(("Source", attached ? "Explicit" : "Not attached"))
            } else if read > 0 {
                c.append(("Source", "Implicit"))
            }
            if read > 0, let savings = cacheSavings(message: message, cacheReadTokens: read) { c.append(("Saved", costStr(savings))) }
            out.append(("Cache", c))
        }
        var k: [Line] = []
        if let v = u.inputCostUsd { k.append(("Input", costStr(v))) }
        if let v = u.outputCostUsd { k.append(("Output", costStr(v))) }
        if let v = u.cacheReadCostUsd, v > 0 { k.append(("Cache read", costStr(v))) }
        if let v = u.cacheWriteCostUsd, v > 0 { k.append(("Cache write", costStr(v))) }
        if let v = u.toolCostUsd, v > 0 { k.append(("Tools", costStr(v))) }
        if let v = u.totalCostUsd { k.append(("Total", costStr(v))) }
        if !k.isEmpty { out.append(("Cost", k)) }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(columns, id: \.0) { column in
                VStack(alignment: .leading, spacing: 0) {
                    Text(column.0).sk(11, SK.tertiary, weight: .semibold).padding(.bottom, 5)
                    ForEach(Array(column.1.enumerated()), id: \.offset) { _, line in
                        HStack {
                            Text(line.0).sk(12, line.1.isEmpty ? SK.text : SK.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(line.1).sk(12).monospacedDigit()
                        }
                        .frame(height: 19)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(MK.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SK.line, lineWidth: 1))
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
        v.formatted(.currency(code: "USD").precision(.fractionLength(4)))
    }

}

