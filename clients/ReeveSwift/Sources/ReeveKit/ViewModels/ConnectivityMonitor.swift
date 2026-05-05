import Foundation
import Observation

/// Reachability monitor for the configured reeved host. Polls
/// `GET /healthz` on a fixed interval; a 200 flips state to
/// `.online`, anything else (TCP refused, TLS fail, timeout, non-200)
/// flips it to `.offline`. UI surfaces (composer, error banners) read
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
///     no DB) so polling at 15s costs nothing.
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
    private let pollInterval: TimeInterval
    private let probeTimeout: TimeInterval
    private var task: Task<Void, Never>?

    public init(host: URL, pollInterval: TimeInterval = 15, probeTimeout: TimeInterval = 3) {
        self.host = host
        self.pollInterval = pollInterval
        self.probeTimeout = probeTimeout
    }

    /// Starts the polling loop. Idempotent — safe to call from
    /// multiple lifecycle hooks (e.g. scenePhase becoming active).
    /// First probe fires immediately so the UI doesn't sit in
    /// `.unknown` for 15 seconds on launch.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.probeOnce()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One-shot probe — useful at scenePhase = .active so the user
    /// sees a fresh signal the moment they bring the app to the
    /// foreground, without waiting for the next poll tick.
    public func probeNow() {
        Task { await probeOnce() }
    }

    private func probeOnce() async {
        let url = host.appendingPathComponent("healthz")
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: probeTimeout)
        req.httpMethod = "GET"
        let session = URLSession.shared
        do {
            let (_, resp) = try await session.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            self.state = ok ? .online : .offline
        } catch {
            self.state = .offline
        }
        self.lastProbeAt = Date()
    }
}
