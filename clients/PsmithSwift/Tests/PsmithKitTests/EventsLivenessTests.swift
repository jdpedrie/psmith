import Foundation
import Testing

@testable import PsmithKit

/// The events-stream liveness watchdog decides when a quiet connection is
/// actually dead. Getting that wrong in either direction is expensive: too
/// eager and it churns a healthy connection, too lax and the app sits
/// receiving nothing for ten minutes.
@Suite("EventsLiveness")
struct EventsLivenessTests {

    @Test("the deadline does not apply until a heartbeat has been seen")
    func deadlineRequiresAHeartbeat() {
        let clock = EventsSubscriber.FrameClock()

        // A server too old to heartbeat is not broken, just quiet. Enforcing a
        // deadline against it tears the stream down every interval forever,
        // which is worse than the problem the watchdog exists to solve.
        #expect(clock.liveness().deadlineApplies == false)

        clock.mark()
        #expect(clock.liveness().deadlineApplies == false, "an ordinary frame is not proof of heartbeat support")

        clock.markHeartbeat()
        #expect(clock.liveness().deadlineApplies == true)
    }

    @Test("any frame resets the quiet timer")
    func framesResetQuietTimer() async throws {
        let clock = EventsSubscriber.FrameClock()
        clock.markHeartbeat()

        try await Task.sleep(for: .milliseconds(30))
        let beforeMark = clock.liveness().quietFor
        #expect(beforeMark > .milliseconds(20))

        clock.mark()
        let afterMark = clock.liveness().quietFor
        #expect(afterMark < beforeMark, "a real event should count as liveness, not just heartbeats")
    }

    @Test("reset clears heartbeat support for the next connection")
    func resetIsPerConnection() {
        let clock = EventsSubscriber.FrameClock()
        clock.markHeartbeat()
        #expect(clock.liveness().deadlineApplies == true)

        // Reconnecting may land on a different server, so support has to be
        // re-established rather than assumed from the previous connection.
        clock.reset()
        #expect(clock.liveness().deadlineApplies == false)
    }
}
