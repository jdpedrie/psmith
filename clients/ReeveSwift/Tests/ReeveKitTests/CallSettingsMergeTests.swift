import XCTest
@testable import ReeveKit

/// Pure unit tests for the client-side CallSettings merge — must stay
/// in lockstep with `internal/profiles/callsettings.go`. These guard
/// the settings form's "Inherit (X)" previews: the merge feeds no
/// request, but a drift here shows users the wrong inherited values.
final class CallSettingsMergeTests: XCTestCase {

    func testScalarsHigherWins() {
        var higher = ReeveCallSettings()
        higher.temperature = 0.7
        higher.maxOutputTokens = 2048
        var lower = ReeveCallSettings()
        lower.temperature = 0.2
        lower.topP = 0.9
        lower.maxOutputTokens = 4096
        lower.topK = 40
        lower.explicitCache = true

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.temperature, 0.7, "higher temperature wins")
        XCTAssertEqual(out.topP, 0.9, "unset topP inherits")
        XCTAssertEqual(out.maxOutputTokens, 2048, "higher maxOutputTokens wins")
        XCTAssertEqual(out.topK, 40, "unset topK inherits")
        XCTAssertEqual(out.explicitCache, true, "unset explicitCache inherits")
    }

    func testStopSequencesWholeFieldOverride() {
        var higher = ReeveCallSettings()
        higher.stopSequences = ["STOP"]
        var lower = ReeveCallSettings()
        lower.stopSequences = ["END", "DONE"]

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.stopSequences, ["STOP"], "non-empty higher replaces, never concatenates")

        let inheritedOut = CallSettingsMerge.merge(higher: ReeveCallSettings(), lower: lower)
        XCTAssertEqual(inheritedOut.stopSequences, ["END", "DONE"], "empty higher inherits whole list")
    }

    func testThinkingNestedMerge() {
        // The case the old flat merge got wrong: profile sets only
        // `enabled`, model sets only `budgetTokens` — the resolved
        // preview must show BOTH.
        var higher = ReeveCallSettings()
        higher.thinking = ReeveThinkingSettings(enabled: true, budgetTokens: nil)
        var lower = ReeveCallSettings()
        lower.thinking = ReeveThinkingSettings(enabled: nil, budgetTokens: 8192)

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.thinking?.enabled, true)
        XCTAssertEqual(out.thinking?.budgetTokens, 8192, "unset nested field inherits through")
    }

    func testAnthropicNestedMerge() {
        var higher = ReeveCallSettings()
        higher.anthropic = ReeveAnthropicExtras(cacheEnabled: false, cacheTTL: nil)
        var lower = ReeveCallSettings()
        lower.anthropic = ReeveAnthropicExtras(cacheEnabled: true, cacheTTL: .oneHour)

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.anthropic?.cacheEnabled, false, "explicit false beats lower true")
        XCTAssertEqual(out.anthropic?.cacheTTL, .oneHour, "unset TTL inherits")
    }

    func testOpenAINestedMergeAndWholeFieldRules() {
        var higher = ReeveCallSettings()
        var ho = ReeveOpenAIExtras()
        ho.seed = 42
        ho.logitBias = [1: -5]
        higher.openai = ho

        var lower = ReeveCallSettings()
        var lo = ReeveOpenAIExtras()
        lo.seed = 7
        lo.frequencyPenalty = 0.5
        lo.serviceTier = .priority
        lo.responseFormat = .jsonObject
        lo.logitBias = [2: 3, 4: 5]
        lower.openai = lo

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.openai?.seed, 42)
        XCTAssertEqual(out.openai?.frequencyPenalty, 0.5)
        XCTAssertEqual(out.openai?.serviceTier, .priority)
        XCTAssertEqual(out.openai?.responseFormat, .jsonObject, "unset oneof inherits whole")
        XCTAssertEqual(out.openai?.logitBias, [1: -5], "non-empty map replaces whole, no entry merge")
    }

    func testGoogleSafetyTwoLevelMerge() {
        var higher = ReeveCallSettings()
        var hg = ReeveGoogleExtras()
        hg.safetySettings = ReeveSafetySettings(harassment: .blockNone)
        higher.google = hg

        var lower = ReeveCallSettings()
        var lg = ReeveGoogleExtras()
        lg.responseMimeType = "application/json"
        lg.safetySettings = ReeveSafetySettings(harassment: .blockOnlyHigh, hateSpeech: .blockMediumAndAbove)
        lower.google = lg

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.google?.responseMimeType, "application/json")
        XCTAssertEqual(out.google?.safetySettings?.harassment, .blockNone, "higher threshold wins")
        XCTAssertEqual(out.google?.safetySettings?.hateSpeech, .blockMediumAndAbove, "unset threshold inherits")
    }

    func testNilBlocksPassThrough() {
        var lower = ReeveCallSettings()
        lower.thinking = ReeveThinkingSettings(enabled: true, budgetTokens: 1024)
        lower.google = {
            var g = ReeveGoogleExtras()
            g.candidateCount = 3
            return g
        }()

        let out = CallSettingsMerge.merge(higher: ReeveCallSettings(), lower: lower)
        XCTAssertEqual(out.thinking?.enabled, true)
        XCTAssertEqual(out.thinking?.budgetTokens, 1024)
        XCTAssertEqual(out.google?.candidateCount, 3)
    }

    func testThreeLayerChainAssociativity() {
        // conversation → profile → model, folded the way
        // prepareSettingsView folds them. Each layer contributes the
        // fields the others leave unset; conversation wins conflicts.
        var convo = ReeveCallSettings()
        convo.temperature = 1.0
        var profile = ReeveCallSettings()
        profile.temperature = 0.5
        profile.maxOutputTokens = 1000
        var model = ReeveCallSettings()
        model.maxOutputTokens = 9999
        model.topK = 25

        let resolvedBelow = CallSettingsMerge.merge(higher: profile, lower: model)
        let out = CallSettingsMerge.merge(higher: convo, lower: resolvedBelow)
        XCTAssertEqual(out.temperature, 1.0)
        XCTAssertEqual(out.maxOutputTokens, 1000)
        XCTAssertEqual(out.topK, 25)
    }
}
