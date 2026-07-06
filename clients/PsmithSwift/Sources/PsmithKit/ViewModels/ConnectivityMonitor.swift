import Foundation
import Observation

/// Reachability monitor for the configured psmithd host. Polls
/// `GET /healthz` on a cadence; a 200 flips state to `.online`,
/// anything else (TCP refused, TLS fail, timeout, non-200) flips
/// it to `.offline`. UI surfaces (composer, error banners) read
/// `state` and disable Send / show banners accordingly.
///
/// Why a poll instead of waiting on RPC failures alone:
///   - Users notice "server is down" the moment they open the app,
///     not at the moment of their first failed Send.
///   - SSE stream subscribes are long-lived; their failure mode is a
///     dropped connection mid-stream, which we don't want to count
///     as "server is down" (could be a flap). The dedicated probe
///     is a single, predictable signal.
///   - The probe is intentionally cheap on the server side (no auth,
///     no DB) so polling at the steady cadence costs nothing.
///
/// Cadence is dynamic: when the OutboundQueue has pending entries
/// AND we're offline, the interval shrinks to an exponential
/// backoff starting at 1s and capped at 60s — we want a queued
/// message to fire the moment connectivity comes back, not wait
/// up to 15s for the steady poll. Backoff resets on online OR
/// on the queue emptying.
@Observable
@MainActor
public final class ConnectivityMonitor {
    public enum State: Sendable, Equatable {
        case unknown
        case online
        case offline
    }

    public private(set) var state: State = .unknown

    /// Wall-clock the most recent probe completed. Surfaced so the
    /// settings UI can render "Last seen 12s ago" when offline.
    public private(set) var lastProbeAt: Date?

    private let host: URL
    private let steadyInterval: TimeInterval
    private let probeTimeout: TimeInterval
    private let queue: OutboundQueue?
    private var task: Task<Void, Never>?
    /// Current backoff exponent — incremented on each offline
    /// probe while the queue has entries; reset to 0 on online or
    /// queue-empty. The actual sleep is min(2^n, capSeconds).
    private var backoffExponent: Int = 0
    private let backoffCapSeconds: TimeInterval = 60
    private let backoffStartSeconds: TimeInterval = 1
    private var onOnlineCallbacks: [@MainActor () async -> Void] = []
    /// Notification observer token for the OutboundQueue
    /// "did change" notification. Kept so we can de-register on
    /// stop() and reset on `init`.
    private var queueObserver: NSObjectProtocol?

    public init(
        host: URL,
        queue: OutboundQueue? = nil,
        pollInterval: TimeInterval = 15,
        probeTimeout: TimeInterval = 3
    ) {
        self.host = host
        self.queue = queue
        self.steadyInterval = pollInterval
        self.probeTimeout = probeTimeout
        // When the queue gains entries while we're offline, the
        // existing sleep cycle is between probes — don't wait it
        // out. A fresh probe via `probeNow()` either flips state
        // to online (firing onOnline + drain) or returns offline
        // (loop will then pick the backoff cadence on its next
        // sleep). Either way it's at most one extra probe and the
        // user gets near-instant feedback.
        if queue != nil {
            queueObserver = NotificationCenter.default.addObserver(
                forName: OutboundQueue.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.probeNow() }
            }
        }
    }

    // No deinit cleanup: this is a process-singleton wrapper
    // owned by AppModel, which lives for the lifetime of the
    // app. The notification observer is implicitly torn down
    // when the process exits, so the @MainActor-isolated
    // `queueObserver` doesn't need to be touched from a
    // non-isolated `deinit`.

    /// Register a closure that fires after every flip to
    /// `.online` (including the first probe of a session if it
    /// reports online). Drains-on-reconnect are wired this way so
    /// ConnectivityMonitor doesn't need a PsmithClient reference.
    public func onOnline(_ block: @escaping @MainActor () async -> Void) {
        onOnlineCallbacks.append(block)
    }

    /// Starts the polling loop. Idempotent — safe to call from
    /// multiple lifecycle hooks (e.g. scenePhase becoming active).
    /// First probe fires immediately so the UI doesn't sit in
    /// `.unknown` for the steady interval on launch.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.probeOnce()
                let nanos = await UInt64(self.nextSleepSeconds() * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One-shot probe — useful at scenePhase = .active so the user
    /// sees a fresh signal the moment they bring the app to the
    /// foreground, without waiting for the next poll tick. Also
    /// fired by the OutboundQueue notification observer so the
    /// faster backoff cadence kicks in immediately on a fresh
    /// enqueue.
    public func probeNow() {
        Task { await probeOnce() }
    }

    private func probeOnce() async {
        let url = host.appendingPathComponent("healthz")
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: probeTimeout)
        req.httpMethod = "GET"
        let session = URLSession.shared
        let priorState = state
        do {
            let (_, resp) = try await session.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            self.state = ok ? .online : .offline
        } catch {
            self.state = .offline
        }
        self.lastProbeAt = Date()
        if state == .online, priorState != .online {
            backoffExponent = 0
            for block in onOnlineCallbacks {
                await block()
            }
        }
    }

    /// Decide the next sleep length based on online/offline +
    /// queue depth. When offline AND queue non-empty: backoff
    /// 1s, 2s, 4s, … capped at 60s. Otherwise: steady interval.
    private func nextSleepSeconds() -> TimeInterval {
        guard let queue, !queue.isEmpty, state == .offline else {
            backoffExponent = 0
            return steadyInterval
        }
        let secs = min(backoffStartSeconds * pow(2, Double(backoffExponent)), backoffCapSeconds)
        backoffExponent += 1
        return secs
    }
}
