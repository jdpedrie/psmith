import Foundation

/// Race `operation` against a sleep; whichever finishes first wins.
/// On timeout, throws a `ReeveError.rpc(.deadlineExceeded, …)` so
/// callers can catch + fall back (typically: read from local cache
/// instead of wedging on the URLSession default of ~60s).
///
/// Used by repository calls that fire at app launch — when the
/// server is unreachable, the default URLSession timeout pins the
/// UI on a launch spinner for over a minute. Bounding launch RPCs
/// to single-digit seconds lets the cached path drop the spinner
/// almost immediately, and the connectivity monitor's banner tells
/// the user why the list isn't refreshing.
///
/// Cancellation: when the timeout branch fires first, the
/// `operation` task is cancelled via `group.cancelAll()`. Most
/// Connect-Swift calls eventually observe cancellation and abort
/// their URLSession data task; in the worst case the URLSession
/// runs to completion in the background and its result is dropped.
/// Either way the caller is unblocked at the deadline.
@Sendable
func withRPCTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ReeveError.rpc(
                code: .deadlineExceeded,
                message: "operation timed out after \(Int(seconds))s"
            )
        }
        defer { group.cancelAll() }
        // First completion wins. `group.next()` on a non-empty group
        // never returns nil, so the force-unwrap is safe.
        return try await group.next()!
    }
}
