import Foundation
import Testing
@testable import SpaltKit

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
        } catch let SpaltError.rpc(code, _) {
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
}
