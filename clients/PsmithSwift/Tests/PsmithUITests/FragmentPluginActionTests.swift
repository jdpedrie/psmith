import Testing

@testable import PsmithUI

/// The action grammar is the contract between a plugin and every client. If
/// parsing drifts, taps silently do nothing.
@Suite("FragmentPluginAction")
struct FragmentPluginActionTests {
    @Test("plugin actions parse with their params")
    func parsesPluginAction() {
        let parsed = FragmentActionParser.parse("plugin:arm?id=runbook")
        guard case .plugin(let action, let params) = parsed else {
            Issue.record("expected a plugin action, got \(String(describing: parsed))")
            return
        }
        #expect(action == "arm")
        #expect(params["id"] == "runbook")
    }

    @Test("an action with no params still parses")
    func parsesBareAction() {
        guard case .plugin(let action, let params) = FragmentActionParser.parse("plugin:refresh") else {
            Issue.record("expected a plugin action")
            return
        }
        #expect(action == "refresh")
        #expect(params.isEmpty)
    }

    @Test("the existing verbs are unaffected")
    func otherVerbsUnchanged() {
        #expect(FragmentActionParser.parse("compose:hi") == .compose("hi"))
        #expect(FragmentActionParser.parse("send:go") == .send("go"))
        #expect(FragmentActionParser.parse("plugin:") == nil)
        #expect(FragmentActionParser.parse("nonsense") == nil)
    }
}
