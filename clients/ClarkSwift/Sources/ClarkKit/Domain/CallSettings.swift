import Foundation

// MARK: - CallSettings (universal common-core)

/// Cross-driver per-call settings. Hybrid common-core + provider-specific
/// shape that mirrors `Clark_V1_CallSettings`:
///   * The first block is universal (every driver translates it).
///   * `topK` is shared by Anthropic + Google.
///   * `thinking` is the universal "extended reasoning" knob translated
///     per driver.
///   * `anthropic` / `openai` / `google` carry per-provider knobs.
///
/// All fields are nullable / `nil`-defaulted — every layer can leave any
/// field unset to inherit from the layer below in the resolution chain.
public struct ClarkCallSettings: Sendable, Hashable {
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int32?
    public var stopSequences: [String]
    public var topK: Int32?
    public var thinking: ClarkThinkingSettings?
    public var anthropic: ClarkAnthropicExtras?
    public var openai: ClarkOpenAIExtras?
    public var google: ClarkGoogleExtras?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int32? = nil,
        stopSequences: [String] = [],
        topK: Int32? = nil,
        thinking: ClarkThinkingSettings? = nil,
        anthropic: ClarkAnthropicExtras? = nil,
        openai: ClarkOpenAIExtras? = nil,
        google: ClarkGoogleExtras? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.stopSequences = stopSequences
        self.topK = topK
        self.thinking = thinking
        self.anthropic = anthropic
        self.openai = openai
        self.google = google
    }

    /// True when every field is unset / empty. Callers pass `nil` (rather
    /// than the empty struct) to the proto so the column stays NULL.
    public var isEmpty: Bool {
        temperature == nil
            && topP == nil
            && maxOutputTokens == nil
            && stopSequences.isEmpty
            && topK == nil
            && (thinking?.isEmpty ?? true)
            && (anthropic?.isEmpty ?? true)
            && (openai?.isEmpty ?? true)
            && (google?.isEmpty ?? true)
    }
}

extension ClarkCallSettings {
    /// Round-trip from the proto into the domain struct. Every "unset"
    /// proto optional becomes a Swift `nil`; sub-messages recurse and
    /// collapse to `nil` when wholly empty.
    public init(from p: Clark_V1_CallSettings) {
        self.init(
            temperature:     p.hasTemperature     ? p.temperature     : nil,
            topP:            p.hasTopP            ? p.topP            : nil,
            maxOutputTokens: p.hasMaxOutputTokens ? p.maxOutputTokens : nil,
            stopSequences:   p.stopSequences,
            topK:            p.hasTopK            ? p.topK            : nil,
            thinking:  p.hasThinking  ? ClarkThinkingSettings(from: p.thinking)   : nil,
            anthropic: p.hasAnthropic ? ClarkAnthropicExtras(from: p.anthropic)   : nil,
            openai:    p.hasOpenai    ? ClarkOpenAIExtras(from: p.openai)         : nil,
            google:    p.hasGoogle    ? ClarkGoogleExtras(from: p.google)         : nil
        )
    }

    /// Lossless export to the proto shape. Every field is sparsely set —
    /// only writes the proto presence flag when the Swift field is non-nil.
    public var proto: Clark_V1_CallSettings {
        var s = Clark_V1_CallSettings()
        if let v = temperature     { s.temperature     = v }
        if let v = topP            { s.topP            = v }
        if let v = maxOutputTokens { s.maxOutputTokens = v }
        if !stopSequences.isEmpty  { s.stopSequences   = stopSequences }
        if let v = topK            { s.topK            = v }
        if let t = thinking, !t.isEmpty   { s.thinking  = t.proto }
        if let a = anthropic, !a.isEmpty  { s.anthropic = a.proto }
        if let o = openai, !o.isEmpty     { s.openai    = o.proto }
        if let g = google, !g.isEmpty     { s.google    = g.proto }
        return s
    }
}

// MARK: - ThinkingSettings

public struct ClarkThinkingSettings: Sendable, Hashable {
    public var enabled: Bool?
    public var budgetTokens: Int32?

    public init(enabled: Bool? = nil, budgetTokens: Int32? = nil) {
        self.enabled = enabled
        self.budgetTokens = budgetTokens
    }

    public var isEmpty: Bool { enabled == nil && budgetTokens == nil }
}

extension ClarkThinkingSettings {
    public init(from p: Clark_V1_ThinkingSettings) {
        self.init(
            enabled:      p.hasEnabled      ? p.enabled      : nil,
            budgetTokens: p.hasBudgetTokens ? p.budgetTokens : nil
        )
    }

    public var proto: Clark_V1_ThinkingSettings {
        var s = Clark_V1_ThinkingSettings()
        if let v = enabled      { s.enabled      = v }
        if let v = budgetTokens { s.budgetTokens = v }
        return s
    }
}

// MARK: - AnthropicExtras

/// Anthropic-specific knobs that don't fit the cross-provider common
/// surface. v1 surfaces prompt-cache control:
///   * `cacheEnabled` — when explicitly false, the driver skips placing
///     a `cache_control` marker on the request.
///   * `cacheTTL` — picks the 5-minute (default) vs 1-hour ephemeral
///     cache tier.
public struct ClarkAnthropicExtras: Sendable, Hashable {
    public var cacheEnabled: Bool?
    public var cacheTTL: ClarkCacheTTL?

    public init(cacheEnabled: Bool? = nil, cacheTTL: ClarkCacheTTL? = nil) {
        self.cacheEnabled = cacheEnabled
        self.cacheTTL = cacheTTL
    }

    public var isEmpty: Bool {
        cacheEnabled == nil && cacheTTL == nil
    }
}

/// Anthropic ephemeral-cache TTL tier. 5-minute is the default; 1-hour
/// costs more to write but persists across longer idle gaps.
public enum ClarkCacheTTL: Sendable, Hashable {
    case fiveMinutes
    case oneHour

    init?(from p: Clark_V1_CacheTTL) {
        switch p {
        case .cacheTtl5M: self = .fiveMinutes
        case .cacheTtl1H: self = .oneHour
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Clark_V1_CacheTTL {
        switch self {
        case .fiveMinutes: return .cacheTtl5M
        case .oneHour:     return .cacheTtl1H
        }
    }
}

extension ClarkAnthropicExtras {
    public init(from p: Clark_V1_AnthropicExtras) {
        self.init(
            cacheEnabled: p.hasCacheEnabled ? p.cacheEnabled : nil,
            cacheTTL:     p.hasCacheTtl     ? ClarkCacheTTL(from: p.cacheTtl) : nil
        )
    }

    public var proto: Clark_V1_AnthropicExtras {
        var s = Clark_V1_AnthropicExtras()
        if let v = cacheEnabled { s.cacheEnabled = v }
        if let v = cacheTTL     { s.cacheTtl     = v.proto }
        return s
    }
}

// MARK: - OpenAI extras

public enum ClarkServiceTier: Sendable, Hashable {
    case auto
    case standard
    case priority

    init?(from p: Clark_V1_ServiceTier) {
        switch p {
        case .auto:     self = .auto
        case .standard: self = .standard
        case .priority: self = .priority
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Clark_V1_ServiceTier {
        switch self {
        case .auto:     return .auto
        case .standard: return .standard
        case .priority: return .priority
        }
    }
}

/// Tagged response-format selector. `text` and `jsonObject` are flags;
/// `jsonSchema` carries the schema payload.
public enum ClarkResponseFormat: Sendable, Hashable {
    case text
    case jsonObject
    case jsonSchema(name: String, description: String?, schema: Data, strict: Bool?)

    init?(from p: Clark_V1_ResponseFormat) {
        guard let kind = p.kind else { return nil }
        switch kind {
        case .text:        self = .text
        case .jsonObject:  self = .jsonObject
        case .jsonSchema(let s):
            self = .jsonSchema(
                name: s.name,
                description: s.hasDescription_p ? s.description_p : nil,
                schema: s.schema,
                strict: s.hasStrict ? s.strict : nil
            )
        }
    }

    var proto: Clark_V1_ResponseFormat {
        var rf = Clark_V1_ResponseFormat()
        switch self {
        case .text:
            rf.text = true
        case .jsonObject:
            rf.jsonObject = true
        case .jsonSchema(let name, let description, let schema, let strict):
            var js = Clark_V1_JsonSchema()
            js.name = name
            if let d = description { js.description_p = d }
            js.schema = schema
            if let s = strict { js.strict = s }
            rf.jsonSchema = js
        }
        return rf
    }
}

public struct ClarkOpenAIExtras: Sendable, Hashable {
    public var seed: Int32?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var topLogprobs: Int32?
    public var parallelToolCalls: Bool?
    public var serviceTier: ClarkServiceTier?
    public var responseFormat: ClarkResponseFormat?
    public var logitBias: [Int32: Double]

    public init(
        seed: Int32? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        topLogprobs: Int32? = nil,
        parallelToolCalls: Bool? = nil,
        serviceTier: ClarkServiceTier? = nil,
        responseFormat: ClarkResponseFormat? = nil,
        logitBias: [Int32: Double] = [:]
    ) {
        self.seed = seed
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.topLogprobs = topLogprobs
        self.parallelToolCalls = parallelToolCalls
        self.serviceTier = serviceTier
        self.responseFormat = responseFormat
        self.logitBias = logitBias
    }

    public var isEmpty: Bool {
        seed == nil
            && frequencyPenalty == nil
            && presencePenalty == nil
            && topLogprobs == nil
            && parallelToolCalls == nil
            && serviceTier == nil
            && responseFormat == nil
            && logitBias.isEmpty
    }
}

extension ClarkOpenAIExtras {
    public init(from p: Clark_V1_OpenAIExtras) {
        self.init(
            seed:              p.hasSeed              ? p.seed              : nil,
            frequencyPenalty:  p.hasFrequencyPenalty  ? p.frequencyPenalty  : nil,
            presencePenalty:   p.hasPresencePenalty   ? p.presencePenalty   : nil,
            topLogprobs:       p.hasTopLogprobs       ? p.topLogprobs       : nil,
            parallelToolCalls: p.hasParallelToolCalls ? p.parallelToolCalls : nil,
            serviceTier:       p.hasServiceTier       ? ClarkServiceTier(from: p.serviceTier) : nil,
            responseFormat:    p.hasResponseFormat    ? ClarkResponseFormat(from: p.responseFormat) : nil,
            logitBias:         p.logitBias
        )
    }

    public var proto: Clark_V1_OpenAIExtras {
        var s = Clark_V1_OpenAIExtras()
        if let v = seed              { s.seed              = v }
        if let v = frequencyPenalty  { s.frequencyPenalty  = v }
        if let v = presencePenalty   { s.presencePenalty   = v }
        if let v = topLogprobs       { s.topLogprobs       = v }
        if let v = parallelToolCalls { s.parallelToolCalls = v }
        if let v = serviceTier       { s.serviceTier       = v.proto }
        if let v = responseFormat    { s.responseFormat    = v.proto }
        if !logitBias.isEmpty        { s.logitBias         = logitBias }
        return s
    }
}

// MARK: - Google extras

public enum ClarkHarmThreshold: Sendable, Hashable {
    case blockNone
    case blockLowAndAbove
    case blockMediumAndAbove
    case blockOnlyHigh

    init?(from p: Clark_V1_HarmThreshold) {
        switch p {
        case .blockNone:            self = .blockNone
        case .blockLowAndAbove:     self = .blockLowAndAbove
        case .blockMediumAndAbove:  self = .blockMediumAndAbove
        case .blockOnlyHigh:        self = .blockOnlyHigh
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Clark_V1_HarmThreshold {
        switch self {
        case .blockNone:           return .blockNone
        case .blockLowAndAbove:    return .blockLowAndAbove
        case .blockMediumAndAbove: return .blockMediumAndAbove
        case .blockOnlyHigh:       return .blockOnlyHigh
        }
    }
}

public struct ClarkSafetySettings: Sendable, Hashable {
    public var harassment: ClarkHarmThreshold?
    public var hateSpeech: ClarkHarmThreshold?
    public var sexuallyExplicit: ClarkHarmThreshold?
    public var dangerousContent: ClarkHarmThreshold?

    public init(
        harassment: ClarkHarmThreshold? = nil,
        hateSpeech: ClarkHarmThreshold? = nil,
        sexuallyExplicit: ClarkHarmThreshold? = nil,
        dangerousContent: ClarkHarmThreshold? = nil
    ) {
        self.harassment = harassment
        self.hateSpeech = hateSpeech
        self.sexuallyExplicit = sexuallyExplicit
        self.dangerousContent = dangerousContent
    }

    public var isEmpty: Bool {
        harassment == nil && hateSpeech == nil
            && sexuallyExplicit == nil && dangerousContent == nil
    }
}

extension ClarkSafetySettings {
    public init(from p: Clark_V1_SafetySettings) {
        self.init(
            harassment:       p.hasHarassment       ? ClarkHarmThreshold(from: p.harassment)       : nil,
            hateSpeech:       p.hasHateSpeech       ? ClarkHarmThreshold(from: p.hateSpeech)       : nil,
            sexuallyExplicit: p.hasSexuallyExplicit ? ClarkHarmThreshold(from: p.sexuallyExplicit) : nil,
            dangerousContent: p.hasDangerousContent ? ClarkHarmThreshold(from: p.dangerousContent) : nil
        )
    }

    public var proto: Clark_V1_SafetySettings {
        var s = Clark_V1_SafetySettings()
        if let v = harassment       { s.harassment       = v.proto }
        if let v = hateSpeech       { s.hateSpeech       = v.proto }
        if let v = sexuallyExplicit { s.sexuallyExplicit = v.proto }
        if let v = dangerousContent { s.dangerousContent = v.proto }
        return s
    }
}

public struct ClarkGoogleExtras: Sendable, Hashable {
    public var safetySettings: ClarkSafetySettings?
    public var responseMimeType: String?
    public var responseSchema: Data?
    public var candidateCount: Int32?
    /// Server-managed Gemini cachedContents auto-placement. When true,
    /// the conversations service creates a cache when the prefix
    /// exceeds the model's minimum and references it on subsequent
    /// turns. Useful for preview models where implicit caching is
    /// unreliable.
    public var explicitCache: Bool?

    public init(
        safetySettings: ClarkSafetySettings? = nil,
        responseMimeType: String? = nil,
        responseSchema: Data? = nil,
        candidateCount: Int32? = nil,
        explicitCache: Bool? = nil
    ) {
        self.safetySettings = safetySettings
        self.responseMimeType = responseMimeType
        self.responseSchema = responseSchema
        self.candidateCount = candidateCount
        self.explicitCache = explicitCache
    }

    public var isEmpty: Bool {
        (safetySettings?.isEmpty ?? true)
            && responseMimeType == nil
            && responseSchema == nil
            && candidateCount == nil
            && explicitCache == nil
    }
}

extension ClarkGoogleExtras {
    public init(from p: Clark_V1_GoogleExtras) {
        self.init(
            safetySettings:   p.hasSafetySettings   ? ClarkSafetySettings(from: p.safetySettings) : nil,
            responseMimeType: p.hasResponseMimeType ? p.responseMimeType : nil,
            responseSchema:   p.hasResponseSchema   ? p.responseSchema   : nil,
            candidateCount:   p.hasCandidateCount   ? p.candidateCount   : nil,
            explicitCache:    p.hasExplicitCache    ? p.explicitCache    : nil
        )
    }

    public var proto: Clark_V1_GoogleExtras {
        var s = Clark_V1_GoogleExtras()
        if let v = safetySettings, !v.isEmpty { s.safetySettings   = v.proto }
        if let v = responseMimeType           { s.responseMimeType = v }
        if let v = responseSchema             { s.responseSchema   = v }
        if let v = candidateCount             { s.candidateCount   = v }
        if let v = explicitCache              { s.explicitCache    = v }
        return s
    }
}
