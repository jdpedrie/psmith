import Foundation
import Observation

/// App-lifetime owner of every active stream subscription. Survives
/// `ConversationViewModel` creation/destruction so the user can leave a
/// chat mid-generation, come back, and pick up where they left off
/// without a refresh round-trip.
///
/// Design:
///  - Keyed by `conversationID` because at most one stream runs per
///    conversation at a time (send + compaction are mutually exclusive
///    in the view model).
///  - Each `ActiveStream` accumulates the same state the view model
///    used to own directly (streamingText, streamingThinking, tool
///    calls, sequence cursor).
///  - Subscriber tasks run on the main actor (chunk handlers mutate
///    `@Observable` state) and keep going until the run terminates,
///    regardless of whether any view is attached.
///  - Views attach by reading `streams[conversationID]` — `@Observable`
///    tracks the nested reads, so chunk-driven updates propagate
///    automatically.
///  - On terminal, the hub fires `onTerminal[conversationID]` (a
///    callback the active view registered via `attach`) and clears the
///    entry. If no view is registered, the entry is still cleared and
///    the next `attach()` returns nil — the view's next `load()` picks
///    up the materialised assistant turn from the server.
///
/// Not persisted across app launches; on cold start the conversations
/// model queries `Streams.ListActiveRuns` for the user and re-adopts
/// any runs that were still going on the server.
@MainActor
@Observable
public final class StreamHub {
    public struct ActiveStream: Identifiable, Hashable, Sendable {
        public let runID: String
        public let conversationID: String
        public let contextID: String
        public let purpose: PsmithStreamPurpose
        public var streamingText: String = ""
        public var streamingThinking: String = ""
        public var streamingThinkingStartedAt: Date?
        public var streamingThinkingFinishedAt: Date?
        public var streamingToolCalls: [LiveToolCall] = []
        public var lastSequence: Int64 = 0
        /// MCP elicitation prompts emitted by in-process tools mid-run.
        /// The view layer reads this; when non-empty, render a form for
        /// the first entry. Submitting (or declining/cancelling) drops
        /// the entry. Subsequent entries — multiple Elicits in one tool
        /// call, rare but legal — surface one at a time.
        public var pendingElicitations: [PendingElicit] = []

        public var id: String { runID }

        /// Public memberwise init — snapshot tests and SwiftUI previews
        /// construct fully-formed streams to seed via `seedForPreview`.
        public init(
            runID: String,
            conversationID: String,
            contextID: String,
            purpose: PsmithStreamPurpose,
            streamingText: String = "",
            streamingThinking: String = "",
            streamingThinkingStartedAt: Date? = nil,
            streamingThinkingFinishedAt: Date? = nil,
            streamingToolCalls: [LiveToolCall] = [],
            lastSequence: Int64 = 0,
            pendingElicitations: [PendingElicit] = []
        ) {
            self.runID = runID
            self.conversationID = conversationID
            self.contextID = contextID
            self.purpose = purpose
            self.streamingText = streamingText
            self.streamingThinking = streamingThinking
            self.streamingThinkingStartedAt = streamingThinkingStartedAt
            self.streamingThinkingFinishedAt = streamingThinkingFinishedAt
            self.streamingToolCalls = streamingToolCalls
            self.lastSequence = lastSequence
            self.pendingElicitations = pendingElicitations
        }
    }

    /// Snapshot/preview seam: injects a fully-formed ActiveStream so
    /// snapshot tests and SwiftUI previews can render streaming states
    /// without a live run. No subscriber task is spawned — the seeded
    /// entry is inert display state. Not for production paths.
    public func seedForPreview(_ stream: ActiveStream) {
        streams[stream.conversationID] = stream
        activeConversationIDs.insert(stream.conversationID)
    }

    /// One in-flight MCP elicitation request waiting for a user response.
    /// Carries the schema verbatim so renderers can introspect (the
    /// `format: password` hint drives secure-text rendering, etc.).
    public struct PendingElicit: Identifiable, Hashable, Sendable {
        /// UUID assigned server-side. Used as the path segment of the
        /// response endpoint.
        public let id: String
        /// Human-readable prompt the server wants displayed above the
        /// form.
        public let message: String
        /// JSON Schema bytes for the expected response payload. Parsed
        /// at render time — the schema set our v1 UI handles is narrow
        /// (object with one or more string / boolean / integer
        /// properties; string with `format: password` renders secure).
        public let schemaJSON: Data
    }

    /// Public for view-model reads. Mutations stay inside the hub.
    public private(set) var streams: [String: ActiveStream] = [:]

    /// Conversations with an active stream right now. Mutated only on
    /// register / adopt / clear / terminal — NOT on every chunk —
    /// so list-row indicators that read this don't re-render at chunk
    /// rate. (`streams` itself mutates on every chunk and would invalidate
    /// every observer of either property, which previously dragged the
    /// kept-alive conversations list under a streaming conversation
    /// into 20-50Hz body re-evals.)
    public private(set) var activeConversationIDs: Set<String> = []

    /// Conversations the user currently has open on screen. Driven by
    /// `ConversationView`'s `.onAppear` / `.onDisappear` (set on both
    /// Mac and iOS). A set rather than a single id because the macOS
    /// sidebar + detail can technically swap selection between two
    /// open conversations under selection-change animations — Set
    /// semantics keep the "is the user looking at this?" answer
    /// stable across the brief overlap window.
    public private(set) var viewingConversationIDs: Set<String> = []

    /// Conversations whose most-recent assistant run terminated while
    /// the user wasn't viewing them. Drives the list-row "new message"
    /// dot. Cleared per-conversation on next `markViewing` (the user
    /// opening the conversation is the canonical "I've seen it"). Set
    /// to a fresh value through `markUnseen` only.
    ///
    /// Persisted to UserDefaults under `unseenStorageKey` so the dot
    /// survives app relaunches — if the assistant message landed while
    /// the app was backgrounded / killed, the indicator still draws
    /// the user's attention back to the right conversation.
    public private(set) var unseenConversationIDs: Set<String> = []

    /// Drops the matching pending elicitation from the active stream.
    /// Called by the view layer after the response endpoint succeeds
    /// (the actual POST goes through ElicitationsRepository) so the
    /// UI form dismisses. Idempotent — dropping an unknown id is a
    /// no-op.
    public func clearPendingElicitation(conversationID: String, elicitationID: String) {
        guard var s = streams[conversationID] else { return }
        s.pendingElicitations.removeAll { $0.id == elicitationID }
        streams[conversationID] = s
    }

    private var tasks: [String /* runID */: Task<Void, Never>] = [:]
    private var terminalHandlers: [String /* conversationID */: (PsmithStreamRun) async -> Void] = [:]

    /// Optional device-tool dispatcher. When non-nil, ChunkDeviceToolUse
    /// events forward to it for native-API execution + result POST.
    /// nil = the hub silently ignores device-tool chunks (the model
    /// will see the call time out server-side, ~60s).
    public var deviceToolDispatcher: DeviceToolDispatcher?

    private let subscriber: StreamSubscriber

    /// Backing store for `unseenConversationIDs`. Production passes
    /// `.standard`; tests pass an isolated suite so a parallel run
    /// can't poison another test's expectations.
    private let defaults: UserDefaults

    /// UserDefaults key used to persist `unseenConversationIDs`. Versioned
    /// so future migration paths can leave the old set alone if the shape
    /// changes (e.g. per-conversation timestamps).
    private static let unseenStorageKey = "psmith.streamHub.unseenConversationIDs.v1"

    public init(subscriber: StreamSubscriber, defaults: UserDefaults = .standard) {
        self.subscriber = subscriber
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.unseenStorageKey) as? [String] {
            self.unseenConversationIDs = Set(stored)
        }
    }

    // MARK: - Public surface

    /// Returns the active stream for a conversation, if any. View
    /// models check this on `load()` to decide whether to render the
    /// streaming bubble + adopt `streamRunID` for the Stop button.
    public func activeStream(conversationID: String) -> ActiveStream? {
        streams[conversationID]
    }

    /// Register a terminal callback for the conversation. The view
    /// model passes its terminal handler here on mount — the hub
    /// invokes it when the active stream ends. Replaces any
    /// previously-registered handler for the same conversation.
    public func attach(
        conversationID: String,
        onTerminal: @escaping (PsmithStreamRun) async -> Void
    ) {
        terminalHandlers[conversationID] = onTerminal
    }

    /// Drop the terminal callback. Called when the view model is being
    /// torn down so a deferred terminal doesn't fire into a stale VM.
    public func detach(conversationID: String) {
        terminalHandlers.removeValue(forKey: conversationID)
    }

    /// Per-conversation server-push change observers. Registered by
    /// ConversationViewModel alongside its terminal handler (same
    /// replace-on-remount semantics); invoked when the account event
    /// stream reports a mutation of that conversation. Handlers hold
    /// their VM weakly, so a stale registration for a closed
    /// conversation no-ops.
    private var changeHandlers: [String /* conversationID */: () async -> Void] = [:]

    /// Register the change observer for a conversation. Replaces any
    /// previously-registered observer for the same conversation.
    public func attachChangeObserver(
        conversationID: String,
        _ handler: @escaping () async -> Void
    ) {
        changeHandlers[conversationID] = handler
    }

    /// Route a ConversationChanged account event to the open view
    /// model, if one is registered. Fire-and-forget.
    public func notifyConversationChanged(conversationID: String) {
        guard let handler = changeHandlers[conversationID] else { return }
        Task { await handler() }
    }

    /// Marks the conversation as currently on screen (user has the
    /// conversation view open). Called from `ConversationView`'s
    /// `.onAppear`. Doubles as "user has seen it" — opening clears any
    /// pending unseen flag in the same step.
    public func markViewing(conversationID: String) {
        viewingConversationIDs.insert(conversationID)
        if unseenConversationIDs.remove(conversationID) != nil {
            persistUnseen()
        }
    }

    /// Marks the conversation as no longer on screen. Doesn't touch
    /// unseen — leaving the chat without new content arriving is not
    /// the same as missing a message.
    public func markStoppedViewing(conversationID: String) {
        viewingConversationIDs.remove(conversationID)
    }

    /// Clear an unseen flag without changing viewing state. Used from
    /// paths that imply the user is aware of the new content but not
    /// through opening the conversation (e.g. they tapped a
    /// notification linking to a different surface). The common
    /// "opened the chat" path goes through `markViewing` instead.
    public func markSeen(conversationID: String) {
        if unseenConversationIDs.remove(conversationID) != nil {
            persistUnseen()
        }
    }

    private func persistUnseen() {
        defaults.set(
            Array(unseenConversationIDs),
            forKey: Self.unseenStorageKey
        )
    }

    /// Start tracking + subscribing to a freshly-started run. Called
    /// from `ConversationViewModel.send()` / `sendForking()` /
    /// `compact()` / etc. after their RPC returns the new run.
    public func register(
        runID: String,
        conversationID: String,
        contextID: String,
        purpose: PsmithStreamPurpose
    ) {
        cancelLocalSubscription(forConversation: conversationID)
        streams[conversationID] = ActiveStream(
            runID: runID,
            conversationID: conversationID,
            contextID: contextID,
            purpose: purpose
        )
        activeConversationIDs.insert(conversationID)
        startSubscriber(runID: runID, conversationID: conversationID, fromSequence: 0)
    }

    /// Adopt a run discovered via `Streams.ListActiveRuns` (i.e., not
    /// started in this process). Reuses an existing in-memory entry
    /// if the hub already knows about it.
    public func adopt(_ run: PsmithStreamRun) {
        if let existing = streams[run.conversationID], existing.runID == run.id {
            // Already subscribed — nothing to do. Subscriber task is
            // accumulating chunks already.
            return
        }
        cancelLocalSubscription(forConversation: run.conversationID)
        streams[run.conversationID] = ActiveStream(
            runID: run.id,
            conversationID: run.conversationID,
            contextID: run.contextID,
            purpose: run.purpose
        )
        activeConversationIDs.insert(run.conversationID)
        startSubscriber(runID: run.id, conversationID: run.conversationID, fromSequence: 0)
    }

    /// Cancel a run server-side (user pressed Stop). The terminal
    /// event the server emits will clear local state.
    public func cancel(conversationID: String) async {
        guard let s = streams[conversationID] else { return }
        try? await subscriber.cancel(streamRunID: s.runID)
    }

    /// Force-drop a conversation's active state without notifying the
    /// server. Used during testing / on logout / on conversation
    /// switch when we want a fresh slate.
    public func clear(conversationID: String) {
        cancelLocalSubscription(forConversation: conversationID)
        discardPendingDeltas(conversationID: conversationID)
        streams.removeValue(forKey: conversationID)
        activeConversationIDs.remove(conversationID)
    }

    /// Stop every subscription and clear all state. Logout path.
    public func reset() {
        for (_, task) in tasks { task.cancel() }
        for (_, task) in flushTasks { task.cancel() }
        flushTasks.removeAll()
        pendingText.removeAll()
        pendingThinking.removeAll()
        pendingSequence.removeAll()
        tasks.removeAll()
        streams.removeAll()
        activeConversationIDs.removeAll()
        viewingConversationIDs.removeAll()
        unseenConversationIDs.removeAll()
        terminalHandlers.removeAll()
        persistUnseen()
    }

    // MARK: - Private machinery

    // Chunk-rate prose is COALESCED before it touches the observable
    // stream state: every `streams[...]` write invalidates every
    // observer — the streaming row re-parses its whole markdown, the
    // transcript re-lays, the scroll geometry re-ticks — so at wire
    // rates of 20–50 deltas/s the app paid a full render pipeline per
    // delta, quadratic in reply length for the parse alone. Text and
    // thinking deltas accumulate here and flush at most every
    // `flushInterval`; structural events (tool calls, elicitation,
    // thinking transitions, terminal, teardown) flush immediately so
    // ordering is preserved.
    private var pendingText: [String: String] = [:]
    private var pendingThinking: [String: String] = [:]
    private var pendingSequence: [String: Int64] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    private let flushInterval: Duration = .milliseconds(100)

    private func bufferDelta(conversationID: String, text: String? = nil, thinking: String? = nil, sequence: Int64) {
        if let text { pendingText[conversationID, default: ""] += text }
        if let thinking { pendingThinking[conversationID, default: ""] += thinking }
        pendingSequence[conversationID] = max(pendingSequence[conversationID] ?? 0, sequence)
        guard flushTasks[conversationID] == nil else { return }
        flushTasks[conversationID] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.flushInterval)
            guard !Task.isCancelled else { return }
            self.flushTasks.removeValue(forKey: conversationID)
            self.flushDeltas(conversationID: conversationID)
        }
    }

    private func flushDeltas(conversationID: String) {
        flushTasks[conversationID]?.cancel()
        flushTasks.removeValue(forKey: conversationID)
        let text = pendingText.removeValue(forKey: conversationID)
        let thinking = pendingThinking.removeValue(forKey: conversationID)
        let seq = pendingSequence.removeValue(forKey: conversationID)
        guard text != nil || thinking != nil || seq != nil else { return }
        guard var s = streams[conversationID] else { return }
        if let text { s.streamingText += text }
        if let thinking { s.streamingThinking += thinking }
        if let seq { s.lastSequence = max(s.lastSequence, seq) }
        streams[conversationID] = s
    }

    /// Drop buffered-but-unflushed deltas WITHOUT applying them. Used
    /// when the stream state itself is being discarded — flushing
    /// into a removed stream would be a no-op anyway, but the timers
    /// must not linger.
    private func discardPendingDeltas(conversationID: String) {
        flushTasks[conversationID]?.cancel()
        flushTasks.removeValue(forKey: conversationID)
        pendingText.removeValue(forKey: conversationID)
        pendingThinking.removeValue(forKey: conversationID)
        pendingSequence.removeValue(forKey: conversationID)
    }

    private func cancelLocalSubscription(forConversation conversationID: String) {
        guard let prev = streams[conversationID] else { return }
        // Flush, don't discard: a suspended subscription resumes from
        // the FLUSHED lastSequence — dropping buffered chunks silently
        // here would rely on server replay, while leaving them
        // unflushed would replay-duplicate them.
        flushDeltas(conversationID: conversationID)
        tasks[prev.runID]?.cancel()
        tasks.removeValue(forKey: prev.runID)
    }

    private func startSubscriber(runID: String, conversationID: String, fromSequence: Int64) {
        tasks[runID] = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.subscriber.subscribe(streamRunID: runID, fromSequence: fromSequence) {
                switch event {
                case .chunk(let c):
                    self.applyChunk(c, runID: runID, conversationID: conversationID)
                case .terminal(let run):
                    await self.handleTerminal(run: run, conversationID: conversationID)
                    return
                case .failed:
                    // Resilient subscriber exhausted retries — treat
                    // as terminal with no run; clear local state so
                    // the next `load()` reconciles via the chain.
                    self.streams.removeValue(forKey: conversationID)
                    self.activeConversationIDs.remove(conversationID)
                    self.tasks.removeValue(forKey: runID)
                    return
                }
            }
        }
    }

    private func applyChunk(_ c: PsmithChunk, runID: String, conversationID: String) {
        guard let current = streams[conversationID], current.runID == runID else { return }
        // Prose deltas go through the coalescing buffer — see the
        // machinery above. Transition edges (first thinking delta,
        // thinking→text) mutate visible timestamps, so they flush and
        // write immediately; everything else buffered here never
        // touches the observable state.
        switch c.type {
        case .textDelta:
            guard let str = c.textIfDelta else { return }
            if current.streamingThinkingStartedAt != nil, current.streamingThinkingFinishedAt == nil {
                flushDeltas(conversationID: conversationID)
                if var s = streams[conversationID], s.runID == runID {
                    s.streamingThinkingFinishedAt = Date()
                    streams[conversationID] = s
                }
            }
            bufferDelta(conversationID: conversationID, text: str, sequence: c.sequence)
            return
        case .thinkingDelta:
            guard let str = c.textIfDelta else { return }
            if current.streamingThinkingStartedAt == nil {
                flushDeltas(conversationID: conversationID)
                if var s = streams[conversationID], s.runID == runID {
                    s.streamingThinkingStartedAt = Date()
                    streams[conversationID] = s
                }
            }
            bufferDelta(conversationID: conversationID, thinking: str, sequence: c.sequence)
            return
        default:
            // Structural chunk: order it after any buffered prose.
            flushDeltas(conversationID: conversationID)
        }
        guard var s = streams[conversationID], s.runID == runID else { return }
        s.lastSequence = max(s.lastSequence, c.sequence)
        switch c.type {
        case .contentReset:
            // The compression continuation restarted the document —
            // everything accumulated so far is superseded (see the
            // server's ChunkContentReset). Pending deltas were flushed
            // above, so the wipe is complete.
            s.streamingText = ""
        case .toolUseStart:
            if let info = c.toolUseStartInfo {
                s.streamingToolCalls.append(LiveToolCall(id: info.id, name: info.name, startedAt: Date()))
            }
        case .toolUseDelta:
            if let partial = c.toolUseDeltaPartialJSON,
               let last = s.streamingToolCalls.indices.last {
                s.streamingToolCalls[last].input.append(partial)
            }
        case .toolUseEnd:
            if let idx = s.streamingToolCalls.lastIndex(where: { $0.argsCompletedAt == nil }) {
                s.streamingToolCalls[idx].argsCompletedAt = Date()
            }
        case .toolResult:
            guard let info = c.toolResultInfo else { break }
            let idx = s.streamingToolCalls.lastIndex(where: { $0.resultArrivedAt == nil })
                ?? s.streamingToolCalls.lastIndex(where: { $0.id == info.toolUseID })
            if let idx {
                s.streamingToolCalls[idx].output = info.output
                s.streamingToolCalls[idx].error = info.error
                s.streamingToolCalls[idx].elapsedMs = info.elapsedMs
                s.streamingToolCalls[idx].resultArrivedAt = Date()
                if s.streamingToolCalls[idx].argsCompletedAt == nil {
                    s.streamingToolCalls[idx].argsCompletedAt = s.streamingToolCalls[idx].resultArrivedAt
                }
            }
        case .elicit:
            if let info = c.elicitInfo {
                s.pendingElicitations.append(PendingElicit(
                    id: info.id,
                    message: info.message,
                    schemaJSON: info.schemaJSON
                ))
            }
        case .deviceToolUse:
            // Forward to the device-tool dispatcher (if wired).
            // The dispatcher runs the matching handler off-actor
            // and POSTs the result back via the broker — no hub-
            // visible state change. ChunkDeviceToolUse is purely
            // a "tell the device to do work" cue; the result
            // arrives as a normal ChunkToolResult in the next
            // round, which the existing case handles.
            deviceToolDispatcher?.handleChunk(c, conversationID: conversationID)
        default:
            break
        }
        streams[conversationID] = s
    }

    private func handleTerminal(run: PsmithStreamRun, conversationID: String) async {
        // Any coalesced prose lands before terminal handling so the
        // streaming row shows the complete text through the swap to
        // the settled message.
        flushDeltas(conversationID: conversationID)
        let handler = terminalHandlers[conversationID]
        tasks.removeValue(forKey: run.id)

        // Mark the "new message arrived while user wasn't looking"
        // state BEFORE invoking the handler. Used to be after, but
        // the VM's terminal handler now clears the hub streams
        // entry as soon as the materialised assistant row is in
        // `messages` (to make the StreamingRow → MessageRow swap
        // atomic). That early clear flips
        // `vm.streamRunID == nil` while the post-handler code path
        // is still pending — any caller polling on streamRunID
        // would race the unseen mark. Moving the mark up front
        // sidesteps the race entirely; the handler doesn't
        // influence whether the user "saw" the message, only the
        // viewing flag does.
        //
        // Status is intentionally not gated: even an errored /
        // cancelled assistant turn produces a new row the user
        // should notice. Compaction terminals don't qualify — the
        // user kicked them off intentionally.
        if run.purpose == .assistantResponse,
           !viewingConversationIDs.contains(conversationID),
           unseenConversationIDs.insert(conversationID).inserted {
            persistUnseen()
        }

        // Run the handler. The VM typically calls `hub.clear` from
        // inside this handler once the materialised message is in
        // `messages`, hiding the StreamingRow in the same render
        // frame the settled MessageRow appears. Without that,
        // both render together for the duration of any downstream
        // network work (sidebar refresh, title generation, …).
        if let handler {
            await handler(run)
        }
        // Idempotent — the handler's hub.clear already removed
        // these, but cleaning up here too means a handler that
        // didn't call clear (legacy / tests without a VM) still
        // results in a settled state. Guarded on the entry still
        // belonging to THIS run: the handler's early clear flips
        // `streamRunID == nil`, which un-gates Send — a next turn
        // can register a NEW entry for this conversation before we
        // resume here, and removing it unconditionally would kill
        // the live stream's hub state mid-turn (the UI freezes and
        // the send gate lies until the chain reload).
        if streams[conversationID]?.runID == run.id {
            streams.removeValue(forKey: conversationID)
            activeConversationIDs.remove(conversationID)
        }
    }
}
