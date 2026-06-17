import Foundation
import Testing
@testable import SpaltKit

/// Pure-unit coverage for the tool-call chunk plumbing — payload parsers
/// on `SpaltChunk` and the phase state machine on `LiveToolCall`. The
/// end-to-end "real chunks flow through ConversationViewModel" path is
/// validated by `cmd/tool-e2e`; here we exercise the boundary cases that
/// are awkward to provoke against a real provider.

@Suite("Tool-call chunk plumbing")
struct ToolCallChunkTests {
    // MARK: - SpaltChunk payload parsers

    @Test
    func toolUseStartParse() {
        let payload = #"{"id":"call-1","name":"web_search","provider_opaque":"abc"}"#.data(using: .utf8)!
        let chunk = SpaltChunk(sequence: 0, type: .toolUseStart, payload: payload)
        let info = chunk.toolUseStartInfo
        #expect(info?.id == "call-1")
        #expect(info?.name == "web_search")
        #expect(info?.providerOpaque == "abc")
    }

    @Test
    func toolUseStartParseWithoutOpaque() {
        let payload = #"{"id":"call-2","name":"web_search"}"#.data(using: .utf8)!
        let chunk = SpaltChunk(sequence: 0, type: .toolUseStart, payload: payload)
        let info = chunk.toolUseStartInfo
        #expect(info?.providerOpaque == nil)
    }

    @Test
    func toolUseStartReturnsNilForWrongType() {
        let chunk = SpaltChunk(sequence: 0, type: .textDelta, payload: Data())
        #expect(chunk.toolUseStartInfo == nil)
    }

    @Test
    func toolUseDeltaParse() {
        let payload = #"{"partial_json":"{\"q\":\"hi\"}"}"#.data(using: .utf8)!
        let chunk = SpaltChunk(sequence: 0, type: .toolUseDelta, payload: payload)
        #expect(chunk.toolUseDeltaPartialJSON == #"{"q":"hi"}"#)
    }

    @Test
    func toolResultParse() {
        let payload = #"{"tool_use_id":"call-1","output":{"hits":3},"error":"","elapsed_ms":412}"#
            .data(using: .utf8)!
        let chunk = SpaltChunk(sequence: 0, type: .toolResult, payload: payload)
        let info = chunk.toolResultInfo
        #expect(info?.toolUseID == "call-1")
        #expect(info?.elapsedMs == 412)
        #expect(info?.error == nil) // empty string normalised to nil
        // Output round-trips back to a JSON object.
        let parsed = try? JSONSerialization.jsonObject(with: info?.output ?? Data()) as? [String: Any]
        #expect(parsed?["hits"] as? Int == 3)
    }

    @Test
    func toolResultErrorParse() {
        let payload = #"{"tool_use_id":"call-1","output":null,"error":"upstream 500","elapsed_ms":200}"#
            .data(using: .utf8)!
        let chunk = SpaltChunk(sequence: 0, type: .toolResult, payload: payload)
        let info = chunk.toolResultInfo
        #expect(info?.error == "upstream 500")
        #expect(info?.output.isEmpty == true)
    }

    // MARK: - LiveToolCall.phase

    @Test
    func phaseGenerating() {
        let call = LiveToolCall(id: "x", name: "n", startedAt: Date())
        if case .generating = call.phase {} else {
            Issue.record("expected .generating, got \(call.phase)")
        }
    }

    @Test
    func phaseExecutingAfterArgsEnd() {
        var call = LiveToolCall(id: "x", name: "n", startedAt: Date())
        call.argsCompletedAt = Date()
        if case .executing = call.phase {} else {
            Issue.record("expected .executing, got \(call.phase)")
        }
    }

    @Test
    func phaseDoneOnResultPrefersServerElapsed() {
        let started = Date()
        let argsDone = started.addingTimeInterval(0.5)
        var call = LiveToolCall(id: "x", name: "n", startedAt: started)
        call.argsCompletedAt = argsDone
        // result arrived 1s after argsDone; server reports 412ms — server wins
        call.resultArrivedAt = argsDone.addingTimeInterval(1.0)
        call.elapsedMs = 412
        if case let .done(dur, hasError) = call.phase {
            #expect(abs(dur - 0.412) < 0.001)
            #expect(hasError == false)
        } else {
            Issue.record("expected .done")
        }
    }

    @Test
    func phaseDoneFlagsError() {
        var call = LiveToolCall(id: "x", name: "n", startedAt: Date())
        call.argsCompletedAt = Date()
        call.resultArrivedAt = Date()
        call.error = "upstream 500"
        call.elapsedMs = 100
        if case let .done(_, hasError) = call.phase {
            #expect(hasError == true)
        } else {
            Issue.record("expected .done")
        }
    }
}
