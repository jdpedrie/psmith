import Foundation
import Connect
import Network
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

    /// This client's own id, as stamped on outbound requests.
    ///
    /// Every mutation fans out to every subscriber for the user, the
    /// originator included. Acting on that echo means a round trip to learn
    /// something this client already knew, landing on the main actor while the
    /// user is still interacting. Suppressing it is the difference between a
    /// send costing one request and costing three.
    private let ownClientID: String

    public init(ownClientID: String = "", client: Psmith_V1_EventsServiceClientInterface) {
        self.ownClientID = ownClientID
        self.client = client
    }

    /// Begin the subscription. Idempotent — calling twice while
    /// already running is a no-op.
    /// Watches the network path and reconnects the moment it changes.
    ///
    /// A wifi-to-cellular handoff, a VPN flap, or airplane mode coming off
    /// leaves the current connection dead but does not fail the read. Without
    /// this the subscriber waits out its backoff (up to 30s) and then the
    /// liveness watchdog (another 50s) before recovering from something the OS
    /// told us about immediately.
    ///
    /// Handlers fire on a background queue; `kick()` mutates `task`, which the
    /// other callers touch from the main actor, so hop before calling it.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        // Handlers are Sendable, so the previous-state flag cannot be a
        // captured var. Updates arrive on one serial queue, but a lock states
        // that rather than relying on it.
        let wasSatisfied = OSAllocatedUnfairLock(initialState: true)
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let previously = wasSatisfied.withLock { prev -> Bool in
                let was = prev
                prev = satisfied
                return was
            }
            // Only act on the transition INTO a usable path. Reacting to the
            // drop as well would just cancel a stream that is already dead and
            // start a reconnect that cannot succeed yet.
            guard satisfied, !previously else { return }
            syncLog.notice("network path became satisfied; reconnecting events stream")
            Task { @MainActor in self?.kick() }
        }
        monitor.start(queue: pathQueue)
        pathMonitor = monitor
    }

    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(label: "dev.jdpedrie.psmith.events.path")

    public func start() {
        startPathMonitor()
        guard task == nil else { return }
        let generation = currentGeneration.withLock { gen -> UInt64 in
            gen &+= 1
            return gen
        }
        task = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    /// Stop the subscription. Closes the underlying stream and
    /// halts the reconnect loop.
    public func stop() {
        // Cancel the live stream, not just the task.
        //
        // Task.cancel() only requests cancellation. The loop is suspended
        // inside `for await stream.results()`, which does not observe it, so
        // the old subscriber kept running while `task = nil` let start() spawn
        // a second one. Every kick could leave another orphan behind, and each
        // orphan receives every event, multiplying the reloads the callbacks
        // fire. Cancelling the stream ends `results()`, so subscribe() returns,
        // its defers run, and runLoop sees the cancellation and exits.
        //
        // This was survivable while a dead connection eventually hit the 600s
        // transport timeout. Heartbeats removed that backstop: an orphan on a
        // live connection is fed forever and never reaps itself.
        cancelActiveStream()
        task?.cancel()
        task = nil
    }

    /// Cancels whatever stream `subscribe()` currently holds, if any.
    ///
    /// Stored as a closure rather than the stream itself so this file does not
    /// have to name Connect's generic stream type.
    private func cancelActiveStream() {
        let cancel = activeStreamCancel.withLock { held -> (@Sendable () -> Void)? in
            let c = held
            held = nil
            return c
        }
        cancel?()
    }

    private let activeStreamCancel = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

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
    /// Bumped on every start. A subscriber whose generation is no longer
    /// current has been superseded and must stop dispatching, even if it is
    /// still unwinding: `results()` can deliver buffered messages after the
    /// stream is cancelled, and a superseded subscriber that dispatched them
    /// would double every reload its callbacks trigger.
    private let currentGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private func isCurrent(_ generation: UInt64) -> Bool {
        currentGeneration.withLock { $0 == generation }
    }

    private func runLoop(generation: UInt64) async {
        var backoffSeconds: Double = 0.5
        while !Task.isCancelled && isCurrent(generation) {
            let connectedAt = ContinuousClock.now
            do {
                try await subscribe(generation: generation)
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
    private func subscribe(generation: UInt64) async throws {
        let stream = client.subscribeAccountEvents(headers: [:])
        defer { stream.cancel() }
        // Publish a cancel hook so stop() can break the `for await` below.
        // Without it a cancelled task stays parked here indefinitely.
        activeStreamCancel.withLock { $0 = { stream.cancel() } }
        defer { activeStreamCancel.withLock { $0 = nil } }
        try stream.send(Psmith_V1_SubscribeAccountEventsRequest())
        syncLog.notice("events stream connected")

        // Liveness watchdog.
        //
        // A stream whose network path has gone away does not fail: the read
        // simply never returns. Nothing else here would notice, because the
        // only other bound is the transport's 600s timeout, so the app sits
        // looking connected and receiving nothing for up to ten minutes. The
        // server heartbeats every 20s specifically so silence can be measured;
        // this cancels the stream when that silence runs past the deadline,
        // which surfaces as an error from `results()` and lets the existing
        // reconnect loop do its job.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                // Poll at half the deadline. Sleeping a full deadline between
                // checks meant worst-case detection was two of them.
                try? await Task.sleep(for: .seconds(RPCTimeouts.eventsLivenessDeadline / 2))
                if Task.isCancelled { return }
                guard let self else { return }
                let (quietFor, deadlineApplies) = self.frameClock.liveness()
                // A server too old to heartbeat gives us nothing to measure,
                // so there is no safe deadline to enforce. Leave the stream
                // alone and fall back to the transport timeout, which is what
                // this client did before heartbeats existed.
                guard deadlineApplies else { continue }
                if quietFor >= .seconds(RPCTimeouts.eventsLivenessDeadline) {
                    syncLog.notice("events stream silent for \(quietFor, privacy: .public); assuming dead, reconnecting")
                    stream.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        frameClock.reset()
        for await result in stream.results() {
            markFrame()
            switch result {
            case .headers, .complete:
                // Headers carry no payload we need; complete ends
                // the stream cleanly.
                continue
            case .message(let event):
                // A superseded subscriber drains quietly rather than firing
                // callbacks a current one is already handling.
                guard isCurrent(generation) else { continue }
                dispatch(event)
            }
        }
    }

    /// When a frame last arrived. Heartbeats count: their whole purpose is to
    /// keep this moving on an account with no real activity.
    ///
    /// Written by the stream loop and read by the watchdog task, so it needs a
    /// lock. This class is `@unchecked Sendable`, which means the compiler
    /// will not flag the race for us.
    private let frameClock = FrameClock()

    private func markFrame() { frameClock.mark() }

    /// Lock-guarded liveness state for one connection. `OSAllocatedUnfairLock`
    /// rather than a serial queue: the critical section is one store or one
    /// load, and a queue hop per received frame would be real overhead on a
    /// chatty stream.
    final class FrameClock: @unchecked Sendable {
        struct State {
            var lastFrame: ContinuousClock.Instant = .now
            var sawHeartbeat = false
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        func mark() {
            lock.withLock { $0.lastFrame = .now }
        }

        /// Records that the server is a version that heartbeats.
        func markHeartbeat() {
            lock.withLock {
                $0.lastFrame = .now
                $0.sawHeartbeat = true
            }
        }

        /// Fresh state for a new connection. The heartbeat flag is per
        /// connection, not per subscriber: reconnecting may land on a
        /// different server.
        func reset() {
            lock.withLock { $0 = State() }
        }

        /// How long since the last frame, and whether the deadline applies at
        /// all. It does not until a heartbeat has been seen: a server that
        /// predates them is not broken, it is just quiet, and tearing its
        /// stream down every deadline would churn the connection forever.
        func liveness() -> (quietFor: Duration, deadlineApplies: Bool) {
            lock.withLock { (ContinuousClock.now - $0.lastFrame, $0.sawHeartbeat) }
        }
    }

    /// Translate a wire event into a typed callback. New event
    /// variants the client doesn't yet handle are silently ignored
    /// so the server can ship new events without breaking old clients.
    private func dispatch(_ event: Psmith_V1_AccountEvent) {
        guard let kind = event.kind else { return }
        // Skip the echo of a mutation this client made. An empty origin means
        // nothing attributable caused it (a supervisor hook, a background
        // worker, an older server), and those must still be delivered.
        if !ownClientID.isEmpty, event.originClientID == ownClientID {
            return
        }
        switch kind {
        case .profileChanged(let payload):
            onProfileChanged?(payload.profileID)
        case .conversationChanged(let payload):
            onConversationChanged?(payload.conversationID)
        case .providerChanged(let payload):
            onProviderChanged?(payload.providerID)
        case .heartbeat:
            // Liveness only. Arriving at all is the entire contribution, and
            // it is also what tells us this server is new enough for the
            // watchdog's deadline to mean anything.
            frameClock.markHeartbeat()
        }
    }
}
