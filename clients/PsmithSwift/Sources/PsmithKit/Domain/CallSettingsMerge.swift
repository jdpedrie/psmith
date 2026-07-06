import Foundation

/// Client-side mirror of the server's `MergeCallSettings`
/// (`internal/profiles/callsettings.go`). Overlays `higher` on `lower`:
/// every scalar is `higher.field ?? lower.field`; repeated/map fields
/// (`stopSequences`, `logitBias`) and the `responseFormat` oneof are
/// whole-field overrides; nested blocks (`thinking`, `anthropic`,
/// `openai`, `google`, and `google.safetySettings`) recurse so a layer
/// that sets only part of a block lets the rest inherit.
///
/// Used by the settings UIs to render "Inherit (X)" previews that match
/// what the server will actually resolve at SendMessage time. The
/// server re-resolves authoritatively per send — this never feeds a
/// request directly, so a drift here shows wrong hints, not wrong calls.
/// Keep in lockstep with the Go merge; the unit tests mirror the Go
/// test cases.
public enum CallSettingsMerge {
    public static func merge(higher: PsmithCallSettings, lower: PsmithCallSettings) -> PsmithCallSettings {
        var out = higher
        if out.temperature == nil      { out.temperature = lower.temperature }
        if out.topP == nil             { out.topP = lower.topP }
        if out.maxOutputTokens == nil  { out.maxOutputTokens = lower.maxOutputTokens }
        if out.stopSequences.isEmpty   { out.stopSequences = lower.stopSequences }
        if out.topK == nil             { out.topK = lower.topK }
        if out.explicitCache == nil    { out.explicitCache = lower.explicitCache }
        out.thinking  = mergeThinking(out.thinking, lower.thinking)
        out.anthropic = mergeAnthropic(out.anthropic, lower.anthropic)
        out.openai    = mergeOpenAI(out.openai, lower.openai)
        out.google    = mergeGoogle(out.google, lower.google)
        return out
    }

    static func mergeThinking(_ higher: PsmithThinkingSettings?, _ lower: PsmithThinkingSettings?) -> PsmithThinkingSettings? {
        guard var out = higher else { return lower }
        guard let lower else { return out }
        if out.enabled == nil      { out.enabled = lower.enabled }
        if out.budgetTokens == nil { out.budgetTokens = lower.budgetTokens }
        return out
    }

    static func mergeAnthropic(_ higher: PsmithAnthropicExtras?, _ lower: PsmithAnthropicExtras?) -> PsmithAnthropicExtras? {
        guard var out = higher else { return lower }
        guard let lower else { return out }
        if out.cacheEnabled == nil { out.cacheEnabled = lower.cacheEnabled }
        if out.cacheTTL == nil     { out.cacheTTL = lower.cacheTTL }
        return out
    }

    static func mergeOpenAI(_ higher: PsmithOpenAIExtras?, _ lower: PsmithOpenAIExtras?) -> PsmithOpenAIExtras? {
        guard var out = higher else { return lower }
        guard let lower else { return out }
        if out.seed == nil              { out.seed = lower.seed }
        if out.frequencyPenalty == nil  { out.frequencyPenalty = lower.frequencyPenalty }
        if out.presencePenalty == nil   { out.presencePenalty = lower.presencePenalty }
        if out.topLogprobs == nil       { out.topLogprobs = lower.topLogprobs }
        if out.parallelToolCalls == nil { out.parallelToolCalls = lower.parallelToolCalls }
        if out.serviceTier == nil       { out.serviceTier = lower.serviceTier }
        // response_format is a oneof — whole-field override, no partial
        // merge (text/json_object/json_schema are exclusive shapes).
        if out.responseFormat == nil    { out.responseFormat = lower.responseFormat }
        // logit_bias is a map — whole-field replacement, no entry merge.
        if out.logitBias.isEmpty        { out.logitBias = lower.logitBias }
        return out
    }

    static func mergeGoogle(_ higher: PsmithGoogleExtras?, _ lower: PsmithGoogleExtras?) -> PsmithGoogleExtras? {
        guard var out = higher else { return lower }
        guard let lower else { return out }
        if out.responseMimeType == nil { out.responseMimeType = lower.responseMimeType }
        if out.candidateCount == nil   { out.candidateCount = lower.candidateCount }
        if out.responseSchema == nil   { out.responseSchema = lower.responseSchema }
        out.safetySettings = mergeSafety(out.safetySettings, lower.safetySettings)
        return out
    }

    static func mergeSafety(_ higher: PsmithSafetySettings?, _ lower: PsmithSafetySettings?) -> PsmithSafetySettings? {
        guard var out = higher else { return lower }
        guard let lower else { return out }
        if out.harassment == nil       { out.harassment = lower.harassment }
        if out.hateSpeech == nil       { out.hateSpeech = lower.hateSpeech }
        if out.sexuallyExplicit == nil { out.sexuallyExplicit = lower.sexuallyExplicit }
        if out.dangerousContent == nil { out.dangerousContent = lower.dangerousContent }
        return out
    }
}
