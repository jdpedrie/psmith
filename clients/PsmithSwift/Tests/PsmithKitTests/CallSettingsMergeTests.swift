import XCTest
@testable import PsmithKit

/// Pure unit tests for the client-side CallSettings merge — must stay
/// in lockstep with `internal/profiles/callsettings.go`. These guard
/// the settings form's "Inherit (X)" previews: the merge feeds no
/// request, but a drift here shows users the wrong inherited values.
final class CallSettingsMergeTests: XCTestCase {

    func testScalarsHigherWins() {
        var higher = PsmithCallSettings()
        higher.temperature = 0.7
        higher.maxOutputTokens = 2048
        var lower = PsmithCallSettings()
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
        var higher = PsmithCallSettings()
        higher.stopSequences = ["STOP"]
        var lower = PsmithCallSettings()
        lower.stopSequences = ["END", "DONE"]

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.stopSequences, ["STOP"], "non-empty higher replaces, never concatenates")

        let inheritedOut = CallSettingsMerge.merge(higher: PsmithCallSettings(), lower: lower)
        XCTAssertEqual(inheritedOut.stopSequences, ["END", "DONE"], "empty higher inherits whole list")
    }

    func testThinkingNestedMerge() {
        // The case the old flat merge got wrong: profile sets only
        // `enabled`, model sets only `budgetTokens` — the resolved
        // preview must show BOTH.
        var higher = PsmithCallSettings()
        higher.thinking = PsmithThinkingSettings(enabled: true, budgetTokens: nil)
        var lower = PsmithCallSettings()
        lower.thinking = PsmithThinkingSettings(enabled: nil, budgetTokens: 8192)

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.thinking?.enabled, true)
        XCTAssertEqual(out.thinking?.budgetTokens, 8192, "unset nested field inherits through")
    }

    func testAnthropicNestedMerge() {
        var higher = PsmithCallSettings()
        higher.anthropic = PsmithAnthropicExtras(cacheEnabled: false, cacheTTL: nil)
        var lower = PsmithCallSettings()
        lower.anthropic = PsmithAnthropicExtras(cacheEnabled: true, cacheTTL: .oneHour)

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.anthropic?.cacheEnabled, false, "explicit false beats lower true")
        XCTAssertEqual(out.anthropic?.cacheTTL, .oneHour, "unset TTL inherits")
    }

    func testOpenAINestedMergeAndWholeFieldRules() {
        var higher = PsmithCallSettings()
        var ho = PsmithOpenAIExtras()
        ho.seed = 42
        ho.logitBias = [1: -5]
        higher.openai = ho

        var lower = PsmithCallSettings()
        var lo = PsmithOpenAIExtras()
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
        var higher = PsmithCallSettings()
        var hg = PsmithGoogleExtras()
        hg.safetySettings = PsmithSafetySettings(harassment: .blockNone)
        higher.google = hg

        var lower = PsmithCallSettings()
        var lg = PsmithGoogleExtras()
        lg.responseMimeType = "application/json"
        lg.safetySettings = PsmithSafetySettings(harassment: .blockOnlyHigh, hateSpeech: .blockMediumAndAbove)
        lower.google = lg

        let out = CallSettingsMerge.merge(higher: higher, lower: lower)
        XCTAssertEqual(out.google?.responseMimeType, "application/json")
        XCTAssertEqual(out.google?.safetySettings?.harassment, .blockNone, "higher threshold wins")
        XCTAssertEqual(out.google?.safetySettings?.hateSpeech, .blockMediumAndAbove, "unset threshold inherits")
    }

    func testNilBlocksPassThrough() {
        var lower = PsmithCallSettings()
        lower.thinking = PsmithThinkingSettings(enabled: true, budgetTokens: 1024)
        lower.google = {
            var g = PsmithGoogleExtras()
            g.candidateCount = 3
            return g
        }()

        let out = CallSettingsMerge.merge(higher: PsmithCallSettings(), lower: lower)
        XCTAssertEqual(out.thinking?.enabled, true)
        XCTAssertEqual(out.thinking?.budgetTokens, 1024)
        XCTAssertEqual(out.google?.candidateCount, 3)
    }

    func testThreeLayerChainAssociativity() {
        // conversation → profile → model, folded the way
        // prepareSettingsView folds them. Each layer contributes the
        // fields the others leave unset; conversation wins conflicts.
        var convo = PsmithCallSettings()
        convo.temperature = 1.0
        var profile = PsmithCallSettings()
        profile.temperature = 0.5
        profile.maxOutputTokens = 1000
        var model = PsmithCallSettings()
        model.maxOutputTokens = 9999
        model.topK = 25

        let resolvedBelow = CallSettingsMerge.merge(higher: profile, lower: model)
        let out = CallSettingsMerge.merge(higher: convo, lower: resolvedBelow)
        XCTAssertEqual(out.temperature, 1.0)
        XCTAssertEqual(out.maxOutputTokens, 1000)
        XCTAssertEqual(out.topK, 25)
    }
}
