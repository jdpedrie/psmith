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

    /// There is NO auto-follow. A send pins the just-sent question at
    /// the viewport top and the response streams in below with the
    /// viewport motionless — reading starts at the top of a reply, so
    /// chasing its tail was pure motion (and, at heavy conversation
    /// scale, visibly janky motion solved against layout estimates).
    /// The only remaining scroll movers: the cold-entry seek, the
    /// one pin at send, the scroll-to-bottom pill, and two idle-time
    /// clamps.
    ///
    /// Scroll handle for the explicit seeks (entry, send pin, pill).
    @State private var scrollPosition = ScrollPosition()
    /// Programmatic push into the contexts list — the Contexts entry
    /// lives in the toolbar menu now, and Menus don't host
    /// NavigationLinks reliably.
    @State private var showingContexts = false
    /// True while the pill's jump-to-bottom is converging: seeks from
    /// far above solve against estimated coordinates and can land
    /// short, so the geometry handler keeps re-seeking until the
    /// bottom is actually reached. Cleared on arrival or on any user
    /// grab. (Its predecessor re-used the follow flag here, and the
    /// user-scroll disengage raced the re-seek loop to death — the
    /// "pill does nothing" report.)
    @State private var seekingBottom = false

    /// Governor for EVERY programmatic scroll command the geometry
    /// handler can issue (convergence re-seek, past-bottom clamp).
    /// Each command triggers a re-layout that re-estimates LazyVStack
    /// content, which fires the geometry handler again — ungoverned,
    /// that loop ran at tick rate against a flapping estimate and
    /// never converged: the pill spin pinned the main thread at 100%
    /// for minutes (sampled live; log showed the same JUMP repeating
    /// every 43ms), and the post-delete clamp is the same disease.
    /// The cooldown gives each solve a beat to realize rows before
    /// the next command re-solves; the attempt caps convert "never
    /// converges" into "lands nearby and stops".
    @State private var lastAutoScrollAt: TimeInterval = 0
    @State private var autoSeekAttempts = 0
    @State private var clampAttempts = 0
    private let autoScrollCooldown: TimeInterval = 0.25
    private let maxAutoSeekAttempts = 8
    private let maxClampAttempts = 4

    /// Latest scroll metrics, readable OUTSIDE the geometry handler.
    /// A reference-type box deliberately: writing it per tick must not
    /// invalidate any view body (an @State struct write would — that
    /// per-tick invalidation was the amplification engine behind the
    /// 100%-CPU storms). `settleAtBottom` reads it to converge without
    /// depending on the tick stream, because SwiftUI stops ticking the
    /// instant layout stabilizes — including stabilizing in a WRONG
    /// position (log-verified: parked past-end with a cooldown-blocked
    /// clamp and zero further ticks to retry on).
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

    /// The scroll-content unit's global minX, from the layer probe.
    /// The entry curtain gates on THIS being clean — the scroll
    /// offset's x reads 0 while the content draws displaced (the
    /// probes disagree by design; pixels follow the content unit).
    @State private var contentUnitMinX: CGFloat = 0


    // THE SEND PIN, third design. History stays mounted (unmounting
    // it read as data loss, and the post-terminal remount could
    // strand the viewport in estimate-space at heavy scale). The
    // question reaches the viewport top via exactly ONE absolute
    // scroll computed from MEASURED geometry — the pending row
    // reports its .scrollView-space minY, and the jump is
    // scrollTo(y: offset + minY), both quantities real. No id or
    // edge solving: every estimate-mediated strategy failed at 406
    // heavy messages (id-solves ~3,000pt short and wandering; a held
    // edge position oscillating ±1,713pt/tick against the UIKit
    // clamp; convergence re-seeking storming the re-estimator at
    // 100% main thread). After the jump the shrinking runway (see
    // streamRunwayBudget) keeps content height constant, so the
    // frozen offset IS the pin.

    /// Runway budget below the streaming reply, fixed at send. The
    /// rendered spacer is budget − (measured streaming height), so
    /// question + reply + spacer stays CONSTANT while the reply
    /// grows — no content-height change, no offset movement, the
    /// reply visually fills the gap in place. Nonzero = send pin
    /// live; zeroed at terminal, by the pill, and on send failure.
    @State private var streamRunwayBudget: CGFloat = 0
    /// The runway's rendered height (derived, see above).
    @State private var streamSpacerHeight: CGFloat = 0
    /// Armed at send; the geometry handler fires the one measured
    /// jump when the pending row's reported position arrives, then
    /// disarms. Cancelled by user grab or terminal.
    @State private var pinJumpPending = false
    /// Latest .scrollView-space minY reported by the pending row (or
    /// the real user row it swaps into, via pinTargetMessageID).
    @State private var pinReportedY: CGFloat?
    /// Post-swap id of the just-sent user row, so it keeps reporting
    /// if the swap lands before the jump fires.
    @State private var pinTargetMessageID: String?
    /// Set when the jump fires; the geometry handler releases the
    /// held ScrollPosition binding as soon as the offset arrives at
    /// this target. A position HELD through the stream re-solves x
    /// against every coalesced re-lay and shimmies the transcript
    /// ±16pt at flush cadence (probe-verified: minX oscillating
    /// −16→0 at ~3Hz for the whole stream — the user-visible
    /// "jitters left and right"), and held past terminal it parks
    /// the margin shift permanently. The frozen offset needs no live
    /// position: content is constant under the shrinking runway.
    @State private var pinDropTarget: CGFloat?

    /// First mounted index into `model.messages`, or nil while the
    /// cold-entry tail window (newest `coldEntryTail` rows) is active.
    ///
    /// This is the fix for the long-standing "cold entry into a long
    /// chat lands in blank space past the messages" bug. Root cause
    /// (device-confirmed): handing LazyVStack 200+ messages in one shot
    /// makes it realize rows from the TOP while the total content size
    /// stays estimated — all the estimate error accumulates at the
    /// BOTTOM as phantom blank space, and the bottom anchor seeks into
    /// it (the scrollbar showed ~5 screens of desert below the last
    /// message). A ~dozen-row tail realizes fully in one pass, so the
    /// content size is exact and the anchor lands on the real last
    /// message.
    ///
    /// Lifecycle (fully transparent — no buttons, no unload):
    ///   nil → cold entry mounts only the newest `coldEntryTail`
    ///         rows so the bottom seek lands true.
    ///   n>0 → once the viewport is OBSERVED settled at the bottom,
    ///         `startHistoryBackfill` walks this DOWN to 0 in small
    ///         batches, one runloop beat apart. Each batch prepends
    ///         above the viewport while the bottom edge is
    ///         anchor-pinned over realized rows — invisible. Batches,
    ///         not one shot: with the full history prepended at once,
    ///         LazyVStack estimates the unrealized mass from the
    ///         realized neighbors, and when the tail rows are TALL
    ///         (long essays) the sticky bottom edge re-solves against
    ///         a wildly inflated total and strands the viewport tens
    ///         of thousands of points past the real content end
    ///         (log-verified: distance=-26882 on re-entry). Batching
    ///         bounds the estimate error the re-solve can see to one
    ///         batch's worth.
    ///   0   → everything is mounted; scrolling up is seamless and
    ///         new sends just append (an index anchor, unlike a
    ///         suffix count, doesn't unmount old rows on append).
    ///
    /// The earlier "Show earlier messages" capsule + frozen-cutoff
    /// design is gone: the v5.1 variant that re-trimmed on every send
    /// and re-expanded at terminal caused the across-the-board
    /// regressions (history visibly unloading, viewport stranded below
    /// the conversation at stream close). Mounting monotonically,
    /// only while idle-at-bottom, and never re-trimming is the safe
    /// combination.
    @State private var mountedFromIndex: Int?
    /// True while the batch loop is walking `mountedFromIndex` down.
    @State private var backfilling = false
    /// Rows kept mounted before the backfill. Enough to fill
    /// any phone viewport so the cold-entry bottom seek is exact.
    private let coldEntryTail = 12
    /// Rows prepended per backfill beat.
    private let backfillBatch = 40

    /// Whether history above the mounted window still needs mounting.
    private var needsBackfill: Bool {
        if let idx = mountedFromIndex { return idx > 0 }
        return model.messages.count > coldEntryTail
    }

    /// True from cold entry until the staged backfill fully
    /// completes (or pauses, or a send starts). Gates the sizeChanges
    /// bottom anchor: a SINGLE stable Bool, deliberately not a
    /// composite expression — an earlier gate that swapped which
    /// subterm supplied `true` mid-entry killed the anchor the tick
    /// the subterms crossed, and the backfill prepends then pushed
    /// the viewport to mid-conversation under a frozen offset.
    @State private var entryAnchorActive = true

    /// Entry curtain. The transcript renders at opacity 0 (layout
    /// fully live) until the geometry handler first observes the
    /// viewport settled at the bottom, then fades in. Even the 12-row
    /// tail window's initial realization runs an estimate oscillation
    /// (logged 2196→42365→16228pt on a tall tail) that the bottom
    /// seek chases across a few passes — invisible on a fast
    /// simulator, a visible settle-flash on device. Hiding the
    /// content until the first settle makes cold entry cut straight
    /// to the correct frame. A short timeout reveals regardless so a
    /// pathological geometry can't blank the pane.
    @State private var entrySettled = false

    /// True while the ScrollPosition binding holds an explicit
    /// position (entry seek, past-bottom clamp, pill seek, send pin).
    /// A held position keeps re-solving on every content change — and
    /// the `Edge.bottom` flavor re-solves center-x against estimated
    /// widths, drifting the transcript 16pt left. So the geometry
    /// handler DROPS any live position (replaces the binding) the
    /// next time it observes settled-at-bottom at rest: from then on
    /// nothing re-solves x at all. Send pins survive to the terminal
    /// because the stream spacer keeps `distance` deep until then.
    @State private var stickyLive = false

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
            // A shrink while system-positioned at the bottom (message
            // delete) drops the content end out from under the
            // viewport; if layout stabilizes past-end no tick ever
            // fires to correct it. User-positioned offsets are
            // excluded: UIKit clamps those natively when content
            // shrinks, and a reader parked above the deletion isn't
            // affected at all.
            if new < old, !scrollPosition.isPositionedByUser,
               !model.isStreaming, !model.sending, streamRunwayBudget == 0 {
                Task { await settleAtBottom(reason: "shrink") }
            }
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
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    paneWidth = size.width
                    viewportHeight = size.height
                }
        }
    }

    @ViewBuilder
    private var paneScrollBody: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Settled history is its own subview that observes
                    // only `model.messages`. Without this split, every
                    // streaming chunk (which mutates streamingText on the
                    // shared @Observable model) would re-eval the entire
                    // LazyVStack content closure — running ForEach over
                    // N messages and constructing N MessageRow values
                    // per chunk, even though none of them changed.
                    ChatHistoryArea(
                        model: model,
                        fromIndex: mountedFromIndex,
                        tail: coldEntryTail,
                        pinTargetID: pinTargetMessageID,
                        onPinTargetMove: { pinReportedY = $0 },
                        entryActive: !entrySettled || backfilling || entryAnchorActive
                    )
                    .equatable()
                    // Pending user is its own subview for the same
                    // reason — observes only pendingUserText, not the
                    // chunk-rate streaming state.
                    PendingUserArea(
                        model: model,
                        onPinTargetMove: { pinReportedY = $0 }
                    )
                    .equatable()
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
                    // Scroll runway for the send pin. Clear color,
                    // not Spacer(): LazyVStack gives Spacer no height.
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
                }
                .padding()
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
            // The sizeChanges bottom anchor exists ONLY for the
            // entry/backfill window: it pins the bottom edge from
            // INSIDE the scroll view's layout pass, which is what
            // makes the staged history prepends land invisibly above
            // the viewport (any hand-computed alternative solves
            // against LazyVStack's estimates and overshoots into
            // blank space). Once the backfill completes it detaches
            // for good — streaming no longer follows anything.
            //
            // Bottom-LEADING, not `.bottom`: `.bottom` is
            // UnitPoint(x: 0.5, y: 1) and the anchor solves BOTH
            // axes. When a relayout pass transiently over-estimates
            // the content width (backfill batches, keyboard show),
            // the x:0.5 anchor re-centers the content against the
            // oversized estimate — a lasting 16pt leftward shift the
            // moment the width settles back (probe-verified). x:0
            // pins the leading edge so the width estimate can't move
            // the transcript horizontally at all.
            .defaultScrollAnchor(
                entryAnchorActive ? UnitPoint(x: 0, y: 1) : nil,
                for: .sizeChanges
            )
            // Deliberately NO second defaultScrollAnchor modifier (an
            // .initialOffset one was tried): stacking anchor modifiers
            // clobbers the sizeChanges role — same composition trap as
            // the all-roles/sizeChanges conflict — which killed the
            // backfill lockstep and stranded entry mid-conversation.
            .onAppear {
                // Sticky bottom position for cold entry: holds the
                // bottom through load + tail-window settle + backfill
                // start, then the settle handler drops it. Edge.bottom
                // is a CENTER-X solve whose re-solves can shimmy the
                // transcript horizontally — the curtain exists to hide
                // exactly that window, which is why its reveal gates
                // on the content unit's measured x and why its timeout
                // must comfortably outlast a heavy load (an absolute
                // measured chase was tried instead of this seek and
                // stranded entry on estimate-transient false bottoms).
                //
                // Deliberately NO convergence arming here — the
                // loop's re-seeks fight the load-growth the entry
                // anchor rides (armed on appear it broke cold entry
                // outright, reproduced). Entry lands via the sticky
                // edge seek + anchor alone; the pill's remount path
                // replays this same sequence.
                seekBottom()
            }
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
                let bottomEdge = m.offset + m.viewportHeight
                let distance = m.contentHeight - bottomEdge

                // Transient-motion telemetry. The scroll bugs this view
                // has a history of (offset lurches mid-stream, viewport
                // stranded past the content end) are only visible in
                // the gaps BETWEEN screenshots — this handler sees
                // every layout tick, so it logs the discontinuities
                // themselves. Notice-level so `log collect` after a
                // device repro carries the evidence. Gated on system-
                // driven motion (or an active stream) — user flings
                // produce big legitimate deltas; programmatic ones are
                // the bug class. This deliberately covers the terminal
                // window: isStreaming flips false BEFORE the reload
                // and park re-asserts, which an isStreaming-only gate
                // would miss entirely.
                let systemDriven = !scrollPosition.isPositionedByUser
                if systemDriven || model.isStreaming || model.isCompacting {
                    let dOff = m.offset - old.offset
                    let dContent = m.contentHeight - old.contentHeight
                    if abs(dOff) > 48 {
                        scrollLog.notice("JUMP dOff=\(Int(dOff), privacy: .public) off=\(Int(old.offset), privacy: .public)→\(Int(m.offset), privacy: .public) content=\(Int(m.contentHeight), privacy: .public) vp=\(Int(m.viewportHeight), privacy: .public) seeking=\(seekingBottom, privacy: .public) user=\(scrollPosition.isPositionedByUser, privacy: .public) streaming=\(model.isStreaming, privacy: .public)")
                    }
                    if abs(dContent) > 120, abs(dContent) > abs(dOff) {
                        scrollLog.notice("CONTENT-LURCH dContent=\(Int(dContent), privacy: .public) content=\(Int(old.contentHeight), privacy: .public)→\(Int(m.contentHeight), privacy: .public) off=\(Int(m.offset), privacy: .public)")
                    }
                    if distance < -8, systemDriven {
                        scrollLog.notice("PAST-END distance=\(Int(distance), privacy: .public) off=\(Int(m.offset), privacy: .public) content=\(Int(m.contentHeight), privacy: .public)")
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

                // First settle → lift the entry curtain. distance<8
                // means the bottom seek has landed on real (realized)
                // content, and the x check means the entry seek's
                // center-x re-solves haven't left the content shifted
                // — so the frame we reveal is the correct one both
                // vertically AND horizontally. (Revealing on y alone
                // showed drifted margins for ~1s until the position
                // machinery caught up — user-reported on device.)
                if !entrySettled, distance < 8, m.contentHeight > 0,
                   abs(m.offsetX) <= 0.5, abs(contentUnitMinX) <= 0.5 {
                    withAnimation(.easeIn(duration: 0.12)) {
                        entrySettled = true
                    }
                }

                // Settled at the bottom with nothing in flight: any
                // live explicit position is pure liability (its
                // re-solves are the x-drift engine). Drop it. NO
                // `!backfilling` term: the entry anchor alone holds
                // the bottom through the backfill (verified lockstep),
                // and deferring the drop leaves the center-x edge
                // position live for the backfill to re-poison — the
                // v21 "margins collapsed through entry" burst frames.
                // Settled BAND, not `< 8`: a past-end transient
                // (estimate collapse mid-walk logged distance −781)
                // passes a one-sided check, and dropping the entry
                // seek at that moment leaves nothing to re-solve the
                // viewport back when the estimate re-inflates.
                // Drop band top is 64 (one bubble height), matching
                // the seek arrival band — with < 8 an at-rest distance
                // of ~41 (tail padding) left the sticky edge position
                // LATCHED, and the first on-demand history mount
                // re-solved it back to the new bottom: a yank to the
                // tail the instant the user tried to read older
                // messages.
                if stickyLive, entrySettled, distance < 64, distance > -8,
                   streamRunwayBudget == 0, !seekingBottom,
                   !scrollPosition.isPositionedByUser {
                    stickyLive = false
                    entryAnchorActive = false
                    scrollPosition = ScrollPosition()
                    scrollLog.notice("sticky dropped")
                }

                // On-demand history mounting — the ONLY mount driver.
                // The window stays at the cold-entry tail until the
                // user scrolls near the top of what's mounted, then
                // one batch prepends immediately (2400pt of lead means
                // the mount lands before the edge is visible). The
                // sizeChanges anchor pins the bottom for the batch so
                // the prepend never moves the user's position.
                //
                // This REPLACES the eager settled-at-bottom walk that
                // mounted all N rows after entry. At heavy scale that
                // walk was the engine of the blank-pane / lockup
                // family: hundreds of freshly-mounted unrealized rows
                // put LazyVStack's content estimate in charge, the
                // estimate collapsed under the walk (logged geometric
                // decay 700k→3k with the viewport riding it down), and
                // every corrective actor either chased it at tick rate
                // (100% CPU lockup) or gave up past-end (blank park).
                // A capped window keeps entry deterministic — 12 real
                // rows, exact coordinates — and caps every later
                // re-diff at the mounted count instead of N.
                if needsBackfill, !backfilling, m.offset < 2400,
                   entrySettled,
                   !model.sending, !model.isStreaming {
                    mountOlderBatch()
                }

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
                // Release the held pin position the tick the jump
                // lands (see pinDropTarget). At-rest binding
                // replacement — content is constant under the runway,
                // so this is the verified-safe drop, not the
                // mid-stream rewind case.
                if let target = pinDropTarget,
                   !scrollPosition.isPositionedByUser,
                   abs(m.offset - target) < 64 {
                    pinDropTarget = nil
                    stickyLive = false
                    scrollPosition = ScrollPosition()
                    scrollLog.notice("send pin position dropped")
                }

                // Absolute, not seekBottom(): contentHeight and
                // viewportHeight here are measured, so the target is
                // exact — an id/edge solve at heavy scale can land
                // ABOVE the bottom where this guard never re-fires.
                // Gated off while the send pin's runway is live (the
                // spacer keeps distance positive; transient negatives
                // during its layout must not yank the pin).
                // NEVER during the entry walk: the clamp's absolute
                // target is only as good as the metrics, and mid-walk
                // estimate collapses (content 750k→3k logged) make it
                // write a garbage offset that strands the viewport
                // mid-conversation once the estimate re-inflates. The
                // entry seek + anchor own transients until settle.
                // Reset the failure counters whenever the viewport is
                // actually settled near the bottom — the governor caps
                // count SUCCESSIVE misfires, not lifetime ones.
                if distance > -1, distance < 8 {
                    clampAttempts = 0
                }
                if distance < -1, streamRunwayBudget == 0,
                   entrySettled, !backfilling,
                   scrollPhase == .idle,
                   !scrollPosition.isPositionedByUser,
                   clampAttempts < maxClampAttempts,
                   CACurrentMediaTime() - lastAutoScrollAt >= autoScrollCooldown {
                    scrollLog.notice("past-bottom clamp fired (distance=\(Int(distance), privacy: .public)) attempt=\(clampAttempts + 1, privacy: .public)")
                    clampAttempts += 1
                    lastAutoScrollAt = CACurrentMediaTime()
                    stickyLive = true
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        scrollPosition.scrollTo(x: 0, y: max(0, m.contentHeight - m.viewportHeight))
                    }
                    return
                }

                // Pill convergence. A jump-to-bottom from far above
                // solves its target against estimated coordinates; at
                // hundreds-of-heavy-messages scale it lands well shy
                // of the real bottom. While `seekingBottom` is armed,
                // keep re-seeking — each pass realizes rows near the
                // landing zone and refines the solve — until arrival
                // (distance settles) or the user takes the viewport.
                // A dedicated flag, NOT the old follow flag: the
                // user-scroll disengage used to race the re-seek loop
                // and kill it after the first short landing, which is
                // exactly why the pill "did nothing" from far away.
                if seekingBottom {
                    if scrollPosition.isPositionedByUser {
                        seekingBottom = false
                        autoSeekAttempts = 0
                        scrollLog.notice("bottom seek cancelled: user took over")
                    } else if distance < 64 {
                        // Arrival band = the re-seek trigger threshold.
                        // With arrival at <8 and re-seek at >64, a rest
                        // distance in 8..64 left the seek LATCHED
                        // indefinitely — doing nothing until an estimate
                        // collapse minutes later handed it a garbage
                        // bottom to chase (log-verified: a latched seek
                        // "arrived" at offset 51967 of a 736k-pt
                        // conversation and blanked the pane). One
                        // bubble-height short of exact is arrived.
                        seekingBottom = false
                        autoSeekAttempts = 0
                        scrollLog.notice("bottom seek arrived (distance=\(Int(distance), privacy: .public))")
                    } else if autoSeekAttempts >= maxAutoSeekAttempts {
                        // The edge solve is oscillating against the
                        // estimate flap (live repro: distance bounced
                        // 1567→140→1567 at tick rate, forever). Stop
                        // seeking and land with ONE absolute jump off
                        // the current measured metrics — nearby beats
                        // never.
                        seekingBottom = false
                        autoSeekAttempts = 0
                        scrollLog.notice("bottom seek budget exhausted — absolute finisher (distance=\(Int(distance), privacy: .public))")
                        stickyLive = true
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            scrollPosition.scrollTo(x: 0, y: max(0, m.contentHeight - m.viewportHeight))
                        }
                        return
                    } else if distance > 64, scrollPhase == .idle,
                              CACurrentMediaTime() - lastAutoScrollAt >= autoScrollCooldown {
                        scrollLog.notice("bottom convergence re-seek (distance=\(Int(distance), privacy: .public)) attempt=\(autoSeekAttempts + 1, privacy: .public)")
                        autoSeekAttempts += 1
                        lastAutoScrollAt = CACurrentMediaTime()
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            seekBottom()
                        }
                        return
                    }
                }

                // Release any live pin the moment the user takes
                // over. An id-pin is STICKY — the scroll view
                // re-applies it on every arriving chunk, which snaps
                // the viewport back against the user's drag
                // (verified: repeated drags barely moved while a
                // stream pin held). Replacing the binding while the
                // user's gesture owns the viewport breaks the pin
                // without the at-rest one-viewport rewind.
                if stickyLive, scrollPosition.isPositionedByUser {
                    scrollLog.notice("pin released: user took over")
                    stickyLive = false
                    scrollPosition = ScrollPosition()
                }
                if pinJumpPending, scrollPosition.isPositionedByUser {
                    // The user grabbed the viewport before the jump
                    // fired — their position wins.
                    pinJumpPending = false
                }
                if pinDropTarget != nil, scrollPosition.isPositionedByUser {
                    // Release already handled by the block above; just
                    // retire the pending drop.
                    pinDropTarget = nil
                }

                // The send pin's one measured jump: the pending row
                // reported its top edge at `pinReportedY` (viewport
                // space); offset + that delta puts it exactly at the
                // viewport top. Both quantities are MEASURED — no
                // LazyVStack estimate participates, which is why this
                // works at 1.3M pt where every solver-based pin
                // failed. Fires once; the frozen offset + constant
                // content (shrinking runway) hold the pin afterwards.
                if pinJumpPending, !scrollPosition.isPositionedByUser,
                   let rowY = pinReportedY, rowY > 8 {
                    // Fire only when the runway is IN these metrics:
                    // the tick carrying the row's report can predate
                    // the spacer's layout, and clamping against that
                    // stale max eats most of the jump (measured: 568pt
                    // asked, ~80 granted). Waiting costs one tick —
                    // the spacer's own insertion generates it.
                    let maxOff = max(0, m.contentHeight - m.viewportHeight)
                    if m.offset + rowY <= maxOff + 4 {
                        pinJumpPending = false
                        stickyLive = true
                        let target = m.offset + rowY - 20
                        pinDropTarget = target
                        scrollLog.notice("send pin jump dy=\(Int(rowY), privacy: .public) off=\(Int(m.offset), privacy: .public)")
                        var tj = Transaction()
                        tj.disablesAnimations = true
                        withTransaction(tj) {
                            // −20: .scrollView-space minY doesn't
                            // account for the top content inset under
                            // the status strip; without the margin the
                            // bubble's first line sits clipped behind
                            // it (screenshot-verified).
                            scrollPosition.scrollTo(x: 0, y: target)
                        }
                        return
                    }
                }

                // Pill visibility. The runway is blank space, not
                // content — subtract it or the pill lights on every
                // send before anything is below the fold.
                let newFar = (distance - streamSpacerHeight) > scrollToBottomThreshold
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
                    // Arm the convergence loop BEFORE the seek: the
                    // jump is non-animated (tweening across estimated
                    // coordinates buys nothing), and the geometry
                    // handler keeps re-seeking while `seekingBottom`
                    // holds until the bottom is actually reached.
                    seekingBottom = true
                    autoSeekAttempts = 0
                    // An explicit bottom-seek ends the pin contract:
                    // reclaim the runway so "bottom" means the real
                    // content end, not the blank band.
                    streamRunwayBudget = 0
                    streamSpacerHeight = 0
                    pinJumpPending = false
                    pinDropTarget = nil
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        seekBottom()
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
                    // Send: arm the measured one-shot jump (fired by
                    // the geometry handler once the pending row
                    // reports where it landed) and lay the runway so
                    // the question CAN sit at the top with the reply
                    // streaming into view below. History stays
                    // mounted throughout.
                    scrollLog.notice("send: arm pin jump")
                    entryAnchorActive = false
                    seekingBottom = false
                    // A FULL viewport of runway: the jump puts the
                    // question's top at the viewport top, which needs
                    // ≥ vp of content below that point — the question
                    // row itself plus this spacer always satisfies it,
                    // so the jump target can never exceed max-scroll.
                    // (vp − 120 was tried: the target landed past the
                    // end, the held position sat at distance −18, and
                    // the pending→real row swap yanked the viewport
                    // −788 out of the unstable state.)
                    streamRunwayBudget = max(240, viewportHeight)
                    streamSpacerHeight = streamRunwayBudget
                    pinJumpPending = true
                    pinReportedY = nil
                    pinTargetMessageID = nil
                    // Freeze the mounted window to an index anchor if
                    // the send arrived before the backfill ever ran —
                    // a dynamic newest-N suffix would unmount the
                    // window's oldest row when this send appends (the
                    // v5.1 "unloading messages at the top" sin).
                    if mountedFromIndex == nil {
                        mountedFromIndex = max(0, model.messages.count - coldEntryTail)
                    }
                } else if model.sending || model.isStreaming {
                    // Pending sentinel swapped for the real user row;
                    // hand position-reporting to it in case the jump
                    // hasn't fired yet.
                    pinTargetMessageID = model.messages.last(where: { $0.role == .user })?.id
                } else {
                    // Send failed before a run started — the terminal
                    // that normally reclaims the runway never fires.
                    streamRunwayBudget = 0
                    streamSpacerHeight = 0
                    pinJumpPending = false
                    pinTargetMessageID = nil
                    pinDropTarget = nil
                }
            }
            .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                if !wasStreaming && isStreaming {
                    scrollLog.notice("stream start")
                } else if wasStreaming && !isStreaming {
                    // Terminal edge: nothing positional — the offset
                    // is numerically frozen and the streaming→settled
                    // swap happens below the viewport top. Reclaim
                    // the runway; it sits below the fold, so removal
                    // can't move the frame. A reply shorter than the
                    // runway leaves the viewport past the new content
                    // end and the past-bottom clamp (live again once
                    // the budget is zero) settles it with one
                    // measured absolute scroll.
                    scrollLog.notice("stream terminal")
                    seekingBottom = false
                    streamRunwayBudget = 0
                    streamSpacerHeight = 0
                    pinJumpPending = false
                    pinTargetMessageID = nil
                    pinDropTarget = nil
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
            // Entry curtain (see `entrySettled`): opacity keeps layout
            // fully live while hidden, which is exactly what the
            // settle needs. Timeout backstop so an odd geometry can't
            // leave the pane blank.
            .opacity(entrySettled ? 1 : 0)
            .task {
                // Failsafe only. At 700ms a 400-message conversation's
                // load+settle regularly outlasted it, revealing the
                // transcript with the entry seek still live — the
                // visible middle/left shimmy. Real settles reveal via
                // the geometry gate well before this fires.
                try? await Task.sleep(for: .milliseconds(2500))
                if !entrySettled { entrySettled = true }
            }
            // No initial-load task needed for the mount: the geometry
            // handler starts the backfill the instant it observes
            // the viewport settled at the bottom of the cold-entry
            // tail. As a backstop for the rare case where a chat is
            // short enough that it never reports a distinct "settled at
            // bottom" frame, mark everything mounted once the load
            // finishes too.
            .task {
                while model.loading {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if model.messages.count <= coldEntryTail {
                    mountedFromIndex = 0
                    entryAnchorActive = false
                }
            }
    }

    /// Bottom seek that keeps the position solver's x anchored at the
    /// LEADING edge whenever possible. `Edge.bottom` positions solve
    /// center-x, and the solver re-solves against its own (estimated,
    /// sometimes transiently oversized) content width on every
    /// re-pin — parking the transcript 16pt left with nothing
    /// UIKit-side to correct (probe-verified: the backing scroll view
    /// reads offset 0 / inset 0 while the content draws displaced).
    /// So: pin ids with UnitPoint(x: 0, y: 1) anchors. Id targets are
    /// only trusted when they're guaranteed mounted — the streaming /
    /// pending sentinels while they exist, or the last message once
    /// the array is FINAL (load finished + backfill complete; an
    /// id-pin issued against a partial cache page froze the viewport
    /// on message 12 of 228). Anything earlier falls back to the edge
    /// seek; the post-settle upgrade in the geometry handler replaces
    /// it as soon as the id becomes trustworthy.
    private func seekBottom() {
        stickyLive = true
        if model.isStreaming || model.isCompacting || !model.streamingText.isEmpty {
            // Edge, not the "__streaming__" id: an id-solve for a row
            // far outside the realized band can silently no-op — the
            // pill "did nothing" mid-stream. The edge solve always
            // moves; convergence + the settled-band drop finish it.
            scrollPosition.scrollTo(edge: .bottom)
        } else if model.pendingUserText != nil {
            scrollPosition.scrollTo(id: "__pending__", anchor: UnitPoint(x: 0, y: 1))
        } else if !model.loading, mountedFromIndex == 0, let last = model.messages.last {
            scrollPosition.scrollTo(id: last.id, anchor: UnitPoint(x: 0, y: 1))
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// Prepends ONE `backfillBatch`-row batch of older history to the
    /// mounted window. Called from the near-top trigger each time the
    /// user's scroll approaches the top of what's mounted; the
    /// sizeChanges anchor holds the bottom for the batch so the
    /// prepend is invisible, then detaches after a settle beat.
    private func mountOlderBatch() {
        guard !backfilling else { return }
        let idx = mountedFromIndex ?? max(0, model.messages.count - coldEntryTail)
        guard idx > 0 else { return }
        backfilling = true
        entryAnchorActive = true
        mountedFromIndex = max(0, idx - backfillBatch)
        scrollLog.notice("mount older: \(idx, privacy: .public) → \(mountedFromIndex ?? 0, privacy: .public)")
        Task { @MainActor in
            // One settle beat: let the batch's rows realize under the
            // anchor before the trigger may fire again — back-to-back
            // prepends against unrealized rows are the estimate-storm
            // recipe this design retired.
            try? await Task.sleep(for: .milliseconds(120))
            backfilling = false
            entryAnchorActive = false
        }
    }

    /// Bounded bottom-convergence loop that does NOT depend on the
    /// geometry tick stream. Each pass reads the latest measured
    /// metrics from the box; if the viewport isn't settled at the
    /// bottom band it re-asserts the bottom via seekBottom() — which
    /// post-load resolves to the last-row ID PIN, the one position
    /// immune to content-height estimates — then gives layout a beat
    /// to respond. At most six commands 250ms apart: a deliberate,
    /// bounded realization driver in place of the accidental per-tick
    /// storm that used to converge entry (and pinned the CPU doing
    /// it). Bails the moment the user owns the viewport.
    private func settleAtBottom(reason: String) async {
        for attempt in 1...6 {
            let m = metricsBox.latest
            let distance = m.contentHeight - (m.offset + m.viewportHeight)
            if scrollPosition.isPositionedByUser {
                scrollLog.notice("settle(\(reason, privacy: .public)) ceded to user at attempt \(attempt, privacy: .public)")
                return
            }
            if m.contentHeight > 0, distance > -1, distance < 64 {
                scrollLog.notice("settle(\(reason, privacy: .public)) done (distance=\(Int(distance), privacy: .public), attempts=\(attempt - 1, privacy: .public))")
                return
            }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                seekBottom()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let m = metricsBox.latest
        scrollLog.notice("settle(\(reason, privacy: .public)) budget exhausted (distance=\(Int(m.contentHeight - m.offset - m.viewportHeight), privacy: .public))")
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

/// Renders the settled message + compression-summary timeline. Observes
/// only `model.messages` (plus the rare isStreaming flip for the
/// follow-cutoff reporter); immune to streaming-text churn.
///
/// `fromIndex` selects the mounted window: nil renders the newest
/// `tail` rows (the cold-entry window), an index renders
/// `messages[fromIndex...]` (see `mountedFromIndex` on
/// ConversationBody — the backfill walks it to 0 in batches). Message
/// ids are stable, so every window growth is a pure prepend in
/// ForEach's diff.
private struct ChatHistoryArea: View, @MainActor Equatable {
    @Bindable var model: ConversationViewModel
    let fromIndex: Int?
    let tail: Int
    /// When set, the row with this id reports its `.scrollView`-space
    /// minY through `onPinTargetMove` — the send pin's measured
    /// ground truth (see pinReportedY on ConversationBody).
    var pinTargetID: String? = nil
    var onPinTargetMove: (CGFloat) -> Void = { _ in }
    /// True while the entry machinery (curtain + staged backfill) is
    /// live. Disables the memoization gate below for the entry window
    /// ONLY: entry's estimate convergence depends on the per-tick
    /// ForEach re-diff to keep realizing rows (with the gate on
    /// through entry, the content estimate collapsed 700k→23k and
    /// parked the pane blank — reproduced repeatedly). Entry is a
    /// bounded few seconds; the storms this gate exists to kill are
    /// the steady-state ones.
    var entryActive: Bool = false
    @Environment(\.chatPaneWidth) private var paneWidth

    /// Value-equality gate for parent-driven re-renders. The stored
    /// closure (`onPinTargetMove`) defeats SwiftUI's reflection-based
    /// diffing, so WITHOUT this conformance every ConversationBody
    /// invalidation (each geometry tick during seeks and streams)
    /// re-ran this body and re-diffed the full ForEach — at 446
    /// messages that was 446 MessageRow constructions per frame, the
    /// dominant cost in the live 100%-CPU sample. Message-content
    /// changes still re-render: @Observable tracks `model.messages`
    /// as this view's OWN dependency, independent of parent diffing;
    /// same for the paneWidth environment.
    static func == (a: ChatHistoryArea, b: ChatHistoryArea) -> Bool {
        if a.entryActive || b.entryActive { return false }
        return a.fromIndex == b.fromIndex
            && a.tail == b.tail
            && a.pinTargetID == b.pinTargetID
    }

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

    private var visibleMessages: [PsmithMessage] {
        if let idx = fromIndex {
            // Clamp: terminal reloads / fork switches can shrink the
            // array under a frozen index.
            return Array(model.messages.suffix(from: min(idx, model.messages.count)))
        }
        if model.messages.count <= tail {
            return model.messages
        }
        return Array(model.messages.suffix(tail))
    }

    var body: some View {
        ForEach(visibleMessages) { msg in
            if msg.role == .compressionSummary {
                CompressionSummaryCard(message: msg, model: model)
                    .frame(width: rowWidth, alignment: .leading)
                    .id(msg.id)
            } else if msg.id == pinTargetID {
                // The identity change from gaining the modifier is
                // confined to the one pinned row, once per send.
                MessageRow(message: msg, model: model)
                    .frame(width: rowWidth, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .scrollView).minY
                    } action: { y in
                        onPinTargetMove(y)
                    }
                    .id(msg.id)
            } else {
                MessageRow(message: msg, model: model)
                    .frame(width: rowWidth, alignment: .leading)
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
    /// Reports the pending row's `.scrollView`-space minY — the send
    /// pin's measured target until the real user row replaces the
    /// sentinel.
    var onPinTargetMove: (CGFloat) -> Void = { _ in }
    @State private var queuedTick: Int = 0
    @Environment(\.chatPaneWidth) private var paneWidth

    /// Same parent-diff gate as ChatHistoryArea: the closure defeats
    /// reflection diffing; observation of pendingUserText / the queue
    /// snapshot drives real updates.
    static func == (_: PendingUserArea, _: PendingUserArea) -> Bool { true }

    private var rowWidth: CGFloat? {
        paneWidth > 32 ? paneWidth - 32 : nil
    }

    var body: some View {
        Group {
            if let pending = model.pendingUserText {
                PendingUserRow(text: pending)
                    .frame(width: rowWidth, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .scrollView).minY
                    } action: { y in
                        onPinTargetMove(y)
                    }
                    .id("__pending__")
            }
            ForEach(model.queuedEntries) { entry in
                QueuedUserRow(text: entry.content)
                    .frame(width: rowWidth, alignment: .leading)
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
            .id("__streaming__")
        }
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
