import Foundation
import Connect
import os.log

private let syncLog = Logger(subsystem: "dev.jdpedrie.psmith", category: "Sync")

/// Long-lived subscription to the server's account-scoped event
/// stream. Each received event is dispatched to a typed callback so
/// the calling layer (typically `AppModel`) can refresh local state.
///
/// Lifecycle: `start()` once on bootstrap, `stop()` on tear-down (or
/// just cancel the owning Task). The subscriber auto-reconnects on
/// stream end with exponential backoff up to a cap, so a server
/// restart or transient network blip recovers without app
/// intervention.
///
/// Not MainActor — PsmithClient's init runs in a non-isolated context
/// so the subscriber has to construct there. Callbacks delivered to
/// `onProfileChanged` arrive on the runLoop's executor; callers that
/// touch SwiftUI state should hop to MainActor inside the closure
/// (AppModel does — see its bootstrap wire-up).
public final class EventsSubscriber: @unchecked Sendable {
    private let client: Psmith_V1_EventsServiceClientInterface
    /// Fired when the server pushes a ProfileChanged event. Argument
    /// is the affected profile id — callers can use it to refresh just
    /// one profile or invalidate the whole list (current consumer
    /// does the latter; per-profile granularity is opportunistic).
    /// Mutated only from MainActor (per AppModel wiring) so the
    /// @unchecked Sendable conformance is honest.
    public var onProfileChanged: (@Sendable (String) -> Void)?
    /// Fired when the server pushes a ConversationChanged event —
    /// any mutation of any of the user's conversations, from any
    /// client INCLUDING this one (events carry no origin identity).
    /// Consumers keep their reaction cheap: debounced list refresh
    /// plus a staleness check on the open conversation.
    public var onConversationChanged: (@Sendable (String) -> Void)?
    /// Fired when the server pushes a ProviderChanged event — a model
    /// provider (or any of its models: enable/disable, metadata,
    /// settings, favorites) was mutated. Argument is the provider id;
    /// the current consumer reloads the whole provider list.
    public var onProviderChanged: (@Sendable (String) -> Void)?

    private var task: Task<Void, Never>?

    public init(client: Psmith_V1_EventsServiceClientInterface) {
        self.client = client
    }

    /// Begin the subscription. Idempotent — calling twice while
    /// already running is a no-op.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop the subscription. Closes the underlying stream and
    /// halts the reconnect loop.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Drop the current connection attempt (and whatever backoff
    /// sleep it's in) and reconnect NOW. Call on auth transitions and
    /// app foregrounding: a subscriber that failed pre-auth or died
    /// during a background suspend may be deep in the 30s backoff,
    /// and every second it waits is a second another client's
    /// changes stay invisible.
    public func kick() {
        guard task != nil else {
            start()
            return
        }
        stop()
        start()
    }

    /// The reconnect loop. Opens the server-streaming RPC, reads
    /// events until the stream ends or the Task is cancelled, then
    /// backs off and tries again. Cap at 30s so a long server outage
    /// doesn't spin forever at full speed.
    private func runLoop() async {
        var backoffSeconds: Double = 0.5
        while !Task.isCancelled {
            let connectedAt = ContinuousClock.now
            do {
                try await subscribe()
                // Clean stream end (server closed) — reset backoff
                // for the next cycle.
                backoffSeconds = 0.5
            } catch {
                // Any error → back off. Network unreachable, auth
                // failure (recoverable on reconnect after re-auth),
                // server crash. A connection that held for a while
                // before failing was HEALTHY — reset the ladder so a
                // session's accumulated blips don't climb toward the
                // 30s cap and stretch every future recovery.
                if ContinuousClock.now - connectedAt > .seconds(10) {
                    backoffSeconds = 0.5
                }
                syncLog.notice("events stream ended: \(String(describing: error), privacy: .public); retry in \(backoffSeconds, privacy: .public)s")
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(backoffSeconds))
            backoffSeconds = min(backoffSeconds * 2, 30)
        }
    }

    /// Single subscription pass. Returns normally on clean close,
    /// throws on error (callers retry).
    private func subscribe() async throws {
        let stream = client.subscribeAccountEvents(headers: [:])
        defer { stream.cancel() }
        try stream.send(Psmith_V1_SubscribeAccountEventsRequest())
        syncLog.notice("events stream connected")
        for await result in stream.results() {
            switch result {
            case .headers, .complete:
                // Headers carry no payload we need; complete ends
                // the stream cleanly.
                continue
            case .message(let event):
                dispatch(event)
            }
        }
    }

    /// Translate a wire event into a typed callback. New event
    /// variants the client doesn't yet handle are silently ignored
    /// so the server can ship new events without breaking old clients.
    private func dispatch(_ event: Psmith_V1_AccountEvent) {
        guard let kind = event.kind else { return }
        switch kind {
        case .profileChanged(let payload):
            onProfileChanged?(payload.profileID)
        case .conversationChanged(let payload):
            onConversationChanged?(payload.conversationID)
        case .providerChanged(let payload):
            onProviderChanged?(payload.providerID)
        }
    }
}
