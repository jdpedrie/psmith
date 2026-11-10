import Foundation
import Testing
@testable import PsmithKit

@Suite("Elicit chunk")
struct ElicitChunkTests {
    @Test
    func namesWhoIsAsking() {
        let payload = #"{"elicitation_id":"e1","message":"Which repo?","requested_schema":{},"source":"GitHub","tool":"create_issue"}"#
        let info = PsmithChunk(sequence: 0, type: .elicit, payload: Data(payload.utf8)).elicitInfo
        #expect(info?.source == "GitHub")
        #expect(info?.tool == "create_issue")
        let pending = StreamHub.PendingElicit(id: "e1", message: "Which repo?", schemaJSON: Data(),
                                              source: info?.source, tool: info?.tool)
        #expect(pending.title == "GitHub needs input")
    }

    @Test
    func fallsBackToPsmithWithoutASource() {
        let payload = #"{"elicitation_id":"e1","message":"?","requested_schema":{},"source":""}"#
        let info = PsmithChunk(sequence: 0, type: .elicit, payload: Data(payload.utf8)).elicitInfo
        #expect(info?.source == nil)
        #expect(StreamHub.PendingElicit(id: "e1", message: "?", schemaJSON: Data()).title == "Psmith needs input")
    }
}
