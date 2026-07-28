import Connect
import Foundation
import Testing

@testable import PsmithKit
import PsmithKitTestHarness

/// A client must not react to the events its own mutations produced.
///
/// Every mutation fans out to every subscriber for the user, the originator
/// included. On receipt a client refreshes its conversation list and runs
/// staleness checks, so a send or an edit paid for a round trip to learn
/// something it already knew, landing on the main actor while the user was
/// still interacting. That was invisible while the events stream kept dying;
/// fixing the connection made the app do the work it had been dropping.
@Suite("EventEchoSuppression", .serialized)
struct EventEchoSuppressionTests {
    let server: TestPsmithdServer

    init() throws {
        self.server = try TestPsmithdServer.shared()
    }

    @Test("a client ignores the echo of its own mutation")
    func ownMutationIsSuppressed() async throws {
        let (client, _) = try await TestSession.freshUser(server: server, usernamePrefix: "echo-self")

        let seen = Counter()
        client.events.onProfileChanged = { _ in seen.bump() }
        client.events.start()
        defer { client.events.stop() }
        try await Task.sleep(for: .milliseconds(700))
        seen.reset()

        _ = try await client.profiles.create(Fixtures.minimalProfilePatch(name: "Mine"))
        try await Task.sleep(for: .seconds(2))

        #expect(seen.value == 0, "the originating client reacted to its own mutation \(seen.value) time(s)")
    }

    @Test("another client still hears the change")
    func otherClientsStillNotified() async throws {
        // Suppression must be scoped to the originator. Dropping the event for
        // everyone would break cross-device sync, which is the entire point of
        // the events stream.
        let (writer, user) = try await TestSession.freshUser(server: server, usernamePrefix: "echo-writer")
        let reader = try await TestSession.secondClient(server: server, for: user)

        let seen = Counter()
        reader.events.onProfileChanged = { _ in seen.bump() }
        reader.events.start()
        defer { reader.events.stop() }
        try await Task.sleep(for: .milliseconds(700))
        seen.reset()

        _ = try await writer.profiles.create(Fixtures.minimalProfilePatch(name: "Theirs"))
        try await Task.sleep(for: .seconds(2))

        #expect(seen.value >= 1, "a second client on the same account must still be told")
    }

    @Test("each client instance gets a distinct id")
    func idsAreDistinctPerInstance() async throws {
        let (a, user) = try await TestSession.freshUser(server: server, usernamePrefix: "echo-ids")
        let b = try await TestSession.secondClient(server: server, for: user)

        #expect(!a.clientID.isEmpty)
        #expect(a.clientID != b.clientID, "two clients sharing an id would suppress each other's events")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    func reset() { lock.lock(); n = 0; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
