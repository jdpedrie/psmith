import SwiftUI
import PsmithKit
import PsmithUI
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
    /// Viewport height of the message scroll, measured via
    /// `onGeometryChange`. Used as the cap above which auto-follow
    /// disengages so a long response stops scrolling once the bubble
    /// fills the screen.
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

    /// Whether the sticky scroll position has been upgraded from the
    /// cold-entry `Edge.bottom` seek (which re-solves center-x; see
    /// seekBottom) to an x-honest id pin. Flips once, when the
    /// geometry handler first observes bottom-settled with the
    /// message array final.
    @State private var stickyUpgraded = false

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            if let err = model.loadError, !model.messages.isEmpty {
                loadErrorBanner(err)
            }
            if let speechErr = app.speech.playbackError {
                speechErrorBanner(speechErr)
            }
            messageScroll
            if let archivedAt = liveConversation.archivedAt {
                archivedBar(archivedAt)
            } else {
                Composer(model: model)
            }
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
                    ChatHistoryArea(model: model, fromIndex: mountedFromIndex, tail: coldEntryTail)
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
            // Bottom-LEADING, not `.bottom`: `.bottom` is
            // UnitPoint(x: 0.5, y: 1) and the anchor solves BOTH
            // axes. When a relayout pass transiently over-estimates
            // the content width (backfill batches, keyboard show),
            // the x:0.5 anchor re-centers the content against the
            // oversized estimate — a lasting 16pt leftward shift the
            // moment the width settles back (probe-verified: the
            // content unit's global x oscillated 0→-16 per batch and
            // stuck at -16; the user sees it as "the margins shifted
            // left"). x:0 pins the leading edge so the width estimate
            // can't move the transcript horizontally at all.
            .defaultScrollAnchor(
                autoFollow ? UnitPoint(x: 0, y: 1) : nil,
                for: .sizeChanges
            )
            .onAppear {
                // Sticky bottom position for cold entry: holds the
                // bottom through load + tail-window settle + backfill.
                // The stickiness is exactly the follow behavior we
                // want while autoFollow is true; it is explicitly
                // broken at park (disengageFollow resets the binding)
                // and replaced by any user drag. seekBottom targets an
                // id when messages are already cached and only falls
                // back to the center-x edge seek pre-content; the
                // entry-settle handler upgrades the sticky position
                // to the x-honest id pin either way.
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
                liveOffset.y = m.offset
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
                        scrollLog.notice("JUMP dOff=\(Int(dOff), privacy: .public) off=\(Int(old.offset), privacy: .public)→\(Int(m.offset), privacy: .public) content=\(Int(m.contentHeight), privacy: .public) vp=\(Int(m.viewportHeight), privacy: .public) follow=\(autoFollow, privacy: .public) user=\(scrollPosition.isPositionedByUser, privacy: .public) parked=\(parkedMessageID != nil, privacy: .public) streaming=\(model.isStreaming, privacy: .public)")
                    }
                    if abs(dContent) > 120, abs(dContent) > abs(dOff) {
                        scrollLog.notice("CONTENT-LURCH dContent=\(Int(dContent), privacy: .public) content=\(Int(old.contentHeight), privacy: .public)→\(Int(m.contentHeight), privacy: .public) off=\(Int(m.offset), privacy: .public)")
                    }
                    if distance < -8, systemDriven {
                        scrollLog.notice("PAST-END distance=\(Int(distance), privacy: .public) off=\(Int(m.offset), privacy: .public) content=\(Int(m.contentHeight), privacy: .public) follow=\(autoFollow, privacy: .public)")
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
                // content, so the frame we reveal is the correct one.
                if !entrySettled, distance < 8, m.contentHeight > 0 {
                    withAnimation(.easeIn(duration: 0.12)) {
                        entrySettled = true
                    }
                }

                // Silent staged expansion: the moment we observe the
                // viewport settled at the bottom of the cold-entry tail
                // window (the seek has landed on the small, fully-
                // realized set), start mounting the rest of the
                // history in batches. The bottom edge is anchor-pinned
                // over realized rows, so each prepend lands entirely
                // above the viewport and is invisible. Gated on
                // autoFollow so we only expand while genuinely
                // bottom-pinned, never mid-scroll; if the user grabs
                // the view mid-backfill the loop pauses and this
                // trigger resumes it on the next settle.
                if needsBackfill, !backfilling, autoFollow, distance < 8 {
                    startHistoryBackfill()
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
                if autoFollow, distance < -1,
                   scrollPhase == .idle,
                   !scrollPosition.isPositionedByUser {
                    scrollLog.notice("past-bottom clamp fired (distance=\(Int(distance), privacy: .public))")
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        seekBottom()
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
                    scrollLog.notice("follow off: user scrolled (distance=\(Int(distance), privacy: .public))")
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
                    scrollLog.notice("park released: user took over")
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
            // BOTTOM, just above the composer: the pill shows exactly
            // when the newest content is below the viewport, so the
            // bottom edge is where the eye already is — and the park
            // pins the just-sent message at the viewport TOP, which a
            // top-anchored pill sat directly on top of (video-verified
            // overlap during every parked stream).
            .overlay(alignment: .bottom) {
                Button {
                    Haptics.impact(.light)
                    autoFollow = true
                    withAnimation(.easeInOut(duration: 0.22)) {
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
                    scrollLog.notice("send: follow on")
                    autoFollow = true
                    streamingRowHeight = 0
                    cutoffArmed = false
                    parkedMessageID = nil
                    // Freeze the mounted window to an index anchor if
                    // the send arrived before the backfill ever ran —
                    // a dynamic newest-N suffix would unmount the
                    // window's oldest row when this send appends (the
                    // v5.1 "unloading messages at the top" sin).
                    if mountedFromIndex == nil {
                        mountedFromIndex = max(0, model.messages.count - coldEntryTail)
                    }
                    // NO explicit bottom-EDGE seek here. The pending
                    // row's insertion is a content size change, and
                    // with autoFollow re-engaged the sizeChanges
                    // anchor pins the bottom from INSIDE that layout
                    // pass — offset and content move in lockstep,
                    // nothing visible. The explicit edge seek this
                    // replaces solved its target against the
                    // pre-layout estimated content height in a
                    // SEPARATE pass; the estimate then refined and
                    // the two passes rendered as an offset flicker
                    // (log-verified ±763pt at send). Keyboard
                    // dismissal (container growth, which the
                    // sizeChanges anchor ignores) is covered by the
                    // past-bottom clamp in the geometry handler.
                    //
                    // The sticky position DOES need re-targeting: an
                    // id pin left on the pre-send last message would
                    // hold that row's bottom pinned while the anchor
                    // pulls toward the growing content below — two
                    // solvers fighting one viewport. The pending row
                    // mounts in this same update, so the pin resolves.
                    var ts = Transaction()
                    ts.disablesAnimations = true
                    withTransaction(ts) {
                        scrollPosition.scrollTo(id: "__pending__", anchor: UnitPoint(x: 0, y: 1))
                    }
                }
            }
            .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
                if !wasStreaming && isStreaming {
                    scrollLog.notice("stream start: follow on")
                    autoFollow = true
                    streamingRowHeight = 0
                    stickyUpgraded = true
                    // Hand the sticky pin from __pending__ to the
                    // streaming row so it tracks the same target the
                    // anchor is following (see the send handler for
                    // why the pin must move with the bottom-most row).
                    var tp = Transaction()
                    tp.disablesAnimations = true
                    withTransaction(tp) {
                        scrollPosition.scrollTo(id: "__streaming__", anchor: UnitPoint(x: 0, y: 1))
                    }
                } else if wasStreaming && !isStreaming {
                    scrollLog.notice("stream terminal (follow=\(autoFollow, privacy: .public) parked=\(parkedMessageID != nil, privacy: .public))")
                    if autoFollow, parkedMessageID == nil {
                        // Following through terminal: the streaming
                        // row unmounts, taking the sticky pin's
                        // target with it. Re-pin the settled last
                        // message once the reload lands (same 300ms
                        // settle window as the parked re-assert).
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard autoFollow, parkedMessageID == nil,
                                  !model.isStreaming else { return }
                            var tt = Transaction()
                            tt.disablesAnimations = true
                            withTransaction(tt) { seekBottom() }
                        }
                    }
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
                            scrollPosition.scrollTo(id: parkedID, anchor: UnitPoint(x: 0, y: 0))
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !autoFollow, parkedMessageID == parkedID else { return }
                            var t2 = Transaction()
                            t2.disablesAnimations = true
                            withTransaction(t2) {
                                scrollPosition.scrollTo(id: parkedID, anchor: UnitPoint(x: 0, y: 0))
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
                    // Fire a little EARLY (24pt above the top) rather
                    // than on the crossing: the preference emits at
                    // chunk cadence, so a crossing check always lands
                    // past the top by up to a chunk's growth and the
                    // id-pin then yanks the content back DOWN
                    // (log-verified minY=-8..-11 parks). Firing early
                    // makes the pin a small continuation of the
                    // motion already underway instead of a reversal.
                    guard autoFollow, minY <= 24 else { return }
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
            // Entry curtain (see `entrySettled`): opacity keeps layout
            // fully live while hidden, which is exactly what the
            // settle needs. Timeout backstop so an odd geometry can't
            // leave the pane blank.
            .opacity(entrySettled ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(700))
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
                }
            }
            // Sticky x-honest upgrade. The cold-entry edge seek's
            // re-pins solve center-x (the margin-shift engine); this
            // waits until the message array is FINAL (load done +
            // backfill complete) and the entry settled, then swaps in
            // the id pin. A polling task, not geometry-driven — once
            // the content is static there are no more geometry ticks
            // to piggyback on (that gap is exactly where the previous
            // attempt silently never ran). Bails if the user or a
            // stream takes over first: both install their own
            // x-honest positions.
            .task {
                for _ in 0..<100 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if stickyUpgraded { return }
                    if scrollPosition.isPositionedByUser || model.isStreaming { return }
                    if !model.loading, mountedFromIndex == 0, !backfilling, entrySettled {
                        stickyUpgraded = true
                        scrollLog.notice("sticky upgraded to id pin")
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { seekBottom() }
                        return
                    }
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
        if model.isStreaming || model.isCompacting || !model.streamingText.isEmpty {
            scrollPosition.scrollTo(id: "__streaming__", anchor: UnitPoint(x: 0, y: 1))
        } else if model.pendingUserText != nil {
            scrollPosition.scrollTo(id: "__pending__", anchor: UnitPoint(x: 0, y: 1))
        } else if !model.loading, mountedFromIndex == 0, let last = model.messages.last {
            scrollPosition.scrollTo(id: last.id, anchor: UnitPoint(x: 0, y: 1))
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// Walks `mountedFromIndex` down to 0 in `backfillBatch`-row steps,
    /// one runloop beat apart, while the viewport stays anchor-pinned
    /// at the bottom. The beat between batches lets each batch's rows
    /// realize before the next prepend, so any bottom-edge re-solve
    /// only ever sees one batch's worth of estimated rows — the
    /// one-shot variant let the re-solve see 200+ estimated rows and
    /// stranded the viewport tens of thousands of points past the
    /// content end when the realized tail was tall.
    ///
    /// Pauses (breaks) if the user takes the viewport mid-walk —
    /// prepends are only invisible while the bottom anchor holds. The
    /// geometry handler restarts it on the next settled-at-bottom
    /// observation.
    private func startHistoryBackfill() {
        guard !backfilling else { return }
        backfilling = true
        scrollLog.notice("backfill start (count=\(model.messages.count, privacy: .public))")
        Task { @MainActor in
            defer { backfilling = false }
            if mountedFromIndex == nil {
                mountedFromIndex = max(0, model.messages.count - coldEntryTail)
            }
            while let idx = mountedFromIndex, idx > 0 {
                guard autoFollow else {
                    scrollLog.notice("backfill paused at \(idx, privacy: .public)")
                    return
                }
                mountedFromIndex = max(0, idx - backfillBatch)
                try? await Task.sleep(for: .milliseconds(80))
            }
            scrollLog.notice("backfill complete")
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
                scrollPosition.scrollTo(id: last.id, anchor: UnitPoint(x: 0, y: 0))
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
                    scrollPosition.scrollTo(id: parkedID, anchor: UnitPoint(x: 0, y: 0))
                }
            }
        }
    }

}

/// Reference-type holder for the live scroll offset. Mutated from the
/// geometry handler every tick WITHOUT invalidating any view (it's a
/// class held in @State — stable identity, field writes are invisible
/// to SwiftUI). Read once per park.
final class LiveOffsetBox {
    var y: CGFloat = 0
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
/// `fromIndex` selects the mounted window: nil renders the newest
/// `tail` rows (the cold-entry window), an index renders
/// `messages[fromIndex...]` (see `mountedFromIndex` on
/// ConversationBody — the backfill walks it to 0 in batches). Message
/// ids are stable, so every window growth is a pure prepend in
/// ForEach's diff.
private struct ChatHistoryArea: View {
    @Bindable var model: ConversationViewModel
    let fromIndex: Int?
    let tail: Int
    @Environment(\.chatPaneWidth) private var paneWidth

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
                    .frame(width: rowWidth, alignment: .leading)
                    .id(msg.id)
            } else {
                MessageRow(message: msg, model: model)
                    .frame(width: rowWidth, alignment: .leading)
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
    @Environment(\.chatPaneWidth) private var paneWidth

    private var rowWidth: CGFloat? {
        paneWidth > 32 ? paneWidth - 32 : nil
    }

    var body: some View {
        Group {
            if let pending = model.pendingUserText {
                PendingUserRow(text: pending)
                    .frame(width: rowWidth, alignment: .leading)
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
    @Binding var streamingRowHeight: CGFloat
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
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
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
