import Foundation
import Testing
import Connect
@testable import PsmithKit

/// `PsmithError.display(_:)` is the gold-standard normaliser used by every
/// catch-block on the iOS / Mac clients. These tests pin down the
/// per-shape behaviour so the UI never surfaces a raw JSON blob.
@Suite("PsmithError.display")
struct PsmithErrorDisplayTests {

    @Test("RPC envelope with nested message")
    func nestedEnvelope() {
        let err = PsmithError.rpc(
            code: .internalError,
            message: #"{"error":{"message":"rate limit exceeded","type":"x"}}"#
        )
        #expect(PsmithError.display(err) == "Server error: rate limit exceeded")
    }

    @Test("RPC envelope with bare error string")
    func bareErrorString() {
        let err = PsmithError.rpc(
            code: .unavailable,
            message: #"{"error":"connection refused"}"#
        )
        #expect(PsmithError.display(err) == "Server unreachable: connection refused")
    }

    @Test("RPC with top-level message field")
    func topLevelMessage() {
        let err = PsmithError.rpc(
            code: .invalidArgument,
            message: #"{"message":"missing field foo"}"#
        )
        #expect(PsmithError.display(err) == "Invalid request: missing field foo")
    }

    @Test("RPC with GraphQL-style errors array")
    func errorsArray() {
        let err = PsmithError.rpc(
            code: .internalError,
            message: #"{"errors":[{"message":"bad query"}]}"#
        )
        #expect(PsmithError.display(err) == "Server error: bad query")
    }

    @Test("RPC with FastAPI detail")
    func fastAPIDetail() {
        let err = PsmithError.rpc(
            code: .failedPrecondition,
            message: #"{"detail":"validation failed"}"#
        )
        #expect(PsmithError.display(err) == "Couldn't complete: validation failed")
    }

    @Test("RPC with OAuth-style error_description")
    func oauthDescription() {
        let err = PsmithError.rpc(
            code: .unauthenticated,
            message: #"{"error_description":"invalid token"}"#
        )
        #expect(PsmithError.display(err) == "Not signed in: invalid token")
    }

    @Test("RPC with prefix + embedded JSON")
    func prefixedEnvelope() {
        let err = PsmithError.rpc(
            code: .internalError,
            message: #"upstream call failed: {"error":{"message":"504 gateway timeout"}}"#
        )
        let got = PsmithError.display(err)
        // Prefix preserved + extracted message appended.
        #expect(got.contains("504 gateway timeout"))
        #expect(got.contains("upstream call failed"))
    }

    @Test("RPC with plain text message")
    func plainText() {
        let err = PsmithError.rpc(code: .deadlineExceeded, message: "request took too long")
        #expect(PsmithError.display(err) == "Request timed out: request took too long")
    }

    @Test("RPC with empty message uses friendly label")
    func emptyMessage() {
        let err = PsmithError.rpc(code: .unavailable, message: "")
        #expect(PsmithError.display(err) == "Server unreachable")
    }

    @Test("missingPayload reads as a sentence")
    func missingPayload() {
        let err = PsmithError.missingPayload("conversation")
        #expect(PsmithError.display(err) == "Missing field in server response: conversation")
    }

    @Test("non-PsmithError uses localizedDescription via normalisation")
    func nsErrorPath() {
        let err = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: #"{"error":{"message":"wrapped"}}"#]
        )
        #expect(PsmithError.display(err) == "wrapped")
    }

    @Test("never returns empty for non-nil error")
    func neverEmpty() {
        let err = NSError(domain: "", code: 0, userInfo: nil)
        let s = PsmithError.display(err)
        #expect(!s.isEmpty)
    }
}
