import UIKit
import Observation

/// Wraps iOS's `UIApplication.beginBackgroundTask` so the StreamHub
/// gets ~30s of bonus background execution after the user backgrounds
/// the app, instead of being frozen immediately. The single most-common
/// scenario this helps: the user starts a long-thinking turn, swipes
/// to Home, and the answer materialises in the buffer before iOS
/// suspends the process — so when the user comes back the chain is
/// already up-to-date.
///
/// Past ~30s iOS fires `expirationHandler` and we release the token;
/// the app is then suspended and the hub's subscriber Tasks freeze. On
/// foreground the resilient subscriber's transparent retry resumes
/// from the last persisted sequence (server-side replay) — no
/// observable correctness loss, just the resume-roundtrip delay we
/// already had before Phase 1.
@MainActor
@Observable
final class BackgroundTaskKeeper {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    /// Ask iOS for extended background time. Idempotent — calling
    /// twice without an intervening `end()` is a no-op. Caller
    /// provides a name for Instruments / Console logs.
    func extend(name: String = "spalt-stream-hub") {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // System is about to forcibly suspend us — release the
            // token so iOS doesn't escalate to a kill.
            self?.end()
        }
    }

    /// Release the background-task token. Safe to call when no token
    /// is held.
    func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }

    /// True while a token is held. Useful for instrumentation /
    /// debug surfaces.
    var isHoldingToken: Bool { taskID != .invalid }
}
