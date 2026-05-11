import Foundation
import Testing
import Connect
@testable import ReeveKit

/// `ReeveError.display(_:)` is the gold-standard normaliser used by every
/// catch-block on the iOS / Mac clients. These tests pin down the
/// per-shape behaviour so the UI never surfaces a raw JSON blob.
@Suite("ReeveError.display")
struct ReeveErrorDisplayTests {

    @Test("RPC envelope with nested message")
    func nestedEnvelope() {
        let err = ReeveError.rpc(
            code: .internalError,
            message: #"{"error":{"message":"rate limit exceeded","type":"x"}}"#
        )
        #expect(ReeveError.display(err) == "Server error: rate limit exceeded")
    }

    @Test("RPC envelope with bare error string")
    func bareErrorString() {
        let err = ReeveError.rpc(
            code: .unavailable,
            message: #"{"error":"connection refused"}"#
        )
        #expect(ReeveError.display(err) == "Server unreachable: connection refused")
    }

    @Test("RPC with top-level message field")
    func topLevelMessage() {
        let err = ReeveError.rpc(
            code: .invalidArgument,
            message: #"{"message":"missing field foo"}"#
        )
        #expect(ReeveError.display(err) == "Invalid request: missing field foo")
    }

    @Test("RPC with GraphQL-style errors array")
    func errorsArray() {
        let err = ReeveError.rpc(
            code: .internalError,
            message: #"{"errors":[{"message":"bad query"}]}"#
        )
        #expect(ReeveError.display(err) == "Server error: bad query")
    }

    @Test("RPC with FastAPI detail")
    func fastAPIDetail() {
        let err = ReeveError.rpc(
            code: .failedPrecondition,
            message: #"{"detail":"validation failed"}"#
        )
        #expect(ReeveError.display(err) == "Couldn't complete: validation failed")
    }

    @Test("RPC with OAuth-style error_description")
    func oauthDescription() {
        let err = ReeveError.rpc(
            code: .unauthenticated,
            message: #"{"error_description":"invalid token"}"#
        )
        #expect(ReeveError.display(err) == "Not signed in: invalid token")
    }

    @Test("RPC with prefix + embedded JSON")
    func prefixedEnvelope() {
        let err = ReeveError.rpc(
            code: .internalError,
            message: #"upstream call failed: {"error":{"message":"504 gateway timeout"}}"#
        )
        let got = ReeveError.display(err)
        // Prefix preserved + extracted message appended.
        #expect(got.contains("504 gateway timeout"))
        #expect(got.contains("upstream call failed"))
    }

    @Test("RPC with plain text message")
    func plainText() {
        let err = ReeveError.rpc(code: .deadlineExceeded, message: "request took too long")
        #expect(ReeveError.display(err) == "Request timed out: request took too long")
    }

    @Test("RPC with empty message uses friendly label")
    func emptyMessage() {
        let err = ReeveError.rpc(code: .unavailable, message: "")
        #expect(ReeveError.display(err) == "Server unreachable")
    }

    @Test("missingPayload reads as a sentence")
    func missingPayload() {
        let err = ReeveError.missingPayload("conversation")
        #expect(ReeveError.display(err) == "Missing field in server response: conversation")
    }

    @Test("non-ReeveError uses localizedDescription via normalisation")
    func nsErrorPath() {
        let err = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: #"{"error":{"message":"wrapped"}}"#]
        )
        #expect(ReeveError.display(err) == "wrapped")
    }

    @Test("never returns empty for non-nil error")
    func neverEmpty() {
        let err = NSError(domain: "", code: 0, userInfo: nil)
        let s = ReeveError.display(err)
        #expect(!s.isEmpty)
    }
}
