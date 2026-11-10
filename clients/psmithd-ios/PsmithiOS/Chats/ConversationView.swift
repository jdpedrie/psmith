import SwiftUI
import PsmithKit
import PsmithUI
import QuartzCore
import os.log

/// Breadcrumbs for the follow-then-park state machine. Notice-level so
/// they survive into `log show`: these interactions only show on a live
/// stream.
private let scrollLog = Logger(subsystem: "dev.jdpedrie.psmith", category: "ChatScroll")

extension Notification.Name {
    /// "Jump to the start of the context", posted by the status-bar
    /// bridge (object: conversation id); the screen runs its
    /// scroll-to-oldest.
    static let psmithScrollToContextStart = Notification.Name("psmith.scrollToContextStart")
}

/// A conversation (board Conversation and its states). Builds the
/// `ConversationViewModel` against the live server, then shows the
/// screen.
struct ConversationView: View {
    /// The conversation opened from the list; nil for a new one.
    private let existing: PsmithConversation?
    /// Identity of a new conversation's screen. Stable across its first
    /// send, when the view model gains a server id: keying the setup
    /// task on the conversation id would rebuild the model mid-send.
    private let draftID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.notifier) private var notifier
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ConversationViewModel?
    @State private var ui = ConversationUIState()
    /// Hands each view model this view builds to an observer. Tests use it
    /// to drive the real screen and to see whether a model was replaced.
    private let onModel: ((ConversationViewModel, ConversationUIState) -> Void)?

    init(conversation: PsmithConversation, onModel: ((ConversationViewModel, ConversationUIState) -> Void)? = nil) {
        existing = conversation
        draftID = nil
        self.onModel = onModel
    }

    /// A new conversation: nothing exists on the server until its first
    /// message is sent.
    init(newConversation draftID: UUID, onModel: ((ConversationViewModel, ConversationUIState) -> Void)? = nil) {
        existing = nil
        self.draftID = draftID
        self.onModel = onModel
    }

    private var conversation: PsmithConversation {
        model?.conversation ?? existing ?? Self.emptyDraft
    }

    private static let emptyDraft = PsmithConversation(
        id: "", profileID: "", title: nil, activeContextID: "",
        ownerUserID: "", createdAt: .distantPast, updatedAt: .distantPast
    )

    private var setupKey: String { existing?.id ?? draftID?.uuidString ?? "" }

    var body: some View {
        Group {
            if let model {
                ConversationScreen(model: model, ui: ui)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(existing?.title ?? "New conversation")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        // Edge-only back swipe while the conversation is up: the iOS 26
        // swipe-anywhere pop fires on rightward transcript drags.
        .background(BackSwipeLimiter())
        .onAppear {
            TranscriptTrace.note(conversation.id, "view appeared model=\(model != nil)")
            // On screen: a terminal arriving now doesn't raise the list's
            // new-message dot, and any pending one clears.
            if !conversation.id.isEmpty { app.streamHub.markViewing(conversationID: conversation.id) }
        }
        // A new conversation gets its id at the first send, on screen.
        .onChange(of: model?.conversation.id) { _, id in
            if let id, !id.isEmpty { app.streamHub.markViewing(conversationID: id) }
        }
        .onDisappear {
            TranscriptTrace.note(conversation.id, "view disappeared")
            app.streamHub.markStoppedViewing(conversationID: conversation.id)
        }
        .onChange(of: scenePhase) { _, phase in
            // The server keeps streaming while we're away and persists
            // chunks; on return the subscriber replays from the last
            // sequence, and anything changed elsewhere reconciles.
            guard let m = model else { return }
            switch phase {
            case .background, .inactive: m.suspendActiveStream()
            case .active:
                m.resumeStreamIfPaused()
                Task { await m.refreshIfStale() }
            @unknown default: break
            }
        }
        .onChange(of: app.connectivity.state) { old, new in
            guard old == .offline, new == .online, let m = model else { return }
            Task { await m.reloadAfterReconnect() }
        }
        .task(id: setupKey) {
            TranscriptTrace.note(conversation.id, "view setup task model=\(model != nil)")
            if existing == nil {
                // `.task` runs again every time this view reappears, as it
                // does when a pushed page (the model picker, Info) pops. A
                // draft has nothing on the server to reload, so rebuilding
                // it threw away the profile and model just chosen.
                if model == nil { await setUpNewConversation() }
                return
            }
            // A fresh view model per appearance: the scroll machinery is
            // built around a cold-entry settle per entry, and every
            // settings writer does a fresh read-modify-write, so a stale
            // snapshot can't clobber anything.
            //
            // Parsed markdown from the previous conversation goes; this
            // one's lands back as soon as its first load returns.
            MarkdownCache.shared.clear()
            let liveNotifier = notifier
            let m = ConversationViewModel(
                conversation: existing ?? conversation,
                client: app.client,
                hub: app.streamHub,
                outboundQueue: app.outboundQueue,
                connectivity: app.connectivity,
                onTerminal: { [weak convos] in await convos?.refresh() },
                onAssistantTurnComplete: { convID, title, msgID, preview in
                    liveNotifier.generationCompleted(conversationID: convID, conversationTitle: title,
                                                     messageID: msgID, preview: preview)
                },
                localTitler: AppleFoundationTitler()
            )
            m.speechPlayer = app.speech
            // Cache first: the cached transcript renders this frame and
            // the network load replaces it at the inverted list's rest
            // edge, where the swap is invisible.
            await m.hydrateFromCache()
            self.model = m
            onModel?(m, ui)
            await m.load()
            let profileMap = Dictionary(uniqueKeysWithValues: convos.profiles.map { ($0.id, $0) })
            await m.maybeGenerateLocalTitle(profilesByID: profileMap)
            await m.loadContexts()
            await m.loadAvailableModels()
            // Parse history off the main thread so the first scroll back
            // through it doesn't pay per row.
            MarkdownCache.shared.prewarm(m.messages.map {
                let body = $0.displayContent ?? $0.content
                return (key: MessageRow.markdownKey(id: $0.id, body: body), source: body)
            })
        }
    }

    /// Starts a draft from the default profile when there is one;
    /// otherwise the start screen asks.
    private func setUpNewConversation() async {
        let liveNotifier = notifier
        let m = ConversationViewModel.draft(
            client: app.client,
            hub: app.streamHub,
            outboundQueue: app.outboundQueue,
            connectivity: app.connectivity,
            onTerminal: { [weak convos] in await convos?.refresh() },
            onAssistantTurnComplete: { convID, title, msgID, preview in
                liveNotifier.generationCompleted(conversationID: convID, conversationTitle: title,
                                                 messageID: msgID, preview: preview)
            },
            localTitler: AppleFoundationTitler()
        )
        m.speechPlayer = app.speech
        m.localTitleProfilesByID = Dictionary(uniqueKeysWithValues: convos.profiles.map { ($0.id, $0) })
        m.onConversationCreated = { [weak convos] created in convos?.didCreate(created) }
        model = m
        onModel?(m, ui)
        if let profile = convos.profiles.first(where: { $0.isDefault && !$0.parentOnly }) {
            await m.chooseDraftProfile(profile)
        } else {
            await m.loadAvailableModels()
        }
    }
}

// MARK: - Screen

/// The conversation screen: the system navigation bar with the title
/// and the context gauge, the inverted transcript, and the composer's
/// slot, which a card takes over when something else needs an answer
/// first.
struct ConversationScreen: View {
    @Bindable var model: ConversationViewModel
    let ui: ConversationUIState
    /// Tests stand in for the stream's pending elicitation, whose type
    /// has no public initializer.
    var elicitOverride: ElicitRequest?
    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    /// Tests show the follow pill without scrolling.
    var forceFollowPill = false
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.theme) private var theme

    /// The latest list snapshot, so a generated title shows without a
    /// remount.
    private var liveConversation: PsmithConversation {
        convos.conversations.first(where: { $0.id == model.conversation.id }) ?? model.conversation
    }

    private var elicit: ElicitRequest? {
        if let elicitOverride { return elicitOverride }
        guard let p = app.streamHub.activeStream(conversationID: model.conversation.id)?.pendingElicitations.first else { return nil }
        return ElicitRequest(id: p.id, message: p.message, schemaJSON: p.schemaJSON, title: p.title)
    }

    @State private var showingSettings = false
    @State private var queueTick = 0
    @State private var rootHeight: CGFloat = 800
    @FocusState private var renameFocused: Bool

    // Scroll machinery: see paneScrollBody.
    @State private var scrollPosition = ScrollPosition()
    /// Latest scroll metrics in a reference box: writing it per tick must
    /// not invalidate any body (per-tick @State writes were what drove
    /// the old 100%-CPU storms).
    private final class ScrollMetricsBox {
        var latest = ScrollMetrics(contentHeight: 0, offset: 0, viewportHeight: 0,
                                   contentWidth: 0, viewportWidth: 0, offsetX: 0)
    }
    @State private var metricsBox = ScrollMetricsBox()
    @State private var viewportHeight: CGFloat = 0
    /// The pane's top safe-area inset (nav bar clearance), re-applied as
    /// a content-space bottom margin so it renders at the visual top
    /// through the flip.
    @State private var navClearance: CGFloat = 0
    /// Measured in place with onGeometryChange: a GeometryReader around
    /// the scroll view lost the content's horizontal padding whenever the
    /// keyboard appeared.
    @State private var paneWidth: CGFloat = 0
    @State private var isFarFromBottom = false
    private let scrollToBottomThreshold: CGFloat = 200
    @State private var contentUnitMinX: CGFloat = 0
    /// The streaming row's rendered-height cap, set when a stream begins
    /// (about one viewport). Nonzero means the park is live; zeroed at
    /// the terminal, by the pill, and on send failure.
    @State private var streamClipBudget: CGFloat = 0
    /// True while the scroll position holds a one-shot programmatic
    /// position. A held position is sticky and re-applies against a
    /// user's drag, so each one releases on grab or after its settle.
    @State private var positionHeld = false

    private var showsDraftStart: Bool {
        model.isDraft && model.pendingUserText == nil && !model.creatingConversation
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showsDraftStart {
                    draftStart
                } else {
                    messageScroll
                }
            }
            .opacity(ui.renaming ? 0.45 : 1)
            .allowsHitTesting(!ui.renaming)
            bottomSlot
                .padding(.horizontal, 12)
                .padding(.bottom, ui.trayOpen ? 0 : 0)
                .opacity(ui.renaming ? 0.45 : 1)
                .allowsHitTesting(!ui.renaming)
        }
        .background(theme.chrome.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: OutboundQueue.didChangeNotification)) { _ in
            queueTick &+= 1
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { rootHeight = $0 }
        .environment(\.openConversationPage) { page in ui.page = page }
        .environment(\.chatPaneWidth, paneWidth)
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(ui.renaming)
        // The long-press menu covers the whole screen, bar included.
        .toolbar(model.actionMenuMessage == nil ? .visible : .hidden, for: .navigationBar)
        .toolbar { toolbar }
        .onChange(of: model.messages.count) { _, _ in
            // Parse new messages off the main thread; keys must match
            // MessageRow's render key.
            MarkdownCache.shared.prewarm(model.messages.map {
                let body = $0.displayContent ?? $0.content
                return (key: MessageRow.markdownKey(id: $0.id, body: body), source: body)
            })
        }
        .animation(.snappy(duration: 0.25), value: model.isDraft)
        .animation(.snappy(duration: 0.25), value: ui.trayOpen)
        .animation(.snappy(duration: 0.25), value: model.showingCompactView)
        .overlay {
            if let msg = model.actionMenuMessage {
                MessageActionMenu(message: msg, model: model, ui: ui)
                    .environment(\.openConversationPage) { page in ui.page = page }
                    .transition(.opacity)
            }
        }
        .navigationDestination(item: Bindable(ui).page) { page in
            destination(page)
        }
        .navigationDestination(isPresented: $showingSettings) { SettingsRoot() }
        .toast(
            message: Binding(
                get: { model.lastPromotedContextID == nil ? nil : "Switched to the new context" },
                set: { _ in model.lastPromotedContextID = nil }
            ),
            systemImage: "wand.and.stars"
        )
    }

    @ViewBuilder
    private func destination(_ page: ConversationPage) -> some View {
        switch page {
        case .info: ConversationInfoScreen(model: model)
        case .models: ModelPickerScreen(model: model)
        case .callSettings: CallSettingsScreen(model: model)
        case .fullText(let title, let markdown): FullTextScreen(title: title, markdown: markdown)
        case .image(let messageID, let fileID, let filename):
            ImageViewerScreen(model: model, messageID: messageID, fileID: fileID, filename: filename)
        }
    }

    // MARK: Header

    private var navTitle: String {
        if model.isDraft { return "New conversation" }
        let t = liveConversation.title ?? ""
        return t.isEmpty ? "Untitled" : t
    }

    private var profile: PsmithProfile? {
        model.draftProfile ?? convos.profiles.first(where: { $0.id == model.conversation.profileID })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if ui.renaming {
            ToolbarItem(placement: .principal) { renameField }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { titleBlock }
                .sharedBackgroundVisibility(.hidden)
            if !model.isDraft {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { ui.page = .info } label: { ContextGauge(fraction: contextFraction) }
                        .accessibilityLabel(gaugeLabel)
                }
            }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 0) {
            Button {
                guard !model.isDraft else { return }
                ui.renameDraft = liveConversation.title ?? ""
                ui.renaming = true
                renameFocused = true
            } label: {
                Text(navTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IK.text)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isDraft ? navTitle : "\(navTitle), rename conversation")
            subtitle
        }
        .frame(maxWidth: max(paneWidth - 32 - 2 * 52, 160))
    }

    @ViewBuilder
    private var subtitle: some View {
        let voices = model.councilVoices
        if voices.count > 1 {
            HStack(spacing: 4) {
                ForEach(voices, id: \.self) { Circle().fill(theme.personaColor($0)).frame(width: 7, height: 7) }
                Text("\(voices.count) voices").padding(.leading, 3)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(IK.secondary)
            .frame(height: 22)
        } else if let profile {
            HStack(spacing: 6) {
                if model.isCompacting {
                    IKSpinner(size: 11, color: IK.orange)
                    Text("\(profile.name) · compressing").lineLimit(1)
                } else if model.isStreaming {
                    IKSpinner(size: 11)
                    Text("\(profile.name) · replying").lineLimit(1)
                } else {
                    Circle().fill(ProfileColor.color(for: profile.id, theme: theme)).frame(width: 7, height: 7)
                    Text(profile.name + contextLabel).lineLimit(1)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(model.isCompacting ? IK.orange : (model.isStreaming ? theme.accentInk : IK.secondary))
            .frame(height: 20)
        }
    }

    /// " · Context 2 of 3" once the conversation has been compressed.
    private var contextLabel: String {
        guard model.contexts.count > 1, let id = model.activeContext?.id,
              let n = model.contextNumber(for: id) else { return "" }
        return " · Context \(n) of \(model.contexts.count)"
    }

    private var renameField: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .trailing) {
                TextField("Conversation title", text: Bindable(ui).renameDraft)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IK.text)
                    .tint(theme.accent)
                    .focused($renameFocused)
                    .submitLabel(.done)
                    .onSubmit(commitRename)
                    .padding(.leading, 12)
                    .padding(.trailing, 44)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(IK.wash(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5))
                if !ui.renameDraft.isEmpty {
                    Button { ui.renameDraft = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.chrome)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(IK.wash(0.22)))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear title")
                }
            }
            Button(action: commitRename) {
                Text("Done").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(width: max(paneWidth - 32, 280))
    }

    private func commitRename() {
        let title = ui.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        ui.renaming = false
        renameFocused = false
        guard !title.isEmpty, title != liveConversation.title else { return }
        Task { await convos.rename(id: model.conversation.id, title: title) }
    }

    private var contextFraction: Double? {
        guard let t = model.contextTokens, let w = model.contextWindow, w > 0 else { return nil }
        return Double(t) / Double(w)
    }

    private var gaugeLabel: String {
        if let f = contextFraction { return "Context \(Int((f * 100).rounded()))% full, conversation info" }
        return "Conversation info"
    }

    // MARK: Composer slot

    private var contextWarning: ContextWarning? {
        guard !model.isDraft else { return nil }
        return model.contextWarning(threshold: app.preferences.preferences.contextWarningTokens)
    }

    @ViewBuilder
    private var bottomSlot: some View {
        VStack(spacing: 8) {
            banners
            if let archivedAt = liveConversation.archivedAt {
                ArchivedCard(conversationID: liveConversation.id, archivedAt: archivedAt)
            } else if let pending = model.pendingCompressionSummary {
                // The server refuses sends and compactions until a
                // pending summary is confirmed or deleted.
                ReviewCard(message: pending, model: model, ui: ui)
            } else if let elicit {
                ElicitCard(conversationID: model.conversation.id, request: elicit)
                    .id(elicit.id)
            } else if model.showingCompactView {
                CompressCard(model: model, ui: ui)
            } else {
                // Keyboard-sized on a big phone; smaller on a short one so
                // the transcript keeps some room.
                Composer(model: model, ui: ui, onSend: onSend, onStop: onStop,
                         trayHeight: min(282, max(200, (rootHeight * 0.4).rounded())))
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let err = model.loadError, !model.messages.isEmpty || model.isDraft {
            StatusBanner(systemImage: "exclamationmark.triangle", text: err) { model.loadError = nil }
        }
        if let err = app.speech.playbackError {
            StatusBanner(systemImage: "speaker.slash", text: err) { app.speech.clearError() }
        }
        if app.connectivity.state == .offline {
            StatusBanner(systemImage: "wifi.exclamationmark", text: "Server unreachable. Messages queue and send when it’s back.")
        }
        if let err = model.compactError, !model.showingCompactView {
            NoticeBanner(systemImage: "exclamationmark.triangle", text: "Compression failed: \(err)") { model.compactError = nil }
                .fixedSize(horizontal: false, vertical: true)
        }
        if let warning = contextWarning, liveConversation.archivedAt == nil, model.pendingCompressionSummary == nil,
           !model.isCompacting {
            Button {
                if !model.showingCompactView { ui.openCompress(model: model) }
            } label: {
                NoticeBanner(systemImage: "exclamationmark.triangle", text: warningText(warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .disabled(model.isStreaming)
            .accessibilityHint(model.showingCompactView ? "" : "Opens Compress")
        }
    }

    private func warningText(_ w: ContextWarning) -> String {
        if let window = model.contextWindow, window > 0 {
            let pct = Int((Double(w.tokens) / Double(window) * 100).rounded())
            return "This context is \(pct)% full. Replies get slower and dearer from here."
        }
        return "This context is \(ContextWarning.compact(w.tokens)) tokens. Replies get slower and dearer from here."
    }

    // MARK: Draft

    private var draftStart: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DraftStart(model: model, profiles: convos.profiles,
                           lastUsedProfileID: lastUsedProfileID,
                           onOpenSettings: { showingSettings = true })
                // What creating the conversation will seed: the system
                // message, a welcome.
                ForEach(model.messages) { msg in
                    MessageRow(message: msg, model: model, ui: ui)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, minHeight: convos.profiles.contains { !$0.parentOnly } ? nil : 560,
                   alignment: .top)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollDismissesKeyboard(.interactively)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
    }

    private var lastUsedProfileID: String? {
        convos.conversations.filter { $0.archivedAt == nil }
            .max { ($0.lastActivityAt ?? $0.updatedAt) < ($1.lastActivityAt ?? $1.updatedAt) }?.profileID
    }

    // MARK: Transcript

    @ViewBuilder
    private var messageScroll: some View {
        if let err = model.loadError, model.messages.isEmpty, !model.isDraft {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(IK.orange)
                Text("Couldn’t load this conversation").font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                Text(err).font(.system(size: 14)).foregroundStyle(IK.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.loading && model.messages.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            paneScrollBody
                // Whole points: when the composer's slot leaves the
                // transcript little room, its height and top inset feed
                // each other, and unrounded values chase float jitter
                // forever.
                .onGeometryChange(for: [CGFloat].self) { proxy in
                    [proxy.size.width, proxy.size.height, proxy.safeAreaInsets.top].map { $0.rounded() }
                } action: { v in
                    paneWidth = v[0]
                    viewportHeight = v[1]
                    navClearance = v[2]
                }
                // Status-bar tap scrolls to the oldest message, the
                // content end here; the system gesture targets offset 0
                // (the newest edge), so the bridge claims it.
                .background(StatusBarTapBridge(onTap: scrollToOldest).frame(width: 2, height: 2))
                // The under-the-bar fade, drawn in screen space where no
                // transform can misplace it: the system scroll-edge
                // effect is hidden on this scroll (its extent math breaks
                // on inverted scroll views, FB20540755). Purely visual;
                // anything hit-testable here steals the transcript's pans
                // and long-presses.
                .overlay(alignment: .top) {
                    let h = navClearance + 21
                    LinearGradient(
                        stops: [
                            .init(color: theme.chrome, location: 0),
                            .init(color: theme.chrome, location: h > 0 ? (navClearance + 1) / h : 0.9),
                            .init(color: theme.chrome.opacity(0), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: h)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }
        }
    }

    @ViewBuilder
    private var paneScrollBody: some View {
            ScrollView {
                // FLIPPED STACK: content-space top = the newest edge.
                // Children are listed newest-first and each row applies
                // its own y-flip (`chatRowFlip`), so through the scroll
                // view's outer flip the transcript reads chronological.
                //
                // EAGER VStack, deliberately not LazyVStack. On iOS 26
                // each row's un-flip is committed as a CALayer transform
                // on a per-row UIKit portal container (the containers
                // exist because of the rows' context menus — hierarchy-
                // dump verified). When LazyVStack realizes a row
                // MID-FLING, the row's drawing appears frames before
                // that transform lands, and the whole message renders
                // upside-down until scroll settle (device-video
                // verified, sustained 400ms+). An eager stack realizes
                // every row in the entry transaction, where content and
                // transform commit together — the race is unreachable,
                // and every offset estimate LazyVStack would have
                // guessed at becomes exact. Entry cost is bounded by
                // MarkdownBudget: the 200×800w fixture plus a 180KB
                // summary card paints inside the push animation
                // (sim-measured); watch entry feel and memory on
                // device before scaling fixtures further.
                VStack(alignment: .leading, spacing: 18) {
                    // The park: the streaming row's rendered height caps at
                    // about one viewport (see StreamingArea).
                    StreamingArea(model: model, waitingOnInput: elicit != nil, clipBudget: streamClipBudget)
                    // Pending user is its own subview so it observes
                    // only pendingUserText, not the chunk-rate
                    // streaming state.
                    PendingUserArea(model: model, queueTick: queueTick)
                    // Settled history is its own subview that observes
                    // only `model.messages`. Without this split, every
                    // streaming chunk (which mutates streamingText on the
                    // shared @Observable model) would re-eval the entire
                    // stack content closure — running ForEach over
                    // N messages and constructing N MessageRow values
                    // per chunk, even though none of them changed. The
                    // eager stack raises the stakes: a spurious re-eval
                    // re-renders ALL rows, not just realized ones.
                    ChatHistoryArea(model: model, ui: ui)
                        .equatable()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                // A short conversation sits on the composer, the blank
                // space above it: the flipped stack at the NEAR end of a
                // viewport-height minimum is the visual bottom.
                .frame(
                    minHeight: viewportHeight > 0 ? viewportHeight : nil,
                    alignment: .top
                )
                // Width clamp on the scroll content, one layer of the
                // three-part containment for the "content slams to the
                // screen edges / margins shift left" bug family:
                //   - this cap keeps the padded stack from exceeding
                //     the pane when a wide child would drag it out;
                //   - the per-row exact pins (see ChatHistoryArea.
                //     rowWidth) make each row's width non-negotiable
                //     in transition passes (keyboard show, send
                //     relayout) that re-solve single rows against
                //     loose proposals;
                //   - the UIKit x-offset clamp in the geometry handler
                //     zeroes the horizontal drift those transitions
                //     leave behind (log-verified x=16 after keyboard
                //     show).
                // Deliberately `maxWidth:`, NOT an exact `width:` — an
                // exact frame was tried and CENTERS its content when a
                // narrower proposal arrives, which shifted the whole
                // transcript half the overflow to the left at rest.
                //
                // `.leading` alignment is THE margin fix: transition
                // passes (keyboard show, backfill batches) lay the
                // padded stack ~32pt oversized, and a center-aligned
                // frame places that overflow half on each side —
                // shifting the whole transcript 16pt left, visually
                // "the margins are gone", persisting on static
                // content until the next layout tick. (UIKit-verified
                // NOT a scroll-offset or inset problem: the backing
                // UIScrollView reads offset 0 / size 402 / inset 0
                // while the content draws displaced — the shift is
                // SwiftUI-internal placement.) Leading alignment
                // pins the left edge so an oversized pass can only
                // spill off the TRAILING side, transiently.
                .frame(
                    maxWidth: paneWidth > 0 ? paneWidth : .infinity,
                    alignment: .leading
                )
                // Layer probe for the horizontal-displacement bug
                // class: the scroll-content unit's global x. Fires on
                // every change; a nonzero minX here means the CONTENT
                // is displaced (offset probes read 0 for this class).
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minX
                } action: { minX in
                    contentUnitMinX = minX
                    scrollLog.notice("content-unit minX=\(Int(minX), privacy: .public)")
                }
                // Tap-to-dismiss for the composer keyboard.
                // `scrollDismissesKeyboard(.interactively)` (below)
                // alone needs actual scroll motion to fire — on a
                // short chain it never triggers, so the user has no
                // way to drop focus without sending or hitting a
                // button. simultaneousGesture lets row taps + bubble
                // long-presses keep working.
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                )
                // NOTE: no DragGesture here for user-scroll detection.
                // A simultaneous DragGesture on the scroll content
                // blocks ScrollView's pan entirely on iOS 26 (verified
                // in the simulator: neither finger drags nor scroll
                // wheel moved the content). User-scroll detection
                // lives in onScrollGeometryChange below, keyed off
                // `scrollPosition.isPositionedByUser`.
                //
                // scrollTargetLayout exposes row identities so the
                // send pin's `scrollTo(id:anchor:)` can hold the sent
                // message at the viewport top.
                .scrollTargetLayout()
            }
            .scrollPosition($scrollPosition)
            // Safe-area handling for the flip: automatic vertical
            // insets apply in CONTENT space, so the nav-bar clearance
            // (content top) would render at the visual bottom and the
            // content would run under the bar. Neutralize them and
            // re-apply mirrored — the measured top safe-area inset
            // goes on the content BOTTOM (visual top, clearing the
            // bar). The keyboard inset is ignored outright: the
            // composer below owns keyboard avoidance by layout, and
            // the automatic keyboard inset would render as a
            // nonsense gap at the visual top.
            .ignoresSafeArea(.container, edges: .vertical)
            .ignoresSafeArea(.keyboard)
            .contentMargins(.bottom, navClearance + 8, for: .scrollContent)
            .contentMargins(.top, 12, for: .scrollContent)
            // The iOS 26 progressive scroll-edge blur computes its
            // extent in the TRANSFORMED coordinate space (FB20540755
            // — known regression with inverted scroll views): the
            // nav fade painted upward from the visual bottom and
            // washed the whole pane. Re-assigning the bottom edge
            // was tried (hoping the overlay flips with the layer) —
            // it composites in screen space with transformed extent,
            // so no assignment renders correctly. Hide the effect
            // and give the bar a real background instead (below).
            .scrollEdgeEffectHidden(true, for: .all)
            // THE FLIP. Render-only vertical mirror: content offset 0
            // (the newest message) draws at the visual bottom, and
            // hit-testing passes through the transform so touches and
            // drags feel native. A scroll view starts at offset 0
            // natively, which inverted IS the newest edge — entry
            // needs no seek, no sizeChanges anchor, no curtain, and
            // no failsafe. Indicators would render mirrored (running
            // bottom-to-top), so they stay hidden.
            .scaleEffect(x: 1, y: -1)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    offset: geometry.contentOffset.y,
                    viewportHeight: geometry.containerSize.height,
                    contentWidth: geometry.contentSize.width,
                    viewportWidth: geometry.containerSize.width,
                    offsetX: geometry.contentOffset.x
                )
            } action: { old, m in
                metricsBox.latest = m
                // Inverted, "distance from the newest message" IS the
                // offset (minus the runway's blank spacer when live).
                //
                // Transient-motion telemetry. The scroll bugs this view
                // has a history of (offset lurches mid-stream, viewport
                // stranded past the content end) are only visible in
                // the gaps BETWEEN screenshots — this handler sees
                // every layout tick, so it logs the discontinuities
                // themselves. Notice-level so `log collect` after a
                // device repro carries the evidence. Gated on system-
                // driven motion (or an active stream) — user flings
                // produce big legitimate deltas; programmatic ones are
                // the bug class.
                let systemDriven = !scrollPosition.isPositionedByUser
                if systemDriven || model.isStreaming || model.isCompacting {
                    let dOff = m.offset - old.offset
                    let dContent = m.contentHeight - old.contentHeight
                    if abs(dOff) > 48 {
                        scrollLog.notice("JUMP dOff=\(Int(dOff), privacy: .public) off=\(Int(old.offset), privacy: .public)→\(Int(m.offset), privacy: .public) content=\(Int(m.contentHeight), privacy: .public) vp=\(Int(m.viewportHeight), privacy: .public) pin=\(positionHeld, privacy: .public) user=\(scrollPosition.isPositionedByUser, privacy: .public) streaming=\(model.isStreaming, privacy: .public)")
                    }
                    if abs(dContent) > 120, abs(dContent) > abs(dOff) {
                        scrollLog.notice("CONTENT-LURCH dContent=\(Int(dContent), privacy: .public) content=\(Int(old.contentHeight), privacy: .public)→\(Int(m.contentHeight), privacy: .public) off=\(Int(m.offset), privacy: .public)")
                    }
                    if m.offset < -8, systemDriven {
                        scrollLog.notice("PAST-ORIGIN off=\(Int(m.offset), privacy: .public) content=\(Int(m.contentHeight), privacy: .public)")
                    }
                }
                // The horizontal break-out ("margins shift left"):
                // content laid out wider than the pane, or the pane
                // horizontally displaced. Logged unconditionally —
                // any occurrence is a bug. (Note the keyboard-show
                // margin collapse does NOT move either of these — the
                // stack overflows its reported frame — so pixels, not
                // this probe, are the authority on margin health; see
                // the scan_margin harness note in the docs.)
                if m.contentWidth > m.viewportWidth + 1,
                   old.contentWidth <= old.viewportWidth + 1 {
                    scrollLog.notice("WIDTH-BREAKOUT content=\(Int(m.contentWidth), privacy: .public) viewport=\(Int(m.viewportWidth), privacy: .public) streaming=\(model.isStreaming, privacy: .public)")
                }
                // X-drift telemetry: SwiftUI reports a nonzero
                // horizontal offset when a transition pass lays the
                // content oversized (the backing UIScrollView reads
                // clean throughout — this is content placement, not
                // scroll state). With the frame's `.leading`
                // alignment the left margin can't move; this log
                // remains to catch any regression of that class.
                if abs(m.offsetX) > 0.5, abs(old.offsetX) <= 0.5 {
                    scrollLog.notice("X-DRIFT x=\(Int(m.offsetX), privacy: .public)")
                }

                // Release any live one-shot position the moment the
                // user takes over. A held position is STICKY — it
                // re-applies against the user's drag (verified
                // pre-inversion: repeated drags barely moved while a
                // pin held). Replacing the binding while the user's
                // gesture owns the viewport breaks the hold without
                // the at-rest one-viewport rewind.
                if positionHeld, scrollPosition.isPositionedByUser {
                    scrollLog.notice("position released: user took over")
                    positionHeld = false
                    scrollPosition = ScrollPosition()
                }

                // Pill visibility: inverted, "distance from the
                // newest message" is simply the offset.
                let newFar = m.offset > scrollToBottomThreshold
                if newFar != isFarFromBottom {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isFarFromBottom = newFar
                    }
                }
            }
            // Always rendered and faded rather than inserted, so the
            // overlay subtree isn't rebuilt per state change; hit testing
            // is gated so a hidden pill can't take taps.
            .overlay(alignment: .bottom) {
                FollowPill(streaming: model.isStreaming) {
                    Haptics.impact(.light)
                    // Inverted, "bottom" is offset 0: one exact absolute
                    // scroll. Mid-stream this returns to the parked frame;
                    // the tail stays below the fold until the terminal.
                    oneShotScroll(y: 0, reason: "pill")
                }
                .padding(.bottom, 56)
                .opacity(isFarFromBottom || forceFollowPill ? 1 : 0)
                .allowsHitTesting(isFarFromBottom || forceFollowPill)
                .animation(.easeInOut(duration: 0.22), value: isFarFromBottom)
                .accessibilityHidden(!(isFarFromBottom || forceFollowPill))
            }
            // Intentionally NOT scrolling on `model.messages.count` —
            // that handler used to fire on stream end (streaming row
            // → settled assistant message bumps count by 1) and on
            // deletes, both of which jerked the viewport. Stream end
            // and delete hold the user's current scroll position.
            .onChange(of: model.pendingUserText) { _, text in
                if text != nil {
                    // Send: no scroll command at all — the question
                    // lands at the visible rest edge and the follow
                    // is native. The only exception: the user had
                    // scrolled away before sending, in which case
                    // one exact catch-up to the rest edge shows them
                    // their own message.
                    if metricsBox.latest.offset > 64 {
                        oneShotScroll(y: 0, reason: "send catch-up")
                    }
                } else if model.sending || model.isStreaming {
                    // Pending sentinel swapped for the real user row —
                    // a pure equal-height row swap at the head; the
                    // rest-edge frame doesn't move. Nothing to do.
                } else {
                    // Send failed before a run started — the terminal
                    // that normally releases the clip never fires.
                    streamClipBudget = 0
                }
            }
            .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                if !wasStreaming && isStreaming {
                    // Arm the park clip HERE, not at send: by stream
                    // start the keyboard has dropped and
                    // viewportHeight is the full pane, so "reply top
                    // at viewport top" is measured against the frame
                    // the user actually watches.
                    streamClipBudget = max(240, viewportHeight)
                    scrollLog.notice("stream start (clip=\(Int(streamClipBudget), privacy: .public))")
                } else if wasStreaming && !isStreaming {
                    // Terminal edge: release the clip (the settled
                    // row renders in full), then one exact id-solve
                    // restores the parked frame — the reply's top at
                    // the viewport top, reading starts where the
                    // reply does. Short replies clamp to the rest
                    // edge, the same frame they streamed in. Skipped
                    // entirely when the user owns the viewport.
                    scrollLog.notice("stream terminal")
                    streamClipBudget = 0
                    Task { @MainActor in
                        // One beat for the clip release + settled row
                        // swap to lay out before the solve measures.
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !scrollPosition.isPositionedByUser,
                              let replyID = model.messages.last?.id else { return }
                        scrollLog.notice("terminal: reply-top solve (held)")
                        positionHeld = true
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            scrollPosition.scrollTo(id: replyID, anchor: UnitPoint(x: 0, y: 1))
                        }
                        // NO timer release — the reply-top frame HOLDS
                        // past the terminal until the user takes over
                        // (explicit UX spec: "stick the message at the
                        // top and hold it there past the stream end").
                        // The geometry handler's user-grab release is
                        // the only exit. Holding is safe here where it
                        // wasn't mid-stream: the transcript is static
                        // and the eager stack is fully laid out, so
                        // the held solve re-applies identical values
                        // (no estimate churn to shimmy against), and
                        // it rides keyboard-driven viewport changes
                        // keeping the reply top pinned. A timed
                        // release also risked the documented
                        // one-viewport rewind on the binding swap —
                        // the likely mechanism behind the on-device
                        // "when the stream ends it resets to the
                        // bottom" report.
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // The toolbar title button (and the device-only status-bar
            // bridge) live outside this body; both funnel through this
            // notification. Filtered by conversation id so a stale
            // observer from a previous conversation can't fire.
            .onReceive(NotificationCenter.default.publisher(for: .psmithScrollToContextStart)) { note in
                guard (note.object as? String) == model.conversation.id else { return }
                scrollToOldest()
            }
    }

    /// Jump to the start of the context — the oldest message's first
    /// lines at the visual top. An exact id-solve, same anchor math as
    /// the terminal solve: anchor y:1 aligns the row's content-space
    /// bottom (its VISUAL top, through the flips) with the viewport's
    /// content-space bottom (the visual top). Exact because the eager
    /// stack has every row laid out. The previous `scrollTo(edge:
    /// .bottom)` resolved to the WRONG END on device ("scroll to top
    /// scrolls to bottom", user-reported) — edge semantics through the
    /// flip aren't trustworthy; row ids are.
    private func scrollToOldest() {
        guard let oldestID = model.messages.first?.id else { return }
        scrollLog.notice("scroll to oldest (top tap) id=\(oldestID, privacy: .public)")
        positionHeld = true
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            scrollPosition.scrollTo(id: oldestID, anchor: UnitPoint(x: 0, y: 1))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if positionHeld, !scrollPosition.isPositionedByUser {
                positionHeld = false
                scrollPosition = ScrollPosition()
            }
        }
    }

    /// One exact absolute scroll + at-rest release. The binding must
    /// not stay held (held positions re-apply against user drags and
    /// re-solve on re-lays), so every one-shot schedules its own
    /// release a beat later.
    private func oneShotScroll(y: CGFloat, reason: String) {
        scrollLog.notice("one-shot scroll y=\(Int(y), privacy: .public) (\(reason, privacy: .public))")
        positionHeld = true
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            scrollPosition.scrollTo(x: 0, y: y)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if positionHeld, !scrollPosition.isPositionedByUser {
                positionHeld = false
                scrollPosition = ScrollPosition()
            }
        }
    }

}

/// The scroll metrics the pill and the telemetry read; Equatable so
/// `onScrollGeometryChange` only fires when one actually moves.
private struct ScrollMetrics: Equatable, Sendable {
    var contentHeight: CGFloat
    var offset: CGFloat
    var viewportHeight: CGFloat
    var contentWidth: CGFloat
    var viewportWidth: CGFloat
    var offsetX: CGFloat
}

/// "Follow the reply": back to the newest edge (Streaming).
private struct FollowPill: View {
    let streaming: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold))
                Text(streaming ? "Follow the reply" : "Latest messages").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(theme.accentInk)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(theme.accent.opacity(0.22)).interactive(), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.45), lineWidth: 1).allowsHitTesting(false))
        .shadow(color: IK.shadow, radius: 9, y: 6)
    }
}

// MARK: - Transcript areas
//
// Split so chunk-rate streaming mutations stay out of the settled
// history: each area reads only the observable properties it uses, so
// `streamingText` changing 20-50 times a second doesn't re-run ForEach
// over hundreds of messages.

/// Settled history, newest first for the flipped stack. Rows render
/// eagerly (see paneScrollBody), so each row's un-flip commits with its
/// content.
private struct ChatHistoryArea: View, @MainActor Equatable {
    @Bindable var model: ConversationViewModel
    let ui: ConversationUIState
    @Environment(\.chatPaneWidth) private var paneWidth

    /// Parent re-renders never need to re-diff the whole ForEach;
    /// message changes still re-render through observation. Observation
    /// only covers the model this body last read, and ConversationView
    /// builds a new view model each time the screen reappears (a pushed
    /// page popping), so a new model has to count as a change: otherwise
    /// the history keeps showing the old one and every later message is
    /// missing until the conversation is reopened.
    static func == (a: ChatHistoryArea, b: ChatHistoryArea) -> Bool { a.model === b.model && a.ui === b.ui }

    /// Exact per-row width: transition passes (keyboard show, send) can
    /// re-solve a single row against a loose proposal and render it
    /// wide; pinning each row makes the width non-negotiable.
    private var rowWidth: CGFloat? { paneWidth > 32 ? paneWidth - 32 : nil }

    var body: some View {
        let modelChanges = model.modelChangeMessageIDs
        let firstMetered = model.firstMeteredReplyID
        // Its own stack: the equatable wrapper isn't flattened into the
        // parent's, which would space these rows at the default 8.
        VStack(alignment: .leading, spacing: 18) {
        ForEach(model.messages.reversed()) { msg in
            Group {
                if msg.role == .compressionSummary && model.editingMessage?.id != msg.id
                    && ui.confirmingDelete?.messageID != msg.id {
                    SummaryCard(message: msg, model: model)
                        .messageActionsOnLongPress {
                            Haptics.impact(.medium)
                            withAnimation(.snappy(duration: 0.22)) { model.actionMenuMessage = msg }
                        }
                } else {
                    MessageRow(
                        message: msg,
                        previousMessage: model.messages.first(where: { $0.id == msg.parentID }),
                        model: model,
                        ui: ui,
                        modelChanged: modelChanges.contains(msg.id),
                        isFirstMeteredReply: msg.id == firstMetered
                    )
                }
            }
            .frame(width: rowWidth, alignment: .leading)
            .chatRowFlip()
            .id(msg.id)
        }
        }
    }
}

/// Your message before the send returns, and messages waiting in the
/// offline queue (OfflineQueued).
private struct PendingUserArea: View {
    @Bindable var model: ConversationViewModel
    /// Bumped by the screen on every queue change: the queue isn't
    /// observable, so a new value is what re-reads `queuedEntries`.
    var queueTick: Int
    @Environment(\.chatPaneWidth) private var paneWidth

    private var rowWidth: CGFloat? { paneWidth > 32 ? paneWidth - 32 : nil }

    // Rows straight into the transcript's stack, so an empty area adds
    // no child (and no gap) to it.
    var body: some View {
        ForEach(model.queuedEntries.reversed()) { entry in
            QueuedUserRow(text: entry.content)
                .frame(width: rowWidth, alignment: .leading)
                .chatRowFlip()
                .id("__queued_\(entry.id)")
        }
        if let pending = model.pendingUserText {
            UserBubble(text: pending)
                .frame(width: rowWidth, alignment: .leading)
                .chatRowFlip()
                .id("__pending__")
        }
    }
}

/// A message waiting for the server to come back.
private struct QueuedUserRow: View {
    let text: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            UserBubble(text: text)
            HStack(spacing: 6) {
                Text("Queued").font(.system(size: 12, weight: .medium)).foregroundStyle(IK.orange)
                IKSpinner(size: 10, color: IK.orange)
            }
            .frame(height: 24)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Queued, waiting to send")
        }
        .opacity(0.7)
    }
}

/// The turn in flight. Observes the streaming state so chunks re-render
/// this and only this.
private struct StreamingArea: View {
    @Bindable var model: ConversationViewModel
    var waitingOnInput = false
    /// Nonzero while a stream's park is live: the row's rendered height
    /// caps here.
    var clipBudget: CGFloat = 0
    @Environment(\.chatPaneWidth) private var paneWidth

    private var rowWidth: CGFloat? { paneWidth > 32 ? paneWidth - 32 : nil }

    // Modifiers stay inside the branches: a frame on the empty case
    // would still be a stack child and add a gap above the composer.
    var body: some View {
        if model.isCompacting {
            parked(CompactingCard(model: model))
        } else if !model.streamingText.isEmpty || model.isStreaming {
            parked(StreamingReply(model: model, waitingOnInput: waitingOnInput))
        }
    }

    private func parked<V: View>(_ row: V) -> some View {
        row
            .frame(width: rowWidth, alignment: .leading)
            .chatRowFlip()
            // fixedSize before the cap: frame(maxHeight:) clamps the
            // height proposal, and MarkdownUI under a short proposal
            // degrades every paragraph to one truncated line. This way
            // the content lays out at its ideal height and the cap only
            // limits layout size; the clip hides the overflow.
            .fixedSize(horizontal: false, vertical: true)
            // Alignment .bottom in content space keeps the reply's first
            // lines (through the flips) in view, the tail behind the clip
            // until the terminal swap.
            .frame(maxHeight: clipBudget > 0 ? clipBudget : nil, alignment: .bottom)
            .clipped()
            .id("__streaming__")
    }
}

extension View {
    /// Un-flips one row inside the inverted transcript. Render-only;
    /// layout and geometry are untouched.
    fileprivate func chatRowFlip() -> some View {
        scaleEffect(x: 1, y: -1)
    }
}
