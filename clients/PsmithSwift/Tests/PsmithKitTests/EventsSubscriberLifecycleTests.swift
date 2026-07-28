import Connect
import Foundation
import Testing

@testable import PsmithKit
import PsmithKitTestHarness

/// Repeated kicks must leave exactly one live subscriber.
///
/// `stop()` used to cancel the task and immediately nil it, so `start()` saw a
/// free slot and spawned a second subscriber while the first was still parked
/// in `for await stream.results()`. Every kick could leave another orphan, and
/// each orphan dispatches every event, multiplying the reloads the callbacks
/// fire. Heartbeats turned that from survivable into permanent: an orphan on a
/// live connection is fed forever instead of dying at the transport timeout.
@Suite("EventsSubscriberLifecycle", .serialized)
struct EventsSubscriberLifecycleTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    @Test("repeated kicks do not multiply event delivery")
    func kicksDoNotAccumulateSubscribers() async throws {
        let (client, user) = try await TestSession.freshUser(server: server, usernamePrefix: "evt-kick")
        // The mutation has to come from somewhere else. A client no longer
        // hears the echo of its own, so using this one as the probe would
        // measure suppression rather than subscriber count.
        let other = try await TestSession.secondClient(server: server, for: user)

        let deliveries = Counter()
        client.events.onProfileChanged = { _ in deliveries.bump() }
        client.events.start()

        // Let the first subscription establish before churning it.
        try await Task.sleep(for: .milliseconds(600))

        // Mac reconnects on every window focus, so this is not a synthetic
        // amount of churn.
        for _ in 0..<5 {
            client.events.kick()
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .milliseconds(600))

        deliveries.reset()

        // One mutation. One callback, however many kicks preceded it.
        var patch = Fixtures.minimalProfilePatch(name: "Kick Probe")
        patch.systemMessage = "probe"
        _ = try await other.profiles.create(patch)

        try await Task.sleep(for: .seconds(2))
        client.events.stop()

        let count = deliveries.value
        #expect(count >= 1, "the surviving subscriber should still deliver events")
        #expect(count <= 1, "each extra delivery is an orphaned subscriber doubling every reload; got \(count)")
    }
}

/// Thread-safe tally. The callbacks fire off the main actor.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func bump() {
        lock.lock()
        n += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        n = 0
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}
