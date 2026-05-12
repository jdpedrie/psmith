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
        public let purpose: ReeveStreamPurpose
        public var streamingText: String = ""
        public var streamingThinking: String = ""
        public var streamingThinkingStartedAt: Date?
        public var streamingThinkingFinishedAt: Date?
        public var streamingToolCalls: [LiveToolCall] = []
        public var lastSequence: Int64 = 0

        public var id: String { runID }
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

    private var tasks: [String /* runID */: Task<Void, Never>] = [:]
    private var terminalHandlers: [String /* conversationID */: (ReeveStreamRun) async -> Void] = [:]

    private let subscriber: StreamSubscriber

    public init(subscriber: StreamSubscriber) {
        self.subscriber = subscriber
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
        onTerminal: @escaping (ReeveStreamRun) async -> Void
    ) {
        terminalHandlers[conversationID] = onTerminal
    }

    /// Drop the terminal callback. Called when the view model is being
    /// torn down so a deferred terminal doesn't fire into a stale VM.
    public func detach(conversationID: String) {
        terminalHandlers.removeValue(forKey: conversationID)
    }

    /// Start tracking + subscribing to a freshly-started run. Called
    /// from `ConversationViewModel.send()` / `sendForking()` /
    /// `compact()` / etc. after their RPC returns the new run.
    public func register(
        runID: String,
        conversationID: String,
        contextID: String,
        purpose: ReeveStreamPurpose
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
    public func adopt(_ run: ReeveStreamRun) {
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
        streams.removeValue(forKey: conversationID)
        activeConversationIDs.remove(conversationID)
    }

    /// Stop every subscription and clear all state. Logout path.
    public func reset() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        streams.removeAll()
        activeConversationIDs.removeAll()
        terminalHandlers.removeAll()
    }

    // MARK: - Private machinery

    private func cancelLocalSubscription(forConversation conversationID: String) {
        guard let prev = streams[conversationID] else { return }
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

    private func applyChunk(_ c: ReeveChunk, runID: String, conversationID: String) {
        guard var s = streams[conversationID], s.runID == runID else { return }
        s.lastSequence = max(s.lastSequence, c.sequence)
        switch c.type {
        case .textDelta:
            if let str = c.textIfDelta {
                if s.streamingThinkingStartedAt != nil, s.streamingThinkingFinishedAt == nil {
                    s.streamingThinkingFinishedAt = Date()
                }
                s.streamingText += str
            }
        case .thinkingDelta:
            if let str = c.textIfDelta {
                if s.streamingThinkingStartedAt == nil {
                    s.streamingThinkingStartedAt = Date()
                }
                s.streamingThinking += str
            }
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
        default:
            break
        }
        streams[conversationID] = s
    }

    private func handleTerminal(run: ReeveStreamRun, conversationID: String) async {
        let handler = terminalHandlers[conversationID]
        tasks.removeValue(forKey: run.id)
        // Run the handler FIRST (load + clearStreamingState etc.) so
        // by the time we clear the hub entry, the view model has
        // already mirrored the materialised assistant row into
        // `messages`. The UI briefly shows StreamingRow + new
        // MessageRow simultaneously — the double-render is content-
        // similar and reads as a smooth swap; clearing the hub entry
        // first would instead leave a brief BLANK gap (no streaming,
        // no settled row) for the duration of the network round-trip.
        if let handler {
            await handler(run)
        }
        streams.removeValue(forKey: conversationID)
        activeConversationIDs.remove(conversationID)
    }
}
