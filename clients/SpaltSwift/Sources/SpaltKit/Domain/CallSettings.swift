import Foundation

// MARK: - CallSettings (universal common-core)

/// Cross-driver per-call settings. Hybrid common-core + provider-specific
/// shape that mirrors `Spalt_V1_CallSettings`:
///   * The first block is universal (every driver translates it).
///   * `topK` is shared by Anthropic + Google.
///   * `thinking` is the universal "extended reasoning" knob translated
///     per driver.
///   * `anthropic` / `openai` / `google` carry per-provider knobs.
///
/// All fields are nullable / `nil`-defaulted — every layer can leave any
/// field unset to inherit from the layer below in the resolution chain.
public struct SpaltCallSettings: Sendable, Hashable, Codable {
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int32?
    public var stopSequences: [String]
    public var topK: Int32?
    public var thinking: SpaltThinkingSettings?
    public var anthropic: SpaltAnthropicExtras?
    public var openai: SpaltOpenAIExtras?
    public var google: SpaltGoogleExtras?
    /// Cross-cutting toggle. When true, the conversations service
    /// activates server-managed explicit caching for this turn —
    /// dispatched through providers.ExplicitCacheProvider on the
    /// active driver (Google's cachedContents today; Anthropic's
    /// cache_control auto-placement could grow into one). No-op for
    /// drivers that don't implement the interface.
    public var explicitCache: Bool?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int32? = nil,
        stopSequences: [String] = [],
        topK: Int32? = nil,
        thinking: SpaltThinkingSettings? = nil,
        anthropic: SpaltAnthropicExtras? = nil,
        openai: SpaltOpenAIExtras? = nil,
        google: SpaltGoogleExtras? = nil,
        explicitCache: Bool? = nil
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
        self.explicitCache = explicitCache
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
            && explicitCache == nil
    }
}

extension SpaltCallSettings {
    /// Round-trip from the proto into the domain struct. Every "unset"
    /// proto optional becomes a Swift `nil`; sub-messages recurse and
    /// collapse to `nil` when wholly empty.
    public init(from p: Spalt_V1_CallSettings) {
        self.init(
            temperature:     p.hasTemperature     ? p.temperature     : nil,
            topP:            p.hasTopP            ? p.topP            : nil,
            maxOutputTokens: p.hasMaxOutputTokens ? p.maxOutputTokens : nil,
            stopSequences:   p.stopSequences,
            topK:            p.hasTopK            ? p.topK            : nil,
            thinking:  p.hasThinking  ? SpaltThinkingSettings(from: p.thinking)   : nil,
            anthropic: p.hasAnthropic ? SpaltAnthropicExtras(from: p.anthropic)   : nil,
            openai:    p.hasOpenai    ? SpaltOpenAIExtras(from: p.openai)         : nil,
            google:    p.hasGoogle    ? SpaltGoogleExtras(from: p.google)         : nil,
            explicitCache: p.hasExplicitCache ? p.explicitCache : nil
        )
    }

    /// Lossless export to the proto shape. Every field is sparsely set —
    /// only writes the proto presence flag when the Swift field is non-nil.
    public var proto: Spalt_V1_CallSettings {
        var s = Spalt_V1_CallSettings()
        if let v = temperature     { s.temperature     = v }
        if let v = topP            { s.topP            = v }
        if let v = maxOutputTokens { s.maxOutputTokens = v }
        if !stopSequences.isEmpty  { s.stopSequences   = stopSequences }
        if let v = topK            { s.topK            = v }
        if let v = explicitCache   { s.explicitCache   = v }
        if let t = thinking, !t.isEmpty   { s.thinking  = t.proto }
        if let a = anthropic, !a.isEmpty  { s.anthropic = a.proto }
        if let o = openai, !o.isEmpty     { s.openai    = o.proto }
        if let g = google, !g.isEmpty     { s.google    = g.proto }
        return s
    }
}

// MARK: - ThinkingSettings

public struct SpaltThinkingSettings: Sendable, Hashable, Codable {
    public var enabled: Bool?
    public var budgetTokens: Int32?

    public init(enabled: Bool? = nil, budgetTokens: Int32? = nil) {
        self.enabled = enabled
        self.budgetTokens = budgetTokens
    }

    public var isEmpty: Bool { enabled == nil && budgetTokens == nil }
}

extension SpaltThinkingSettings {
    public init(from p: Spalt_V1_ThinkingSettings) {
        self.init(
            enabled:      p.hasEnabled      ? p.enabled      : nil,
            budgetTokens: p.hasBudgetTokens ? p.budgetTokens : nil
        )
    }

    public var proto: Spalt_V1_ThinkingSettings {
        var s = Spalt_V1_ThinkingSettings()
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
public struct SpaltAnthropicExtras: Sendable, Hashable, Codable {
    public var cacheEnabled: Bool?
    public var cacheTTL: SpaltCacheTTL?

    public init(cacheEnabled: Bool? = nil, cacheTTL: SpaltCacheTTL? = nil) {
        self.cacheEnabled = cacheEnabled
        self.cacheTTL = cacheTTL
    }

    public var isEmpty: Bool {
        cacheEnabled == nil && cacheTTL == nil
    }
}

/// Anthropic ephemeral-cache TTL tier. 5-minute is the default; 1-hour
/// costs more to write but persists across longer idle gaps.
public enum SpaltCacheTTL: Sendable, Hashable, Codable {
    case fiveMinutes
    case oneHour

    init?(from p: Spalt_V1_CacheTTL) {
        switch p {
        case .cacheTtl5M: self = .fiveMinutes
        case .cacheTtl1H: self = .oneHour
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Spalt_V1_CacheTTL {
        switch self {
        case .fiveMinutes: return .cacheTtl5M
        case .oneHour:     return .cacheTtl1H
        }
    }
}

extension SpaltAnthropicExtras {
    public init(from p: Spalt_V1_AnthropicExtras) {
        self.init(
            cacheEnabled: p.hasCacheEnabled ? p.cacheEnabled : nil,
            cacheTTL:     p.hasCacheTtl     ? SpaltCacheTTL(from: p.cacheTtl) : nil
        )
    }

    public var proto: Spalt_V1_AnthropicExtras {
        var s = Spalt_V1_AnthropicExtras()
        if let v = cacheEnabled { s.cacheEnabled = v }
        if let v = cacheTTL     { s.cacheTtl     = v.proto }
        return s
    }
}

// MARK: - OpenAI extras

public enum SpaltServiceTier: Sendable, Hashable, Codable {
    case auto
    case standard
    case priority

    init?(from p: Spalt_V1_ServiceTier) {
        switch p {
        case .auto:     self = .auto
        case .standard: self = .standard
        case .priority: self = .priority
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Spalt_V1_ServiceTier {
        switch self {
        case .auto:     return .auto
        case .standard: return .standard
        case .priority: return .priority
        }
    }
}

/// Tagged response-format selector. `text` and `jsonObject` are flags;
/// `jsonSchema` carries the schema payload.
public enum SpaltResponseFormat: Sendable, Hashable, Codable {
    case text
    case jsonObject
    case jsonSchema(name: String, description: String?, schema: Data, strict: Bool?)

    init?(from p: Spalt_V1_ResponseFormat) {
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

    var proto: Spalt_V1_ResponseFormat {
        var rf = Spalt_V1_ResponseFormat()
        switch self {
        case .text:
            rf.text = true
        case .jsonObject:
            rf.jsonObject = true
        case .jsonSchema(let name, let description, let schema, let strict):
            var js = Spalt_V1_JsonSchema()
            js.name = name
            if let d = description { js.description_p = d }
            js.schema = schema
            if let s = strict { js.strict = s }
            rf.jsonSchema = js
        }
        return rf
    }
}

public struct SpaltOpenAIExtras: Sendable, Hashable, Codable {
    public var seed: Int32?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var topLogprobs: Int32?
    public var parallelToolCalls: Bool?
    public var serviceTier: SpaltServiceTier?
    public var responseFormat: SpaltResponseFormat?
    public var logitBias: [Int32: Double]

    public init(
        seed: Int32? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        topLogprobs: Int32? = nil,
        parallelToolCalls: Bool? = nil,
        serviceTier: SpaltServiceTier? = nil,
        responseFormat: SpaltResponseFormat? = nil,
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

extension SpaltOpenAIExtras {
    public init(from p: Spalt_V1_OpenAIExtras) {
        self.init(
            seed:              p.hasSeed              ? p.seed              : nil,
            frequencyPenalty:  p.hasFrequencyPenalty  ? p.frequencyPenalty  : nil,
            presencePenalty:   p.hasPresencePenalty   ? p.presencePenalty   : nil,
            topLogprobs:       p.hasTopLogprobs       ? p.topLogprobs       : nil,
            parallelToolCalls: p.hasParallelToolCalls ? p.parallelToolCalls : nil,
            serviceTier:       p.hasServiceTier       ? SpaltServiceTier(from: p.serviceTier) : nil,
            responseFormat:    p.hasResponseFormat    ? SpaltResponseFormat(from: p.responseFormat) : nil,
            logitBias:         p.logitBias
        )
    }

    public var proto: Spalt_V1_OpenAIExtras {
        var s = Spalt_V1_OpenAIExtras()
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

public enum SpaltHarmThreshold: Sendable, Hashable, Codable {
    case blockNone
    case blockLowAndAbove
    case blockMediumAndAbove
    case blockOnlyHigh

    init?(from p: Spalt_V1_HarmThreshold) {
        switch p {
        case .blockNone:            self = .blockNone
        case .blockLowAndAbove:     self = .blockLowAndAbove
        case .blockMediumAndAbove:  self = .blockMediumAndAbove
        case .blockOnlyHigh:        self = .blockOnlyHigh
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: Spalt_V1_HarmThreshold {
        switch self {
        case .blockNone:           return .blockNone
        case .blockLowAndAbove:    return .blockLowAndAbove
        case .blockMediumAndAbove: return .blockMediumAndAbove
        case .blockOnlyHigh:       return .blockOnlyHigh
        }
    }
}

public struct SpaltSafetySettings: Sendable, Hashable, Codable {
    public var harassment: SpaltHarmThreshold?
    public var hateSpeech: SpaltHarmThreshold?
    public var sexuallyExplicit: SpaltHarmThreshold?
    public var dangerousContent: SpaltHarmThreshold?

    public init(
        harassment: SpaltHarmThreshold? = nil,
        hateSpeech: SpaltHarmThreshold? = nil,
        sexuallyExplicit: SpaltHarmThreshold? = nil,
        dangerousContent: SpaltHarmThreshold? = nil
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

extension SpaltSafetySettings {
    public init(from p: Spalt_V1_SafetySettings) {
        self.init(
            harassment:       p.hasHarassment       ? SpaltHarmThreshold(from: p.harassment)       : nil,
            hateSpeech:       p.hasHateSpeech       ? SpaltHarmThreshold(from: p.hateSpeech)       : nil,
            sexuallyExplicit: p.hasSexuallyExplicit ? SpaltHarmThreshold(from: p.sexuallyExplicit) : nil,
            dangerousContent: p.hasDangerousContent ? SpaltHarmThreshold(from: p.dangerousContent) : nil
        )
    }

    public var proto: Spalt_V1_SafetySettings {
        var s = Spalt_V1_SafetySettings()
        if let v = harassment       { s.harassment       = v.proto }
        if let v = hateSpeech       { s.hateSpeech       = v.proto }
        if let v = sexuallyExplicit { s.sexuallyExplicit = v.proto }
        if let v = dangerousContent { s.dangerousContent = v.proto }
        return s
    }
}

public struct SpaltGoogleExtras: Sendable, Hashable, Codable {
    public var safetySettings: SpaltSafetySettings?
    public var responseMimeType: String?
    public var responseSchema: Data?
    public var candidateCount: Int32?

    public init(
        safetySettings: SpaltSafetySettings? = nil,
        responseMimeType: String? = nil,
        responseSchema: Data? = nil,
        candidateCount: Int32? = nil
    ) {
        self.safetySettings = safetySettings
        self.responseMimeType = responseMimeType
        self.responseSchema = responseSchema
        self.candidateCount = candidateCount
    }

    public var isEmpty: Bool {
        (safetySettings?.isEmpty ?? true)
            && responseMimeType == nil
            && responseSchema == nil
            && candidateCount == nil
    }
}

extension SpaltGoogleExtras {
    public init(from p: Spalt_V1_GoogleExtras) {
        self.init(
            safetySettings:   p.hasSafetySettings   ? SpaltSafetySettings(from: p.safetySettings) : nil,
            responseMimeType: p.hasResponseMimeType ? p.responseMimeType : nil,
            responseSchema:   p.hasResponseSchema   ? p.responseSchema   : nil,
            candidateCount:   p.hasCandidateCount   ? p.candidateCount   : nil
        )
    }

    public var proto: Spalt_V1_GoogleExtras {
        var s = Spalt_V1_GoogleExtras()
        if let v = safetySettings, !v.isEmpty { s.safetySettings   = v.proto }
        if let v = responseMimeType           { s.responseMimeType = v }
        if let v = responseSchema             { s.responseSchema   = v }
        if let v = candidateCount             { s.candidateCount   = v }
        return s
    }
}
