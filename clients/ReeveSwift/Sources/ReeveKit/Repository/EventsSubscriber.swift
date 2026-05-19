import Foundation
import Connect

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
/// Not MainActor — ReeveClient's init runs in a non-isolated context
/// so the subscriber has to construct there. Callbacks delivered to
/// `onProfileChanged` arrive on the runLoop's executor; callers that
/// touch SwiftUI state should hop to MainActor inside the closure
/// (AppModel does — see its bootstrap wire-up).
public final class EventsSubscriber: @unchecked Sendable {
    private let client: Reeve_V1_EventsServiceClientInterface
    /// Fired when the server pushes a ProfileChanged event. Argument
    /// is the affected profile id — callers can use it to refresh just
    /// one profile or invalidate the whole list (current consumer
    /// does the latter; per-profile granularity is opportunistic).
    /// Mutated only from MainActor (per AppModel wiring) so the
    /// @unchecked Sendable conformance is honest.
    public var onProfileChanged: (@Sendable (String) -> Void)?

    private var task: Task<Void, Never>?

    public init(client: Reeve_V1_EventsServiceClientInterface) {
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

    /// The reconnect loop. Opens the server-streaming RPC, reads
    /// events until the stream ends or the Task is cancelled, then
    /// backs off and tries again. Cap at 30s so a long server outage
    /// doesn't spin forever at full speed.
    private func runLoop() async {
        var backoffSeconds: Double = 0.5
        while !Task.isCancelled {
            do {
                try await subscribe()
                // Clean stream end (server closed) — reset backoff
                // for the next cycle.
                backoffSeconds = 0.5
            } catch {
                // Any error → back off. Network unreachable, auth
                // failure (recoverable on reconnect after re-auth),
                // server crash.
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
        try stream.send(Reeve_V1_SubscribeAccountEventsRequest())
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
    private func dispatch(_ event: Reeve_V1_AccountEvent) {
        guard let kind = event.kind else { return }
        switch kind {
        case .profileChanged(let payload):
            onProfileChanged?(payload.profileID)
        }
    }
}
