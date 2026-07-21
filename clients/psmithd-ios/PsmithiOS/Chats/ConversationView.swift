import SwiftUI
import PsmithKit
import PsmithUI
import QuartzCore
import os.log

/// Diagnostic logger for the auto-follow state machine. Notice-level
/// so entries survive into `log show` — these breadcrumbs exist
/// because the follow/park interactions are only observable on a live
/// stream and have burned multiple debugging rounds.
private let scrollLog = Logger(subsystem: "dev.jdpedrie.psmith", category: "ChatScroll")

/// iOS conversation surface. Constructs `ConversationViewModel` against
/// the live `psmithd`, then renders the status strip + message scroll.
/// Per `docs/clients/ios-reference.md`: composer arrives in Phase 5d, the
/// page-replace alternates (Compact / Contexts / Settings / Model
/// Picker) become push/sheet destinations in Phase 5g.
struct ConversationView: View {
    let conversation: PsmithConversation
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
        // Edge-only back swipe while the conversation is up — the
        // iOS 26 swipe-anywhere pop fires on rightward transcript
        // drags (see BackSwipeLimiter).
        .background(BackSwipeLimiter())
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
            // Per `docs/clients/ios-reference.md`: cancel the live
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
                // Reconcile anything mutated from another client
                // while this device was suspended (account events
                // don't replay). Cheap: one GetConversation unless
                // something actually moved.
                Task { await m.refreshIfStale() }
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
            m.speechPlayer = app.speech
            // Cache-first entry: cached transcript renders this frame;
            // the network load replaces it (and the inverted list's
            // rest edge makes the swap invisible at the bottom).
            await m.hydrateFromCache()
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
    private var liveConversation: PsmithConversation {
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
    let liveConversation: PsmithConversation
    @Environment(AppModel.self) private var app

    // THE INVERTED TRANSCRIPT. The scroll view renders through
    // scaleEffect(y: -1) with each row flipped back and the message
    // array iterated newest-first, so the newest message sits at
    // content offset 0. Zero is not an estimate: every failure class
    // this view has a history of — entry seeks landing in phantom
    // space, the pill parking blank after a long jump, past-bottom
    // clamps chasing a flapping content estimate at 100% CPU — came
    // from solving positions against the estimated FAR end of a
    // LazyVStack. Inverted, the interesting edge is the exact end;
    // estimate error still exists but lives entirely in the
    // old-history direction, where nothing ever solves against it
    // and a wrong guess only miscalibrates the scrollbar.
    //
    // What this deletes: the cold-entry tail window + staged
    // backfill + entry curtain + settle failsafes, the pill
    // convergence loop + governor, the past-bottom clamp, and the
    // measured send-pin jump. What stays: the width pins (horizontal
    // containment is orthogonal to flip direction), the Equatable
    // subview gates (ForEach diff cost is real at 447 rows), the
    // markdown prewarm + budget, and the send runway (content
    // constant under a shrinking spacer), now with near-origin
    // EXACT coordinates instead of estimated ones.
    //
    // There is still NO auto-follow. A send pins the just-sent
    // question at the viewport top and the reply streams in below
    // with the viewport motionless.
    //
    /// Scroll handle for the explicit seeks (send pin, pill).
    @State private var scrollPosition = ScrollPosition()
    /// Programmatic push into the contexts list — the Contexts entry
    /// lives in the toolbar menu now, and Menus don't host
    /// NavigationLinks reliably.
    @State private var showingContexts = false

    /// Latest scroll metrics, readable OUTSIDE the geometry handler.
    /// A reference-type box deliberately: writing it per tick must not
    /// invalidate any view body (an @State struct write would — that
    /// per-tick invalidation was the amplification engine behind the
    /// pre-inversion 100%-CPU storms). Kept as the debugging window
    /// into the live metrics even though no steady-state actor reads
    /// it anymore.
    private final class ScrollMetricsBox {
        var latest = ScrollMetrics(
            contentHeight: 0, offset: 0, viewportHeight: 0,
            contentWidth: 0, viewportWidth: 0, offsetX: 0
        )
    }
    @State private var metricsBox = ScrollMetricsBox()

    /// Viewport height of the message scroll, measured via
    /// `onGeometryChange`.
    @State private var viewportHeight: CGFloat = 0
    /// The scroll pane's TOP safe-area inset (nav-bar clearance),
    /// re-applied as a content-space BOTTOM margin so it renders at
    /// the visual top through the flip.
    @State private var navClearance: CGFloat = 0
    /// Width of the message pane, measured via `onGeometryChange` and
    /// injected as `chatPaneWidth` for bubble width caps. Measured
    /// WITHOUT wrapping the ScrollView in a layout-owning
    /// GeometryReader — that wrapper made the scroll content lose its
    /// horizontal padding (content slammed to the screen edges) the
    /// instant the keyboard appeared or a send fired, snapping back
    /// only on the next interaction. `onGeometryChange` measures the
    /// view in place, so the ScrollView keeps normal keyboard
    /// avoidance + insets.
    @State private var paneWidth: CGFloat = 0
    /// True when the scroll position is more than `scrollToBottomThreshold`
    /// points away from the bottom of the message list. Drives the
    /// "Scroll to bottom" pill that slides down from below the status
    /// strip; tapping it returns the user to the latest message.
    /// Inverted, "distance from bottom" is simply the offset.
    @State private var isFarFromBottom: Bool = false

    /// Distance (pt) from the bottom that flips the "scroll to bottom"
    /// affordance on. Roughly one bubble-height of slack so the pill
    /// doesn't pop the moment the user reads past the last message.
    private let scrollToBottomThreshold: CGFloat = 200

    /// The scroll-content unit's global minX, from the layer probe.
    /// Regression telemetry for the horizontal-displacement bug class
    /// (the scroll offset's x reads 0 while the content draws
    /// displaced — the probes disagree by design; pixels follow the
    /// content unit).
    @State private var contentUnitMinX: CGFloat = 0


    // THE SEND PIN, fifth design (inverted, rest-edge). The lesson
    // that killed the fourth (held id-anchor) design in one live
    // test: ANY nonzero held offset is garbage during a structural
    // re-estimate — inserting the runway rows at the head made
    // LazyVStack re-map ±40k pt of estimates under a frozen offset
    // and the viewport landed mid-history for the whole stream (the
    // held id never re-solved). The only position that is exact by
    // construction through every collapse is the REST EDGE: offset
    // ~0 always shows the first viewport of content, realized by
    // definition.
    //
    // So the pin never scrolls. At send the runway spacer makes
    // (spacer + reply + question) fill exactly one viewport, and the
    // rest-edge frame IS "question at the top, runway below". While
    // the reply fits the runway, the shrinking spacer keeps content
    // constant — motionless. When it outgrows the runway, the
    // streaming row is CLIPPED to the runway height showing the
    // reply's beginning (the pre-inversion design kept the tail
    // below the fold; this keeps it behind the clip) — content
    // stays constant for the entire stream, zero scroll commands.
    // At terminal the full reply lands and ONE id-solve puts the
    // question back at the viewport top (for short replies it
    // clamps to the rest edge — the same frame).

    /// Runway budget, fixed at send. The rendered spacer is
    /// budget − (measured streaming height), so question + reply +
    /// spacer stays CONSTANT while the reply grows. In the flipped
    /// stack the spacer sits FIRST (nearest offset 0): its shrink
    /// exactly cancels the stream's growth at the origin. Nonzero =
    /// send pin live; zeroed at terminal, by the pill, and on send
    /// failure.
    @State private var streamRunwayBudget: CGFloat = 0
    /// The runway's rendered height (derived, see above).
    @State private var streamSpacerHeight: CGFloat = 0
    /// True while the ScrollPosition binding holds a one-shot
    /// programmatic position (send catch-up, terminal solve, pill).
    /// Released (binding replaced) on user grab and by each solve's
    /// own settle task — a held position is STICKY and re-applies
    /// against a user's drag otherwise.
    @State private var positionHeld = false

    var body: some View {
        VStack(spacing: 0) {
            if let err = model.loadError, !model.messages.isEmpty {
                loadErrorBanner(err)
            }
            if let speechErr = app.speech.playbackError {
                speechErrorBanner(speechErr)
            }
            messageScroll
            if let archivedAt = liveConversation.archivedAt {
                archivedBar(archivedAt)
            } else if let pending = model.pendingCompressionSummary {
                // A pending summary limits the conversation (the server
                // refuses sends and compacts until it's resolved) — the
                // composer gives way to the review verdict.
                CompressionReviewBar(message: pending, model: model)
            } else {
                Composer(model: model)
            }
        }
        .onChange(of: model.messages.count) { old, new in
            // Pre-warm parsed markdown for any newly-added messages
            // (terminal reloads, fork switches, manual refresh). Cache
            // already-present entries skip — only the new assistant
            // turn(s) pay the parse cost, and that happens off the
            // main thread. Keys MUST match MessageRow's render key.
            MarkdownCache.shared.prewarm(
                model.messages.map {
                    let body = $0.displayContent ?? $0.content
                    return (key: MessageRow.markdownKey(id: $0.id, body: body), source: body)
                }
            )
            // No shrink-settle needed inverted: a delete near the
            // newest edge shrinks content at/above the origin-side
            // viewport and UIKit's native offset clamp covers it —
            // there is no far-end estimate to strand the viewport
            // against.
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConversationMenu(model: model, showingContexts: $showingContexts)
            }
        }
        .navigationDestination(isPresented: $showingContexts) {
            ContextListView(model: model)
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

    private func speechErrorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "speaker.slash.fill")
                .foregroundStyle(.orange)
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") { app.speech.clearError() }
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
            paneScrollBody
                .environment(\.chatPaneWidth, paneWidth)
                .onGeometryChange(for: [CGFloat].self) { proxy in
                    [proxy.size.width, proxy.size.height, proxy.safeAreaInsets.top]
                } action: { v in
                    paneWidth = v[0]
                    viewportHeight = v[1]
                    navClearance = v[2]
                }
                // Hand-rolled under-the-bar fade, drawn in SCREEN
                // space where no transform can misplace it. The
                // system scroll-edge fade is hidden on this scroll
                // (its extent math breaks on inverted scroll views —
                // FB20540755) and iOS 26 glass bars ignore
                // toolbarBackground, so without this the title text
                // sat directly on passing transcript content.
                .overlay(alignment: .top) {
                    LinearGradient(
                        stops: [
                            .init(color: Color(.systemBackground), location: 0),
                            .init(color: Color(.systemBackground).opacity(0.85), location: 0.55),
                            .init(color: Color(.systemBackground).opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: navClearance + 28)
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
                // LazyVStack laziness now works WITH the design: initial
                // render realizes rows outward from offset 0 (the
                // newest), and older rows realize on scroll — no mount
                // window, no staged backfill, no entry curtain.
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Scroll runway for the send pin, FIRST (nearest
                    // the origin = visual bottom). Clear color, not
                    // Spacer(): LazyVStack gives Spacer no height.
                    // Width pinned EXACTLY like every message row: an
                    // unpinned child accepts a transition pass's loose
                    // (oversized) width proposal, and since the runway
                    // re-lays on every streaming flush, that turned
                    // into a ±16pt horizontal shimmy at flush cadence
                    // (probe-verified: minX −16→0 at ~3Hz all stream).
                    if streamSpacerHeight > 0 {
                        Color.clear
                            .frame(
                                width: paneWidth > 32 ? paneWidth - 32 : nil,
                                height: streamSpacerHeight
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("__streamspacer__")
                    }
                    StreamingArea(model: model)
                        // The runway shrinks by exactly the streaming
                        // row's measured growth — measured, not
                        // estimated, so question+reply+spacer stays
                        // an honest constant.
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { h in
                            guard streamRunwayBudget > 0 else { return }
                            streamSpacerHeight = max(0, streamRunwayBudget - h)
                        }
                        // Clip to the runway once the reply outgrows
                        // it: alignment .bottom in content space keeps
                        // the row's content-space bottom — which the
                        // flips render as the reply's FIRST lines —
                        // visible, with the growing tail behind the
                        // clip. Content contribution is capped at the
                        // budget, so the stream can never move the
                        // rest-edge frame. The full body lands at the
                        // terminal swap.
                        .frame(
                            maxHeight: streamRunwayBudget > 0 ? streamRunwayBudget : nil,
                            alignment: .bottom
                        )
                        .clipped()
                    // Pending user is its own subview so it observes
                    // only pendingUserText, not the chunk-rate
                    // streaming state.
                    PendingUserArea(model: model)
                        .equatable()
                    // Settled history is its own subview that observes
                    // only `model.messages`. Without this split, every
                    // streaming chunk (which mutates streamingText on the
                    // shared @Observable model) would re-eval the entire
                    // LazyVStack content closure — running ForEach over
                    // N messages and constructing N MessageRow values
                    // per chunk, even though none of them changed.
                    ChatHistoryArea(model: model)
                        .equatable()
                }
                .padding()
                // Short conversations read from the visual top like
                // any chat: pushing the (flipped) stack to the FAR end
                // of a viewport-height minimum puts the rows at the
                // visual top with the blank space by the composer.
                .frame(
                    minHeight: viewportHeight > 0 ? viewportHeight : nil,
                    alignment: .bottom
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
            .contentMargins(.top, 8, for: .scrollContent)
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

                // Pill visibility. The runway is blank space, not
                // content — subtract it or the pill lights on every
                // send before anything is below the fold.
                let newFar = (m.offset - streamSpacerHeight) > scrollToBottomThreshold
                if newFar != isFarFromBottom {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isFarFromBottom = newFar
                    }
                }
            }
            // Pill is always-rendered with opacity, not conditional view
            // insertion, so SwiftUI doesn't tear down and rebuild the
            // overlay subtree per state change. Hit testing is gated so
            // a hidden pill can't intercept taps. Anchored at the TOP
            // (user preference — it floats over the parked message
            // when one is pinned there, and that's the accepted
            // trade).
            .overlay(alignment: .top) {
                Button {
                    Haptics.impact(.light)
                    // Inverted, "bottom" is offset 0 — one exact
                    // absolute scroll, no convergence, no estimates.
                    // An explicit bottom-seek ends the pin contract:
                    // reclaim the runway so "bottom" means the real
                    // content end, not the blank band.
                    streamRunwayBudget = 0
                    streamSpacerHeight = 0
                    oneShotScroll(y: 0, reason: "pill")
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
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .opacity(isFarFromBottom ? 1 : 0)
                .allowsHitTesting(isFarFromBottom)
                .animation(.easeInOut(duration: 0.22), value: isFarFromBottom)
                .accessibilityLabel("Scroll to bottom of conversation")
                .accessibilityHidden(!isFarFromBottom)
            }
            // Intentionally NOT scrolling on `model.messages.count` —
            // that handler used to fire on stream end (streaming row
            // → settled assistant message bumps count by 1) and on
            // deletes, both of which jerked the viewport. Stream end
            // and delete hold the user's current scroll position.
            .onChange(of: model.pendingUserText) { _, text in
                if text != nil {
                    // Send: lay the runway. The rest-edge frame then
                    // IS the pin (see the design comment on
                    // streamRunwayBudget) — no scroll command unless
                    // the user had scrolled away, in which case one
                    // exact catch-up to the rest edge.
                    scrollLog.notice("send: runway laid")
                    streamRunwayBudget = max(240, viewportHeight)
                    streamSpacerHeight = streamRunwayBudget
                    if metricsBox.latest.offset > 64 {
                        oneShotScroll(y: 0, reason: "send catch-up")
                    }
                } else if model.sending || model.isStreaming {
                    // Pending sentinel swapped for the real user row —
                    // a pure equal-height row swap at the head; the
                    // rest-edge frame doesn't move. Nothing to do.
                } else {
                    // Send failed before a run started — the terminal
                    // that normally reclaims the runway never fires.
                    streamRunwayBudget = 0
                    streamSpacerHeight = 0
                }
            }
            .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                if !wasStreaming && isStreaming {
                    scrollLog.notice("stream start")
                } else if wasStreaming && !isStreaming {
                    // Terminal edge: reclaim the runway (the clip
                    // releases with it — the settled row renders in
                    // full), then one exact id-solve puts the
                    // question at the viewport top so reading starts
                    // where the reply does. Short replies clamp to
                    // the rest edge — the same frame the stream
                    // showed. Skipped entirely when the user owns the
                    // viewport.
                    scrollLog.notice("stream terminal")
                    streamRunwayBudget = 0
                    streamSpacerHeight = 0
                    let questionID = model.messages.last(where: { $0.role == .user })?.id
                    Task { @MainActor in
                        // One beat for the runway removal + settled
                        // row swap to lay out before the solve.
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !scrollPosition.isPositionedByUser, let qid = questionID else { return }
                        scrollLog.notice("terminal: question-top solve")
                        positionHeld = true
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            scrollPosition.scrollTo(id: qid, anchor: UnitPoint(x: 0, y: 1))
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                        if positionHeld, !scrollPosition.isPositionedByUser {
                            positionHeld = false
                            scrollPosition = ScrollPosition()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
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


/// Snapshot of the bits of `ScrollGeometry` the scroll-to-bottom-pill
/// handler needs. Equatable + Sendable so
/// `onScrollGeometryChange(for:_:action:)` can deliver it through its
/// diff machinery; we only re-fire the action when one of these three
/// values actually moves, not on every layout pass.
private struct ScrollMetrics: Equatable, Sendable {
    var contentHeight: CGFloat
    var offset: CGFloat
    var viewportHeight: CGFloat
    var contentWidth: CGFloat
    var viewportWidth: CGFloat
    var offsetX: CGFloat
}

/// The conversation's toolbar menu. Its label is the running cost,
/// truncated to cents — the always-visible signal the old status chip
/// carried, now living in the nav bar where it costs no vertical
/// space. Inside: Compress (infrequent, so demoted from a top-level
/// button), Contexts, and a non-interactive precise-cost entry. When
/// any assistant turn ran on a model without per-token pricing, an
/// "Unpriced models" entry appears and opens the explainer listing
/// them (subscription / flat-fee models like Z.AI Coding Plan don't
/// populate per-million pricing in `user_models`, so those turns roll
/// up as $0 and the total is approximate).
///
/// A standalone view (not a ConversationBody computed) so its O(N)
/// message scans re-run only when the observed model data changes —
/// inside ConversationBody they re-ran on every body evaluation,
/// which during scroll-command storms meant per-tick.
private struct ConversationMenu: View {
    @Bindable var model: ConversationViewModel
    @Binding var showingContexts: Bool
    @State private var showingMissingCostInfo = false

    var body: some View {
        Menu {
            Button {
                model.showingCompactView = true
            } label: {
                Label("Compress", systemImage: "wand.and.stars")
            }
            .disabled(model.isStreaming || model.isCompacting || model.hasPendingCompression)

            Button {
                showingContexts = true
            } label: {
                Label("Contexts", systemImage: "tray.full")
            }

            Divider()

            // Precise cost, deliberately unclickable — information,
            // not an action. The truncated version lives on the menu
            // label; this row carries the full four decimals.
            Button {} label: {
                Label(String(format: "$%.4f", accruedCost), systemImage: "dollarsign.circle")
            }
            .disabled(true)

            if !modelsMissingCost.isEmpty {
                Button {
                    showingMissingCostInfo = true
                } label: {
                    Label("Unpriced models…", systemImage: "exclamationmark.triangle")
                }
            }
        } label: {
            // Truncated to cents; monospaced digits so the label
            // doesn't wobble as the total ticks up. The warning
            // triangle rides along when the total is approximate.
            HStack(spacing: 4) {
                if !modelsMissingCost.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(String(format: "$%.2f", accruedCost))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("Conversation menu")
        .accessibilityValue(String(format: "cost $%.4f", accruedCost))
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

    /// Total cost of the ACTIVE CONTEXT — every message in it,
    /// including abandoned branches. The server's per-context
    /// aggregate (ListContexts.cumulative_cost_usd) is the source:
    /// a chain-local sum undercounts the moment the user forks,
    /// because the messages array only holds the currently-viewed
    /// branch (user-reported: "cost shows only the current tree").
    /// The chain sum remains as the fallback for the window before
    /// loadContexts lands (cold cache, first frames).
    private var accruedCost: Double {
        if let ctx = model.activeContext,
           let row = model.contexts.first(where: { $0.id == ctx.id }) {
            return row.cumulativeCostUsd
        }
        return model.messages.reduce(0) { acc, m in
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
}

// MARK: - Decoupled scroll-content subviews
//
// These exist to keep streaming-chunk-rate state mutations out of the
// settled-history render path. Each subview reads only the observable
// properties it actually consumes — so `model.streamingText` updating
// 20-50× per second does NOT re-eval ChatHistoryArea's body and run
// ForEach over hundreds of messages.

/// Renders the settled message + compression-summary timeline,
/// NEWEST-FIRST for the flipped stack (each row un-flips itself via
/// `chatRowFlip`). Observes only `model.messages`; immune to
/// streaming-text churn. No mount window: LazyVStack realizes rows
/// outward from the newest edge and older rows realize on scroll —
/// laziness and the inverted origin point the same direction now.
/// Message ids are stable, so a new message is a pure head-insert in
/// ForEach's diff.
private struct ChatHistoryArea: View, @MainActor Equatable {
    @Bindable var model: ConversationViewModel
    @Environment(\.chatPaneWidth) private var paneWidth

    /// Value-equality gate for parent-driven re-renders. WITHOUT this
    /// conformance every ConversationBody invalidation (each geometry
    /// tick during seeks and streams) re-ran this body and re-diffed
    /// the full ForEach — at 446 messages that was 446 MessageRow
    /// constructions per frame, the dominant cost in the live
    /// 100%-CPU sample. Message-content changes still re-render:
    /// @Observable tracks `model.messages` as this view's OWN
    /// dependency, independent of parent diffing; same for the
    /// paneWidth environment.
    static func == (_: ChatHistoryArea, _: ChatHistoryArea) -> Bool { true }

    /// Exact per-row width: the pane minus the transcript padding.
    /// The stack-level exact frame keeps the whole content honest,
    /// but a transition pass (keyboard show, send relayout) can still
    /// re-solve a SINGLE realized row against a loose proposal and
    /// render it wide (video-verified: one boundary row flush to the
    /// screen edge while its neighbors held their margins). Pinning
    /// each row makes the width non-negotiable in every pass.
    private var rowWidth: CGFloat? {
        paneWidth > 32 ? paneWidth - 32 : nil
    }

    var body: some View {
        ForEach(model.messages.reversed()) { msg in
            if msg.role == .compressionSummary {
                CompressionSummaryCard(message: msg, model: model)
                    .frame(width: rowWidth, alignment: .leading)
                    .chatRowFlip()
                    .id(msg.id)
            } else {
                MessageRow(message: msg, model: model)
                    .frame(width: rowWidth, alignment: .leading)
                    .chatRowFlip()
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
private struct PendingUserArea: View, @MainActor Equatable {
    @Bindable var model: ConversationViewModel
    @State private var queuedTick: Int = 0
    @Environment(\.chatPaneWidth) private var paneWidth

    /// Same parent-diff gate as ChatHistoryArea: observation of
    /// pendingUserText / the queue snapshot drives real updates.
    static func == (_: PendingUserArea, _: PendingUserArea) -> Bool { true }

    private var rowWidth: CGFloat? {
        paneWidth > 32 ? paneWidth - 32 : nil
    }

    var body: some View {
        // Newest-first for the flipped stack: queued entries (newer
        // than the pending sentinel) precede it.
        Group {
            ForEach(model.queuedEntries.reversed()) { entry in
                QueuedUserRow(text: entry.content)
                    .frame(width: rowWidth, alignment: .leading)
                    .chatRowFlip()
                    .id("__queued_\(entry.id)")
            }
            if let pending = model.pendingUserText {
                PendingUserRow(text: pending)
                    .frame(width: rowWidth, alignment: .leading)
                    .chatRowFlip()
                    .id("__pending__")
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
    @Environment(\.chatPaneWidth) private var paneWidth

    private var rowWidth: CGFloat? {
        paneWidth > 32 ? paneWidth - 32 : nil
    }

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
            .frame(width: rowWidth, alignment: .leading)
            .chatRowFlip()
            .id("__streaming__")
        }
    }
}

/// Un-flips one row inside the inverted transcript stack. The scroll
/// view renders through `scaleEffect(y: -1)` (newest at offset 0);
/// every row applies this to draw its content upright. Pure render
/// transform — layout, geometry probes, and heights are unaffected.
extension View {
    fileprivate func chatRowFlip() -> some View {
        scaleEffect(x: 1, y: -1)
    }
}


// MARK: - Archived (read-only) state

private struct ArchivedBar: View {
    let conversationID: String
    let archivedAt: Date
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Archived")
                    .font(.callout.weight(.semibold))
                Text(archivedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unarchive") {
                Task {
                    try? await app.client.conversations.unarchive(id: conversationID)
                    await convos.refresh()
                    dismiss()
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

extension ConversationBody {
    /// Replaces the composer while the conversation is archived. The
    /// server refuses every mutation on archived conversations, so the
    /// transcript above is view-only; Unarchive restores it to the
    /// active list and pops back.
    @ViewBuilder
    fileprivate func archivedBar(_ archivedAt: Date) -> some View {
        ArchivedBar(conversationID: liveConversation.id, archivedAt: archivedAt)
    }
}
