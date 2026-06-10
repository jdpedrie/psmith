import SwiftUI
import ReeveKit
import ReeveUI
import os.log

/// Diagnostic logger for the auto-follow state machine. Notice-level
/// so entries survive into `log show` — these breadcrumbs exist
/// because the follow/park interactions are only observable on a live
/// stream and have burned multiple debugging rounds.
private let scrollLog = Logger(subsystem: "dev.jdpedrie.reeve", category: "ChatScroll")

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
            // Recreate the view model on every (re-)appearance — the
            // scroll machinery is built around a fresh cold-entry
            // settle per entry. A VM-reuse fast path for back-
            // navigation was tried (to dodge the settings-save race)
            // and regressed scrolling across the board; the race it
            // dodged is now fixed at the source — every settings
            // writer does a fresh read-modify-write against the live
            // row (see saveCallSettings / selectModel), so a stale
            // VM snapshot can no longer clobber anything.
            //
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
        let t = liveConversation.title ?? ""
        return t.isEmpty ? "Untitled" : t
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
    /// User-driven scrolling disengages follow — detected via
    /// `scrollPosition.isPositionedByUser` in the geometry handler
    /// (deliberately NOT scroll-phase or gesture based; see the
    /// comments in `paneScrollBody`).
    @State private var autoFollow = true
    /// Scroll handle for the explicit `scrollTo(edge: .bottom)` jumps
    /// (send, scroll-to-bottom pill). The continuous bottom-pin while
    /// streaming is NOT driven through this — it's delegated to
    /// `defaultScrollAnchor(.bottom, for: .sizeChanges)`, which pins
    /// inside the scroll view's own layout pass. See the comment on
    /// that modifier in `paneScrollBody` for why every hand-computed
    /// alternative overshot into blank space.
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

    /// Current scroll phase, tracked ONLY to time the past-bottom
    /// clamp (see the geometry handler). Never used to disengage
    /// auto-follow — phases fire for system motion too, which is the
    /// misread that caused the original stranding bug.
    @State private var scrollPhase: ScrollPhase = .idle

    /// Latest scroll offset, stored OUTSIDE SwiftUI invalidation (a
    /// reference-type box mutated from the geometry handler at tick
    /// rate without re-rendering anything). Read exactly once per
    /// park to freeze the viewport at its current offset.
    @State private var liveOffset = LiveOffsetBox()

    /// The message id the mid-stream park pinned at the viewport top.
    /// Used to RE-ASSERT the pin across the terminal reload — the
    /// content swap at stream end re-triggers the scroll position and
    /// yanked a parked viewport to the response bottom (simulator-
    /// verified: park held for 15s of streaming, then jumped at
    /// terminal). Cleared on any user scroll / new send.
    @State private var parkedMessageID: String?

    /// Arms the sent-message-top cutoff. The preference reporter
    /// emits garbage during the send-time relayout (logged minY=-458
    /// on the first frame of a stream, which parked follow at t=0),
    /// so the cutoff only honors a top-crossing after at least one
    /// sane on-screen reading (minY comfortably below the viewport
    /// top) has been observed for the current stream.
    @State private var cutoffArmed = false

    /// Which prefix of the history stays UNMOUNTED. This is the fix
    /// for the long-standing "cold entry into a long chat lands in
    /// blank space past the messages" bug. Root cause (device-
    /// confirmed): handing LazyVStack 200+ messages in one shot makes
    /// it realize rows from the TOP while the total content size stays
    /// estimated — all the estimate error accumulates at the BOTTOM as
    /// phantom blank space, and the bottom anchor seeks into it (the
    /// scrollbar showed ~5 screens of desert below the last message).
    /// A ~dozen-row tail realizes fully in one pass, so the content
    /// size is exact and the anchor lands on the real last message.
    ///
    /// CRITICAL INVARIANT — the mounted set only ever changes by
    /// EXPLICIT USER ACTION (the "Show earlier" capsule). The previous
    /// design cycled the window automatically: re-trim to the newest
    /// 12 on every send, silently re-expand at terminal / pill-tap /
    /// a 500ms timer. Every transition was a structural relayout of
    /// hundreds of rows, and each one had a way to glitch — sends
    /// visibly unloaded the history above, terminal expansion
    /// re-introduced estimate inflation and stranded the viewport
    /// below the conversation, and the whole layout could lurch
    /// during the swap (all user-reported on device). The boundary
    /// freezes once per entry instead:
    ///
    ///   .settling     — initial load in flight; mount the newest 12.
    ///   .cutoff(id)   — boundary frozen at the message that was 12th-
    ///                   from-last when the load finished. New
    ///                   messages append BELOW the boundary, so
    ///                   nothing ever unloads; the hidden prefix never
    ///                   regrows.
    ///   .full         — user tapped "Show earlier" (or the chain was
    ///                   short to begin with).
    @State private var historyMount: HistoryMount = .settling

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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            // Let the message wrap to its natural height. The
            // earlier `.lineLimit(2)` ellipsized server errors like
            // "model X lacks capabilities required by this profile's
            // plugin pipeline" right at the noun the user needs to
            // see. fixedSize forces the Text to take its full
            // intrinsic vertical size against the HStack layout
            // pressure from Dismiss on the right.
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // While the tail window is active and hides older
                    // messages, surface an explicit reveal control at
                    // the top of the visible history. Deliberately
                    // user-initiated rather than an automatic
                    // scroll-position-preserving backfill: the timed
                    // backfill used to race the user's first touch,
                    // and its preserve-seek resolved through hundreds
                    // of unrealized rows' estimates — landing
                    // half-a-conversation away with no discernible
                    // pattern (the on-device "jumps far up" reports).
                    if hiddenHistoryCount > 0 {
                        ShowEarlierRow(count: hiddenHistoryCount) {
                            revealEarlierHistory()
                        }
                    }
                    // Settled history is its own subview that observes
                    // only `model.messages`. Without this split, every
                    // streaming chunk (which mutates streamingText on the
                    // shared @Observable model) would re-eval the entire
                    // LazyVStack content closure — running ForEach over
                    // N messages and constructing N MessageRow values
                    // per chunk, even though none of them changed.
                    ChatHistoryArea(model: model, mount: historyMount)
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
                // NOTE: no DragGesture here for user-scroll detection.
                // A simultaneous DragGesture on the scroll content
                // blocks ScrollView's pan entirely on iOS 26 (verified
                // in the simulator: neither finger drags nor scroll
                // wheel moved the content). User-scroll detection
                // lives in onScrollGeometryChange below, keyed off
                // `scrollPosition.isPositionedByUser`.
                //
                // scrollTargetLayout exposes row identities so the
                // park's `scrollTo(id:anchor:)` can pin the sent
                // message at the viewport top (see disengageFollow).
                .scrollTargetLayout()
            }
            .scrollPosition($scrollPosition)
            // Auto-follow is delegated to the SYSTEM bottom anchor, not
            // hand-computed scrollTo(point:) math. Every prior attempt
            // (sentinel anchors, delta scrolls, "real geometry" pins)
            // overshot into blank space for the same root reason:
            // LazyVStack's contentSize is an ESTIMATE while rows above
            // the viewport are unrealised, so any target computed from
            // it can land past the real content end. Worse, the
            // overshoot's clamp-back bounce reported as `.decelerating`
            // to onScrollPhaseChange, which read it as a user drag and
            // killed autoFollow — stranding the viewport in the blank
            // band below the last message.
            //
            // `defaultScrollAnchor(.bottom, for: .sizeChanges)` pins
            // the bottom edge from INSIDE the scroll view's layout
            // pass, after row realisation, so there is no estimate to
            // overshoot and no programmatic scroll for the phase
            // handler to misread. Passing nil detaches the anchor when
            // follow is disengaged (user dragged, or the streaming
            // bubble outgrew the viewport).
            // ONLY the role-specific sizeChanges anchor — deliberately
            // no all-roles `defaultScrollAnchor(.bottom)`. The
            // all-roles variant covers sizeChanges too, and its
            // composition with the conditional override below is
            // ambiguous: logging showed the view still bottom-pinning
            // after the override flipped to nil. Initial placement
            // comes from the onAppear edge seek below instead (the
            // sizeChanges anchor does NOT cover the empty→loaded
            // transition — verified: cold entry landed at the top
            // without it).
            .defaultScrollAnchor(autoFollow ? .bottom : nil, for: .sizeChanges)
            .onAppear {
                // Sticky bottom-edge position for cold entry: holds
                // the bottom through load + tail-window settle +
                // backfill. The stickiness is exactly the follow
                // behavior we want while autoFollow is true; it is
                // explicitly broken at park (disengageFollow resets
                // the binding) and replaced by any user drag.
                scrollPosition.scrollTo(edge: .bottom)
            }
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    offset: geometry.contentOffset.y,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { _, m in
                liveOffset.y = m.offset
                let bottomEdge = m.offset + m.viewportHeight
                let distance = m.contentHeight - bottomEdge

                // Past-bottom clamp: when the viewport extends BELOW
                // the content bottom while follow is engaged, re-pin.
                // This is the keyboard-dismissal-on-submit case: the
                // send path scrolls to the keyboard-up bottom, then
                // the keyboard dismisses and the viewport grows ~300pt
                // — parking the offset past the content end with an
                // empty band below the last message. The sizeChanges
                // anchor doesn't cover it because the CONTAINER grew,
                // not the content. Guards: `.idle` so we don't stutter
                // the send path's own scroll animation mid-flight, and
                // `!isPositionedByUser` so a user's at-bottom rubber-
                // band (also briefly negative) is never fought.
                if autoFollow, distance < -1,
                   scrollPhase == .idle,
                   !scrollPosition.isPositionedByUser {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                    return
                }

                // Disengage follow ONLY for user-driven motion.
                // `ScrollPosition.isPositionedByUser` tracks position
                // provenance: true after a finger drag, false after
                // programmatic scrolls and the system anchor's own
                // repositioning. Every signal we tried before
                // misattributed system motion to the user —
                // onScrollPhaseChange reports .tracking/.decelerating
                // for clamp-back bounces during cold-entry settle of a
                // long chat (verified in the sim with no touch input),
                // and a simultaneous DragGesture blocks ScrollView's
                // pan outright. The small distance floor keeps
                // at-bottom overscroll rubber-banding from counting as
                // "scrolled away."
                if autoFollow, scrollPosition.isPositionedByUser, distance > 4 {
                    autoFollow = false
                }

                // Release the mid-stream park the moment the user
                // takes over. The id-pin is STICKY — the scroll view
                // re-applies it on every arriving chunk, which
                // snapped the viewport back against the user's drag
                // (verified: repeated drags barely moved while a
                // stream was parked). Replacing the binding while the
                // user's gesture owns the viewport breaks the pin
                // without the at-rest one-viewport rewind.
                if parkedMessageID != nil, scrollPosition.isPositionedByUser {
                    parkedMessageID = nil
                    scrollPosition = ScrollPosition()
                }

                // Pill visibility — only meaningful once follow is off
                // (while anchored, distance hovers near zero).
                guard !autoFollow else { return }
                let newFar = distance > scrollToBottomThreshold
                if newFar != isFarFromBottom {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isFarFromBottom = newFar
                    }
                }
            }
            // Pill is always-rendered with opacity, not conditional view
            // insertion, so SwiftUI doesn't tear down and rebuild the
            // overlay subtree per state change. Hit testing is gated so
            // a hidden pill can't intercept taps. Anchored at the
            // BOTTOM (just above the composer) — it used to share the
            // top with the "Show earlier" capsule and covered it
            // whenever the user scrolled to the top of the mounted
            // history.
            .overlay(alignment: .bottom) {
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
                .padding(.bottom, 10)
                .opacity(isFarFromBottom && !autoFollow ? 1 : 0)
                .allowsHitTesting(isFarFromBottom && !autoFollow)
                .animation(.easeInOut(duration: 0.22), value: isFarFromBottom)
                .accessibilityLabel("Scroll to bottom of conversation")
                .accessibilityHidden(!isFarFromBottom)
            }
            // Initial position comes from `defaultScrollAnchor(.bottom)`
            // above — no onAppear scrollTo needed. The anchor applies
            // during the first layout pass, so there's no
            // empty-then-jump flash while load() populates messages.
            //
            // Intentionally NOT scrolling on `model.messages.count` —
            // that handler used to fire on stream end (streaming row
            // → settled assistant message bumps count by 1) and on
            // deletes, both of which jerked the viewport. Stream end
            // and delete now hold the user's current scroll position.
            .onChange(of: model.pendingUserText) { _, text in
                if text != nil {
                    autoFollow = true
                    streamingRowHeight = 0
                    cutoffArmed = false
                    parkedMessageID = nil
                    // Bottom seek only — the mounted set is NOT
                    // touched. The old design re-trimmed to the
                    // newest 12 here, which visibly unloaded every
                    // row above (user-reported as "unloading messages
                    // at the top") and queued up a re-expansion later
                    // that re-introduced the phantom desert. The seek
                    // stays exact without the trim because the
                    // mounted set is the frozen tail + this session's
                    // turns — rows that have all been realized, so
                    // the content size below the viewport is real,
                    // not estimated. (The hidden prefix above never
                    // mounts and can't contribute estimate error to
                    // the bottom edge.)
                    //
                    // Non-animated deliberately: the animated variant
                    // captured a target offset that the concurrent
                    // keyboard/content changes invalidated mid-flight.
                    // The pending bubble's insertion provides its own
                    // motion; the seek itself should be exact.
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
            .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                if !wasStreaming && isStreaming {
                    autoFollow = true
                    streamingRowHeight = 0
                } else if wasStreaming && !isStreaming {
                    // Terminal edge: reset the streaming-row
                    // bookkeeping and NOTHING ELSE about the layout.
                    // The mounted set stays exactly as it was — the
                    // old design expanded the history window here,
                    // which mounted hundreds of estimated rows in one
                    // structural relayout, and the sticky bottom edge
                    // solved into the resulting phantom space below
                    // the conversation on every stream close (user-
                    // reported, consistent). With the boundary frozen
                    // there is no relayout at terminal at all: the
                    // streaming row settles into a real message row of
                    // the same content and the viewport doesn't move.
                    // When we followed to the end, the sticky bottom
                    // edge holds the viewport through the terminal
                    // reload on its own. (Replacing the binding here
                    // would rewind a viewport; see disengageFollow.)
                    streamingRowHeight = 0
                    if !autoFollow, let parkedID = parkedMessageID {
                        // Parked mid-response: the terminal content
                        // swap re-fires the scroll position and yanks
                        // the viewport to the bottom. Re-assert the
                        // pin now and once more after the reload
                        // settles.
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            scrollPosition.scrollTo(id: parkedID, anchor: .top)
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !autoFollow, parkedMessageID == parkedID else { return }
                            var t2 = Transaction()
                            t2.disablesAnimations = true
                            withTransaction(t2) {
                                scrollPosition.scrollTo(id: parkedID, anchor: .top)
                            }
                        }
                    }
                }
            }
            // Primary streaming stop condition: follow the growing
            // response until the just-sent USER message reaches the
            // top of the viewport, then park — the question stays
            // visible while the answer keeps writing below (the pill
            // appears once the bottom runs away). The preference is
            // emitted only while a streaming turn is active, by the
            // last (user) row in ChatHistoryArea; minY is in the
            // scroll view's visible space, so <= threshold means the
            // row's top is at/above the viewport top.
            .onPreferenceChange(SentMessageTopPreferenceKey.self) { minY in
                guard let minY else { return }
                Task { @MainActor in
                    guard model.isStreaming else { return }
                    if !cutoffArmed {
                        // Arm only on a sane reading: the row top
                        // visibly below the viewport top. Filters the
                        // relayout garbage at stream start.
                        if minY > 60 {
                            cutoffArmed = true
                            scrollLog.notice("cutoff armed (minY=\(Int(minY)))")
                        }
                        return
                    }
                    guard autoFollow, minY <= 8 else { return }
                    scrollLog.notice("park: sent message reached top (minY=\(Int(minY)))")
                    disengageFollow()
                }
            }
            .onChange(of: streamingRowHeight) { _, newHeight in
                // Backstop stop condition: the streaming row alone
                // outgrew the viewport. Normally the sent-message-top
                // preference (above) fires first — this covers turns
                // where the preference can't (forked sends where the
                // last row isn't the watched user message, a row that
                // dematerialized, etc.). streamingRowHeight is used
                // only for this check, not for driving scrolls — the
                // bottom pin is the system anchor's job.
                guard model.isStreaming, newHeight > 0 else { return }
                let buffer: CGFloat = 24
                let usableViewport = max(0, viewportHeight - buffer)
                if usableViewport > 0, newHeight >= usableViewport, autoFollow {
                    scrollLog.notice("park: streaming row outgrew viewport (h=\(Int(newHeight)))")
                    disengageFollow()
                }
            }
            // Phase TRACKING only — deliberately no disengage here.
            // Verified in the simulator that the system fires
            // .tracking/.decelerating during cold-entry settle of a
            // long chat with NO touch input — any phase-based
            // disengage misreads that as a user drag and strands the
            // viewport mid-realization. The phase feeds the
            // past-bottom clamp's "don't stutter an in-flight
            // animation" guard in the geometry handler.
            .onScrollPhaseChange { _, newPhase in
                scrollPhase = newPhase
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                // Freeze the mount boundary once the initial load
                // lands. This is pure bookkeeping — the mounted set is
                // IDENTICAL before and after (the newest 12 either
                // way), so nothing relayouts; it just switches the
                // semantics from "newest 12 by count" (which would
                // slide as new messages append, unloading old rows) to
                // "everything after this fixed message". No timed
                // full-history backfill follows — that silent
                // expansion was the source of the stream-close /
                // post-settle phantom desert.
                while model.loading {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard case .settling = historyMount else { return }
                let msgs = model.messages
                if msgs.count > 12 {
                    historyMount = .cutoff(id: msgs[msgs.count - 12].id)
                } else {
                    historyMount = .full
                }
            }
    }

    /// Stop following the stream and PARK the viewport where it is.
    /// Four simulator-verified traps shape this:
    ///
    ///   1. Flipping `autoFollow` alone is not enough — the send
    ///      path's `scrollTo(edge: .bottom)` leaves ScrollPosition
    ///      holding a STICKY edge position that the scroll view keeps
    ///      re-honoring on every content change, so the view chased
    ///      the stream all the way to terminal.
    ///   2. Replacing the binding with an empty ScrollPosition() to
    ///      break the stickiness REWINDS the offset by exactly one
    ///      viewport (logged park at minY=-4, frame showed the
    ///      previous screenful).
    ///   3. An offset park is only stable when the mounted history is
    ///      SMALL: with the full chain mounted, LazyVStack's estimate
    ///      churn for the unrealized mass above slid the parked
    ///      viewport a full screen off.
    ///   4. `scrollTo(id:anchor:)` is no better — it solves the
    ///      target position from those same estimates and landed a
    ///      screen above the row.
    ///
    /// So: overwrite the sticky edge with an ID-pin on the sent
    /// message, anchored at the viewport top — which is also exactly
    /// the desired UX (the question stays put while the answer keeps
    /// writing below). Trap (4) doesn't apply here because the
    /// mounted set (frozen entry tail + this session's turns) is all
    /// realized rows, so the id solve is exact; an explicit
    /// point-park was tried too and `scrollTo(point:)` landed a
    /// viewport off (its point is not a raw content offset).
    private func disengageFollow() {
        autoFollow = false
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if let last = model.messages.last, last.role == .user {
                parkedMessageID = last.id
                scrollPosition.scrollTo(id: last.id, anchor: .top)
            } else {
                // Compaction / no watched row: freeze at the current
                // offset as a best effort.
                scrollPosition.scrollTo(point: CGPoint(x: 0, y: liveOffset.y))
            }
        }
        // Second pass: the first scrollTo(id:) solves against row
        // ESTIMATES when tall rows in the window aren't realized and
        // can land up to a screen off; by the time this fires, the
        // first pass has realized the target's neighborhood and the
        // re-solve is exact. (Same two-pass trick as the terminal
        // re-assert.)
        if let parkedID = parkedMessageID {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !autoFollow, parkedMessageID == parkedID else { return }
                var t2 = Transaction()
                t2.disablesAnimations = true
                withTransaction(t2) {
                    scrollPosition.scrollTo(id: parkedID, anchor: .top)
                }
            }
        }
    }

    /// Number of older messages currently hidden above the mount
    /// boundary.
    private var hiddenHistoryCount: Int {
        switch historyMount {
        case .full:
            return 0
        case .settling:
            return max(0, model.messages.count - 12)
        case .cutoff(let id):
            return model.messages.firstIndex(where: { $0.id == id }) ?? 0
        }
    }

    /// User-initiated reveal of the hidden history prefix (the
    /// "Show earlier messages" capsule) — the ONLY path that mounts
    /// more rows. Expands to the full chain and re-pins the viewport
    /// to the message that was previously first — the two-pass
    /// id-seek can still land imperfectly over the freshly-prepended
    /// estimates, but because the user explicitly asked for the
    /// expansion, an imperfect landing reads as "the list moved to
    /// older messages", not as a random mid-read jump.
    private func revealEarlierHistory() {
        let anchorID: String?
        switch historyMount {
        case .full:
            return
        case .settling:
            anchorID = model.messages.suffix(12).first?.id
        case .cutoff(let id):
            anchorID = id
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            historyMount = .full
            if let anchorID {
                scrollPosition.scrollTo(id: anchorID, anchor: .top)
            }
        }
        if let anchorID {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard historyMount == .full else { return }
                var t2 = Transaction()
                t2.disablesAnimations = true
                withTransaction(t2) {
                    scrollPosition.scrollTo(id: anchorID, anchor: .top)
                }
            }
        }
    }

}

/// Mount state for the conversation history — see `historyMount`.
enum HistoryMount: Equatable {
    /// Initial load in flight; mount the newest 12 by count.
    case settling
    /// Boundary frozen: mount `id` and everything after it. New
    /// messages append below the boundary; the hidden prefix never
    /// regrows.
    case cutoff(id: String)
    /// Everything mounted (explicit reveal, or a short chain).
    case full
}

/// Reference-type holder for the live scroll offset. Mutated from the
/// geometry handler every tick WITHOUT invalidating any view (it's a
/// class held in @State — stable identity, field writes are invisible
/// to SwiftUI). Read once per park.
final class LiveOffsetBox {
    var y: CGFloat = 0
}

/// Inline control at the top of the windowed history that reveals the
/// older messages. Mirrors the scroll-to-bottom pill's chrome so the
/// two affordances read as a pair.
private struct ShowEarlierRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.semibold))
                    Text("Show \(count) earlier message\(count == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(count) earlier messages")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Snapshot of the bits of `ScrollGeometry` the scroll-to-bottom-pill
/// handler needs. Equatable + Sendable so
/// `onScrollGeometryChange(for:_:action:)` can deliver it through its
/// diff machinery; we only re-fire the action when one of these three
/// values actually moves, not on every layout pass.
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

/// Reports the just-sent user message's top edge in the scroll view's
/// visible coordinate space while a response streams. ConversationBody
/// watches this to stop auto-follow the moment the sent message
/// reaches the viewport top — so the user's question stays on screen
/// while the answer keeps writing below.
///
/// A preference (not a callback prop on ChatHistoryArea) so the
/// history subview's stored properties stay equatable — a closure
/// prop would defeat SwiftUI's body-skip and re-run the 500-message
/// ForEach on every chunk-rate parent re-eval.
struct SentMessageTopPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// Renders the settled message + compression-summary timeline. Observes
/// only `model.messages` (plus the rare isStreaming flip for the
/// follow-cutoff reporter); immune to streaming-text churn.
///
/// `mount` limits rendering to the tail after the frozen boundary
/// (see `historyMount` on ConversationBody). Message ids are stable,
/// so the cutoff→full transition is a pure prepend in ForEach's diff.
private struct ChatHistoryArea: View {
    @Bindable var model: ConversationViewModel
    let mount: HistoryMount

    private var visibleMessages: [ReeveMessage] {
        switch mount {
        case .full:
            return model.messages
        case .settling:
            return Array(model.messages.suffix(12))
        case .cutoff(let id):
            // Boundary message deleted (edit/fork/compaction) →
            // fall back to the full chain rather than hiding
            // everything.
            guard let idx = model.messages.firstIndex(where: { $0.id == id }) else {
                return model.messages
            }
            return Array(model.messages[idx...])
        }
    }

    /// The message whose top edge gates auto-follow: the just-sent
    /// user message, which is the LAST row in the chain for the
    /// whole duration of a streaming turn (the assistant row only
    /// materializes at terminal). nil outside streaming — the
    /// geometry reporter detaches entirely.
    private var followCutoffMessageID: String? {
        guard model.isStreaming, !model.isCompacting,
              let last = model.messages.last, last.role == .user
        else { return nil }
        return last.id
    }

    var body: some View {
        let cutoffID = followCutoffMessageID
        ForEach(visibleMessages) { msg in
            if msg.role == .compressionSummary {
                CompressionSummaryCard(message: msg, model: model)
                    .id(msg.id)
            } else {
                MessageRow(message: msg, model: model)
                    .id(msg.id)
                    .background {
                        if msg.id == cutoffID {
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: SentMessageTopPreferenceKey.self,
                                    value: g.frame(in: .scrollView).minY
                                )
                            }
                        }
                    }
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
                toolCallExpansionBinding: { call in
                    Binding(
                        get: { model.expandedLiveToolCallIDs.contains(call.id) },
                        set: { newValue in
                            if newValue {
                                model.expandedLiveToolCallIDs.insert(call.id)
                            } else {
                                model.expandedLiveToolCallIDs.remove(call.id)
                            }
                        }
                    )
                },
                isCompression: model.isCompacting,
                streamingComponents: model.conversation.streamingComponents
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
