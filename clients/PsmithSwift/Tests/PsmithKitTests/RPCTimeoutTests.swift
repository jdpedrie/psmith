import Foundation
import Testing
@testable import PsmithKit

@Suite("withRPCTimeout")
struct RPCTimeoutTests {
    @Test("returns the operation's value when it completes before the deadline")
    func returnsValueWhenFastEnough() async throws {
        let result = try await withRPCTimeout(seconds: 1) {
            return 42
        }
        #expect(result == 42)
    }

    @Test("throws deadlineExceeded when the operation outruns the deadline")
    func throwsOnTimeout() async throws {
        do {
            _ = try await withRPCTimeout(seconds: 0.05) {
                try await Task.sleep(for: .seconds(2))
                return "should-not-reach"
            }
            Issue.record("expected timeout to throw")
        } catch let PsmithError.rpc(code, _) {
            #expect(code == .deadlineExceeded)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("propagates the operation's own error verbatim")
    func propagatesOperationError() async throws {
        enum CustomError: Error, Equatable { case boom }
        do {
            _ = try await withRPCTimeout(seconds: 5) {
                throw CustomError.boom
            }
            Issue.record("expected propagated error")
        } catch let e as CustomError {
            #expect(e == .boom)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("transport timeouts keep both failure modes out of reach")
    func transportTimeoutInvariants() {
        // Streaming must outlast the server's idle timer, or URLSession
        // tears down a thinking model's quiet stream before Terminal
        // arrives and the assistant turn vanishes client-side.
        #expect(RPCTimeouts.streamingRequest > RPCTimeouts.serverStreamIdleTimeout)

        // Unary must NOT inherit that window. It did, which is why an
        // unreachable host pinned every list/get for ten minutes with
        // no error surfaced ("spins forever"). Keep it an order of
        // magnitude tighter, and bound the whole transfer too.
        #expect(RPCTimeouts.unaryRequest < RPCTimeouts.streamingRequest / 10)
        #expect(RPCTimeouts.unaryResource <= RPCTimeouts.streamingRequest / 5)
        #expect(RPCTimeouts.unaryRequest <= RPCTimeouts.unaryResource)
    }
}
