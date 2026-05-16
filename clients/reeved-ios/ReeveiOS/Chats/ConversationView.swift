import SwiftUI
import ReeveKit
import ReeveUI

/// iOS conversation surface. Constructs `ConversationViewModel` against
/// the live `reeved`, then renders the status strip + message scroll.
/// Per `docs/ios-screens.md` §2.5: composer arrives in Phase 5d, the
/// page-replace alternates (Compact / Contexts / Settings / Model
/// Picker) become push/sheet destinations in Phase 5g.
struct ConversationView: View {
    let conversation: ReeveConversation
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.notifier) private var notifier
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ConversationViewModel?

    var body: some View {
        Group {
            if let model {
                ConversationBody(model: model, liveConversation: liveConversation)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // Mark this conversation as on-screen so a terminal arriving
            // while the user is looking at it doesn't raise the "new
            // message" dot on its sidebar row. markViewing also clears
            // any pending unseen flag — opening the chat is the user's
            // implicit "I've seen it."
            app.streamHub.markViewing(conversationID: conversation.id)
        }
        .onDisappear {
            app.streamHub.markStoppedViewing(conversationID: conversation.id)
        }
        .sheet(item: Binding(
            get: { app.streamHub.activeStream(conversationID: conversation.id)?.pendingElicitations.first },
            set: { _ in /* ElicitSheet calls clearPendingElicitation on its own */ }
        )) { pending in
            ElicitSheet(conversationID: conversation.id, pending: pending)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Per `docs/ios-screens.md` §1.8 + §4.1: cancel the live
            // SSE on background, re-subscribe from the last seen
            // sequence on foreground. Supervisor keeps streaming the
            // whole time and persists chunks to stream_chunks; replay
            // is correct-by-construction.
            guard let m = model else { return }
            switch newPhase {
            case .background, .inactive:
                m.suspendActiveStream()
            case .active:
                m.resumeStreamIfPaused()
            @unknown default:
                break
            }
        }
        .task(id: conversation.id) {
            // Drop stale parsed-markdown entries from the previous
            // conversation so the cache doesn't accumulate forever
            // across long sessions. Each conversation's entries land
            // back in the cache as soon as its first load() returns.
            MarkdownCache.shared.clear()
            // Capture env-injected notifier into the closure so the VM-side
            // firing path doesn't reach into a global. iOS Notifier impl
            // arrives in Phase 8b; for now `\.notifier` resolves to the
            // NoopNotifier default.
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
                }
            )
            self.model = m
            await m.load()
            // Loaded alongside the message list so the model chip
            // can show the display name (not just the model id) and
            // contexts toolbar item knows the count up-front.
            await m.loadContexts()
            await m.loadAvailableModels()
            // Pre-warm parsed markdown in a background task so the
            // first scroll-back through long history doesn't pay the
            // parse cost on every realization. Cache-aware: on a
            // subsequent terminal reload, only new messages parse.
            MarkdownCache.shared.prewarm(
                m.messages.map {
                    let stamp = $0.editedAt?.timeIntervalSince1970 ?? 0
                    return (key: "\($0.id):\(stamp)", source: $0.displayContent ?? $0.content)
                }
            )
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Always read the latest snapshot from the list so an auto-generated
    /// title propagates without forcing a remount of this view.
    private var liveConversation: ReeveConversation {
        convos.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    private var navTitle: String {
        let title = liveConversation.title?.isEmpty == false ? liveConversation.title! : "Untitled"
        return title
    }
}

// MARK: - Conversation body (separated for env injection of model)

private struct ConversationBody: View {
    @Bindable var model: ConversationViewModel
    let liveConversation: ReeveConversation

    /// Auto-follow tracking. While streaming, we keep the streaming
    /// row's bottom in view *until* its height reaches the viewport's
    /// height — at which point we stop following so the user can read
    /// the top of a long response without it being scrolled away.
    /// Touching the scroll surface disengages follow forever (see
    /// `.onScrollPhaseChange`).
    @State private var autoFollow = true
    /// Real-geometry scroll position. Driving the bottom-pin scroll
    /// through `ScrollPosition.scrollTo(point:)` with a Y computed
    /// from `onScrollGeometryChange`'s reported contentSize uses the
    /// actual ScrollView geometry rather than LazyVStack's row-offset
    /// estimates — the latter over-inflate in long chats (especially
    /// for unrealised rows above the viewport with variable-height
    /// markdown) and cause the auto-follow to land past the actual
    /// content end. Symptom: viewport jerks down to blank space
    /// mid-stream, then snaps back at terminal when the scroll-view
    /// clamps the out-of-bounds offset.
    @State private var scrollPosition = ScrollPosition()
    @State private var showingMissingCostInfo = false
    /// Live height of the in-flight streaming bubble. Updated via
    /// `.onGeometryChange` on the StreamingRow. Used to decide when
    /// to stop auto-follow.
    @State private var streamingRowHeight: CGFloat = 0
    /// Viewport height of the message scroll, captured from the
    /// outer GeometryReader. Used as the cap above which auto-follow
    /// disengages so a long response stops scrolling once the bubble
    /// fills the screen.
    @State private var viewportHeight: CGFloat = 0
    /// True when the scroll position is more than `scrollToBottomThreshold`
    /// points away from the bottom of the message list. Drives the
    /// "Scroll to bottom" pill that slides down from below the status
    /// strip; tapping it returns the user to the latest message.
    @State private var isFarFromBottom: Bool = false

    /// Distance (pt) from the bottom that flips the "scroll to bottom"
    /// affordance on. Roughly one bubble-height of slack so the pill
    /// doesn't pop the moment the user reads past the last message.
    private let scrollToBottomThreshold: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            if let err = model.loadError, !model.messages.isEmpty {
                loadErrorBanner(err)
            }
            messageScroll
            Composer(model: model)
        }
        .refreshable {
            await model.load()
        }
        .onChange(of: model.messages.count) { _, _ in
            // Pre-warm parsed markdown for any newly-added messages
            // (terminal reloads, fork switches, manual refresh). Cache
            // already-present entries skip — only the new assistant
            // turn(s) pay the parse cost, and that happens off the
            // main thread.
            MarkdownCache.shared.prewarm(
                model.messages.map {
                    let stamp = $0.editedAt?.timeIntervalSince1970 ?? 0
                    return (key: "\($0.id):\(stamp)", source: $0.displayContent ?? $0.content)
                }
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showingCompactView = true
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .disabled(model.isStreaming || model.isCompacting)
                .accessibilityLabel("Compact")
            }
        }
        .sheet(isPresented: $model.showingCompactView) {
            CompactView(model: model)
        }
        // Single message-edit sheet, bound to the active editingMessage
        // on the view model. `.sheet(item:)` avoids the per-row computed-
        // binding loop the inline `.sheet(isPresented:)` was hitting.
        .sheet(item: $model.editingMessage) { msg in
            EditMessageSheet(message: msg, model: model)
        }
        .toast(
            message: Binding(
                get: { model.lastPromotedContextID == nil ? nil : "Switched to new context" },
                set: { _ in model.lastPromotedContextID = nil }
            ),
            systemImage: "wand.and.stars"
        )
        // Note: model-picker sheet is presented from the Composer
        // itself. SwiftUI doesn't reliably dispatch multiple
        // `.sheet(isPresented:)` modifiers from the same anchor;
        // attaching the picker at its trigger view sidesteps the
        // race.
    }

    // MARK: - Status strip

    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 8) {
            costChip
            if let context = activeContextLabel {
                NavigationLink {
                    ContextListView(model: model)
                } label: {
                    HStack(spacing: 3) {
                        chipLabel(text: context, systemImage: "tray.full")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open contexts")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chipLabel(text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    /// Cost chip with a best-effort total + a (!) tap target when
    /// any assistant message in the active context has usage data
    /// but no per-token price (subscription / flat-fee models like
    /// Z.AI Coding Plan don't populate per-million pricing in
    /// `user_models`, so the cost rolls up as $0). Tapping the
    /// warning lists which models contributed cost-less turns so
    /// the user can decide whether to wire prices in.
    @ViewBuilder
    private var costChip: some View {
        // Show even when the rollup is zero — better than vanishing
        // silently. The (!) makes the missing-data case legible.
        let total = accruedCost
        let label = String(format: "$%.4f", total)
        HStack(spacing: 6) {
            chipLabel(text: label, systemImage: "dollarsign.circle")
            if !modelsMissingCost.isEmpty {
                Button {
                    showingMissingCostInfo = true
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cost data missing")
            }
        }
        .alert(
            "Cost is approximate",
            isPresented: $showingMissingCostInfo
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            let names = modelsMissingCost.joined(separator: "\n• ")
            Text("Some turns ran on models without per-token pricing in your catalog, so they're not included in the running total:\n\n• \(names)")
        }
    }

    /// Sum of every assistant message's `totalCostUsd` in the active
    /// context. Messages with nil cost contribute nothing — those
    /// are the ones the warning chip surfaces. Computed off
    /// `model.messages` (the linear chain currently visible) rather
    /// than the contexts aggregate so the value reflects what's on
    /// screen even on cold cache hits.
    private var accruedCost: Double {
        model.messages.reduce(0) { acc, m in
            acc + (m.usage?.totalCostUsd ?? 0)
        }
    }

    /// Distinct display-name list of models that produced an assistant
    /// message with usage data (real LLM call) but no totalCostUsd
    /// (no per-token price). Sorted, deduped.
    private var modelsMissingCost: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for m in model.messages {
            guard m.role == .assistant,
                  m.usage != nil,
                  m.usage?.totalCostUsd == nil,
                  let mid = m.modelID else { continue }
            // Resolve to display name when we know it; otherwise fall
            // back to the raw id so the user can still identify it.
            let pid = m.providerID
            let display = model.availableModels
                .first(where: { $0.modelID == mid && (pid == nil || $0.providerID == pid) })?
                .displayName ?? mid
            if seen.insert(display).inserted {
                out.append(display)
            }
        }
        return out.sorted()
    }

    /// Header pill label for the active context. Numbering matches the
    /// Contexts list (chronological by createdAt) so "Context 2" in
    /// the header points at the same row the user sees in the list.
    /// Hidden when there's only one context in the conversation —
    /// the pill carries no signal in that case.
    private var activeContextLabel: String? {
        guard let ctx = model.activeContext, model.contexts.count > 1 else { return nil }
        let chronological = model.contexts.sorted { $0.createdAt < $1.createdAt }
        let idx = (chronological.firstIndex(where: { $0.id == ctx.id }) ?? 0) + 1
        return "Context \(idx)"
    }

    private func loadErrorBanner(_ err: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { model.loadError = nil }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Message scroll

    @ViewBuilder
    private var messageScroll: some View {
        if let err = model.loadError, model.messages.isEmpty {
            EmptyStateView(
                "Failed to load",
                systemImage: "exclamationmark.triangle",
                description: "\(err)"
            )
        } else if model.loading && model.messages.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                paneScrollBody
                    .environment(\.chatPaneWidth, geo.size.width)
                    .onAppear { viewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, new in viewportHeight = new }
            }
        }
    }

    @ViewBuilder
    private var paneScrollBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Settled history is its own subview that observes
                    // only `model.messages`. Without this split, every
                    // streaming chunk (which mutates streamingText on the
                    // shared @Observable model) would re-eval the entire
                    // LazyVStack content closure — running ForEach over
                    // N messages and constructing N MessageRow values
                    // per chunk, even though none of them changed.
                    ChatHistoryArea(model: model)
                    // Pending user is its own subview for the same
                    // reason — observes only pendingUserText, not the
                    // chunk-rate streaming state.
                    PendingUserArea(model: model)
                    StreamingArea(
                        model: model,
                        streamingRowHeight: $streamingRowHeight
                    )
                }
                .padding()
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
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    offset: geometry.contentOffset.y,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { _, m in
                // Single pass over the actual scroll geometry handles
                // both jobs: pill visibility and auto-follow scrolling.
                // Driving auto-follow from here (rather than from
                // every streamingRowHeight @State change) means we
                // fire only on real layout shifts — drastically
                // fewer @State mutations to scrollPosition, which is
                // what was causing the lag.
                let bottomEdge = m.offset + m.viewportHeight
                let distance = m.contentHeight - bottomEdge

                // Pill visibility — gated to avoid churn during follow.
                if !autoFollow {
                    let newFar = distance > scrollToBottomThreshold
                    if newFar != isFarFromBottom {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isFarFromBottom = newFar
                        }
                    }
                }

                // Auto-follow: pin the viewport bottom to the
                // content bottom whenever follow is engaged. We
                // correct in BOTH directions, not just downward:
                // the keyboard-dismissal-on-submit case parks the
                // viewport past the content bottom (scrollTo(.bottom)
                // lands at the keyboard-up bottom, then the keyboard
                // dismisses and the viewport grows — leaving
                // m.offset > targetY and an empty band below the
                // last message). A "down only" guard would leave
                // that wedge in place forever; correcting upward
                // when autoFollow is true closes it.
                //
                // It's safe to correct upward because
                // onScrollPhaseChange disables autoFollow the
                // moment the user actually drags — so this only
                // ever fires when we're in pin-mode and the
                // viewport / content geometry has drifted out of
                // alignment on its own.
                guard autoFollow else { return }
                let targetY = max(0, m.contentHeight - m.viewportHeight)
                guard abs(m.offset - targetY) > 0.5 else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    scrollPosition.scrollTo(point: CGPoint(x: 0, y: targetY))
                }
            }
            // Pill is always-rendered with opacity, not conditional view
            // insertion, so SwiftUI doesn't tear down and rebuild the
            // overlay subtree per state change. Hit testing is gated so
            // a hidden pill can't intercept taps.
            .overlay(alignment: .top) {
                Button {
                    Haptics.impact(.light)
                    autoFollow = true
                    withAnimation(.easeInOut(duration: 0.22)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.caption.weight(.semibold))
                        Text("Scroll to bottom")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .opacity(isFarFromBottom && !autoFollow ? 1 : 0)
                .allowsHitTesting(isFarFromBottom && !autoFollow)
                .animation(.easeInOut(duration: 0.22), value: isFarFromBottom)
                .accessibilityLabel("Scroll to bottom of conversation")
                .accessibilityHidden(!isFarFromBottom)
            }
            .onAppear {
                // Initial position: pin to the actual content bottom
                // via real geometry. The previous "scrollTo(lastID,
                // anchor: .top)" used LazyVStack estimates that
                // mis-land on first appear when not every row is
                // realised yet.
                scrollPosition.scrollTo(edge: .bottom)
            }
            // Intentionally NOT scrolling on `model.messages.count` —
            // that handler used to fire on stream end (streaming row
            // → settled assistant message bumps count by 1) and on
            // deletes, both of which jerked the viewport. Stream end
            // and delete now hold the user's current scroll position.
            .onChange(of: model.pendingUserText) { _, text in
                if text != nil {
                    autoFollow = true
                    streamingRowHeight = 0
                    // Scroll the just-sent message to the BOTTOM of the
                    // viewport, not the top. The old "anchor: .top"
                    // approach landed the pending row at the scroll
                    // view's top edge, which sits under the inline
                    // nav bar + status strip — making the user's
                    // message invisible until they scrolled. Pinning
                    // to bottom keeps it visible regardless of where
                    // the header overlay actually lands, and once
                    // streaming begins, auto-follow takes over
                    // naturally (the spec's "scroll down with
                    // generation" rule covers the rest).
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
            .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                if !wasStreaming && isStreaming {
                    autoFollow = true
                    streamingRowHeight = 0
                } else if wasStreaming && !isStreaming {
                    // Terminal edge: reset the streaming-row bookkeeping.
                    // We deliberately don't scroll here — iOS's natural
                    // contentSize-change handling snaps the viewport into
                    // valid bounds without an animated bounce, and the
                    // during-stream auto-follow has kept us at the real
                    // bottom throughout, so no further work is needed.
                    streamingRowHeight = 0
                }
            }
            .onChange(of: streamingRowHeight) { _, newHeight in
                // streamingRowHeight is now used only for the disengage
                // check, not for driving scrolls. The scroll itself
                // happens in onScrollGeometryChange (real layout signal,
                // no @State-mutation lag spiral).
                //
                // Disengage once the streaming row's measured height
                // reaches viewport height — by then the top of the
                // streaming message is at (or past) the top of the
                // viewport, which matches the spec's stop condition.
                // Setting autoFollow=false implements the "do nothing
                // else, ever" half of the contract.
                guard model.isStreaming, newHeight > 0 else { return }
                let buffer: CGFloat = 24
                let usableViewport = max(0, viewportHeight - buffer)
                if usableViewport > 0, newHeight >= usableViewport {
                    autoFollow = false
                }
            }
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .tracking, .interacting, .decelerating:
                    autoFollow = false
                case .idle, .animating:
                    break
                @unknown default:
                    break
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

}

/// Snapshot of the bits of `ScrollGeometry` the auto-follow handler
/// needs. Equatable + Sendable so `onScrollGeometryChange(for:_:action:)`
/// can deliver it through its diff machinery; we only re-fire the
/// action when one of these three values actually moves, not on
/// every layout pass.
private struct ScrollMetrics: Equatable, Sendable {
    var contentHeight: CGFloat
    var offset: CGFloat
    var viewportHeight: CGFloat
}

// MARK: - Decoupled scroll-content subviews
//
// These exist to keep streaming-chunk-rate state mutations out of the
// settled-history render path. Each subview reads only the observable
// properties it actually consumes — so `model.streamingText` updating
// 20-50× per second does NOT re-eval ChatHistoryArea's body and run
// ForEach over hundreds of messages.

/// Renders the settled message + compression-summary timeline. Observes
/// only `model.messages`; immune to streaming state churn.
private struct ChatHistoryArea: View {
    @Bindable var model: ConversationViewModel

    var body: some View {
        ForEach(model.messages) { msg in
            if msg.role == .compressionSummary {
                CompressionSummaryCard(message: msg, model: model)
                    .id(msg.id)
            } else {
                MessageRow(message: msg, model: model)
                    .id(msg.id)
            }
        }
    }
}

/// Optimistic user message rendered before the SendMessage RPC returns,
/// plus any messages queued offline waiting on the OutboundQueue
/// drain. Both render as user bubbles; queued ones get a small
/// clock chip so the user knows they're still waiting on the
/// server.
///
/// Observes `model.pendingUserText` AND the queue snapshot. When
/// the OutboundQueue drains, the entry slides into `messages`
/// via the normal SendMessage response path and disappears from
/// `queuedEntries` — same one-frame swap as `pendingUserText`.
private struct PendingUserArea: View {
    @Bindable var model: ConversationViewModel
    @State private var queuedTick: Int = 0

    var body: some View {
        Group {
            if let pending = model.pendingUserText {
                PendingUserRow(text: pending)
                    .id("__pending__")
            }
            ForEach(model.queuedEntries) { entry in
                QueuedUserRow(text: entry.content)
                    .id("__queued_\(entry.id)")
            }
        }
        // OutboundQueue posts a notification on every mutation;
        // bumping queuedTick re-evaluates `model.queuedEntries`
        // which the parent View hierarchy doesn't otherwise
        // observe (it's not @Observable property — it computes
        // through the queue).
        .onReceive(
            NotificationCenter.default.publisher(for: OutboundQueue.didChangeNotification)
        ) { _ in
            queuedTick &+= 1
        }
    }
}

/// Bubble for a message that's sitting in the offline queue,
/// waiting for the server to come back. Visually mirrors
/// `PendingUserRow` but with a small clock chip below the text
/// so the user can tell at a glance it hasn't gone out yet.
private struct QueuedUserRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 4) {
                Spacer()
                Image(systemName: "clock")
                    .font(.caption2)
                Text("Queued — will send when online")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.trailing, 4)
        }
    }
}

/// In-flight assistant turn. Observes the streaming-state cluster
/// (streamingText, isStreaming, isCompacting, …) so chunk mutations
/// re-render this subview and ONLY this subview.
private struct StreamingArea: View {
    @Bindable var model: ConversationViewModel
    @Binding var streamingRowHeight: CGFloat

    var body: some View {
        if !model.streamingText.isEmpty || model.isStreaming || model.isCompacting {
            StreamingRow(
                text: model.streamingText,
                thinkingText: model.streamingThinking,
                thinkingStartedAt: model.streamingThinkingStartedAt,
                thinkingFinishedAt: model.streamingThinkingFinishedAt,
                thinkingExpanded: $model.streamingThinkingExpanded,
                toolCalls: model.streamingToolCalls,
                isCompression: model.isCompacting
            )
            .id("__streaming__")
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                // Gate writes on actively streaming so an incidental
                // layout pass on the disappearing row doesn't fire a
                // state mutation that re-evals paneScrollBody for
                // nothing.
                guard model.isStreaming || model.isCompacting else { return }
                guard newHeight != streamingRowHeight else { return }
                streamingRowHeight = newHeight
            }
        }
    }
}
