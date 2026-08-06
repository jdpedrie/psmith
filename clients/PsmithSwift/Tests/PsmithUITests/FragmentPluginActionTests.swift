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

/// `card_list` gained a per-item `action` so a card list can be a picker, not
/// just a display. Without it a plugin panel renders rows the user cannot tap,
/// which is how context_packs first shipped: the panel looked right and did
/// nothing.
@Suite("CardListAction")
struct CardListActionTests {
    @Test("an item action parses into a dispatchable fragment action")
    func itemActionParses() {
        guard case .plugin(let action, let params) =
            FragmentActionParser.parse("plugin:arm?id=runbook")
        else {
            Issue.record("card actions must parse with the same grammar as any other")
            return
        }
        #expect(action == "arm")
        #expect(params["id"] == "runbook")
    }

    @Test("a card with no action stays inert")
    func absentActionIsInert() {
        // How a plugin says "nothing left to do here" — a delivered pack —
        // without the renderer needing to know what that means.
        #expect(FragmentActionParser.parse("") == nil)
    }
}
