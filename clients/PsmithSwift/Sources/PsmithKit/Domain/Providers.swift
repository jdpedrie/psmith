import Foundation

public struct PsmithProviderType: Sendable, Identifiable, Hashable, Codable {
    public var id: String { name }
    public let name: String          // "anthropic", "openai-compatible"
    public let displayName: String
    public let stateful: Bool
}

extension PsmithProviderType {
    init(from p: Psmith_V1_ProviderType) {
        name        = p.name
        displayName = p.displayName
        stateful    = p.stateful
    }
}

public struct PsmithProviderTemplate: Sendable, Identifiable, Hashable, Codable {
    public var id: String { catalogProviderID }
    public let catalogProviderID: String   // "groq", "anthropic"
    public let name: String                // "Groq"
    public let driverType: String          // "openai-compatible"
    public let apiBase: String?
    public let envKey: String?
    public let docURL: String?
    /// PresetID for openai-compatible entries — must be persisted in the
    /// driver config blob as `preset_id` so the server-side driver loads
    /// the right Quirks overlay (xAI cache header, etc.). Nil for native
    /// driver entries (anthropic, google).
    public let presetID: String?
    /// LobeHub icon slug. The client renders the corresponding bundled
    /// SVG asset (`Logos/<slug>.svg`). Nil when no logo is available
    /// (custom OpenAI-compatible).
    public let logoSlug: String?

    public init(
        catalogProviderID: String,
        name: String,
        driverType: String,
        apiBase: String? = nil,
        envKey: String? = nil,
        docURL: String? = nil,
        presetID: String? = nil,
        logoSlug: String? = nil
    ) {
        self.catalogProviderID = catalogProviderID
        self.name = name
        self.driverType = driverType
        self.apiBase = apiBase
        self.envKey = envKey
        self.docURL = docURL
        self.presetID = presetID
        self.logoSlug = logoSlug
    }
}

extension PsmithProviderTemplate {
    init(from p: Psmith_V1_ProviderTemplate) {
        catalogProviderID = p.catalogProviderID
        name              = p.name
        driverType        = p.driverType
        apiBase           = p.hasApiBase   ? p.apiBase   : nil
        envKey            = p.hasEnvKey    ? p.envKey    : nil
        docURL            = p.hasDocURL    ? p.docURL    : nil
        presetID          = p.hasPresetID  ? p.presetID  : nil
        logoSlug          = p.hasLogoSlug  ? p.logoSlug  : nil
    }
}

public struct PsmithUserModelProvider: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public let type: String       // driver type name
    public let label: String
    public let createdAt: Date
    public let updatedAt: Date
    /// Provider-level default CallSettings — bottom of the resolution chain.
    /// Sparse: any unset field has no effect on the merge.
    public let defaultSettings: PsmithCallSettings?
    /// `base_url` extracted from the driver-specific config blob — only
    /// populated for openai-compatible providers, where it's the upstream
    /// endpoint root. Surfaced so the edit form can show the user what's
    /// currently set instead of asking them to re-type it from memory.
    /// `api_key` is intentionally not exposed here — it's a secret.
    public let baseURL: String?
    /// `preset_id` extracted from the driver config blob — names the
    /// openai-compatible preset (xai, deepseek, ...) the driver uses to
    /// pick its Quirks overlay. Empty for native drivers and for legacy
    /// "custom" configs without a preset id. Used by the UI to render
    /// the right provider logo and a friendly display name.
    public let presetID: String?

    public init(
        id: String,
        type: String,
        label: String,
        createdAt: Date,
        updatedAt: Date,
        defaultSettings: PsmithCallSettings? = nil,
        baseURL: String? = nil,
        presetID: String? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.defaultSettings = defaultSettings
        self.baseURL = baseURL
        self.presetID = presetID
    }
}

extension PsmithUserModelProvider {
    init(from p: Psmith_V1_UserModelProvider) {
        id        = p.id
        type      = p.type
        label     = p.label
        createdAt = p.hasCreatedAt ? p.createdAt.date : Date(timeIntervalSince1970: 0)
        updatedAt = p.hasUpdatedAt ? p.updatedAt.date : Date(timeIntervalSince1970: 0)
        defaultSettings = p.hasDefaultSettings ? PsmithCallSettings(from: p.defaultSettings) : nil
        let dict = Self.parseConfig(p.config)
        baseURL = (dict["base_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        presetID = (dict["preset_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Parses the JSON config blob into a dictionary. Returns an empty
    /// dictionary for any shape we can't decode (malformed JSON, native
    /// driver configs that aren't dictionaries, harness providers, etc.).
    private static func parseConfig(_ config: Data) -> [String: Any] {
        guard !config.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: config),
              let dict = any as? [String: Any]
        else { return [:] }
        return dict
    }
}

public struct PsmithModelPricing: Sendable, Hashable, Codable {
    public let inputPerMillion: Double?
    public let outputPerMillion: Double?
    public let cacheReadPerMillion: Double?
    public let cacheWritePerMillion: Double?

    public init(
        inputPerMillion: Double?,
        outputPerMillion: Double?,
        cacheReadPerMillion: Double?,
        cacheWritePerMillion: Double?
    ) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
    }
}

extension PsmithModelPricing {
    init(from p: Psmith_V1_ModelPricing) {
        inputPerMillion      = p.hasInputPerMillionTokens      ? p.inputPerMillionTokens      : nil
        outputPerMillion     = p.hasOutputPerMillionTokens     ? p.outputPerMillionTokens     : nil
        cacheReadPerMillion  = p.hasCacheReadPerMillionTokens  ? p.cacheReadPerMillionTokens  : nil
        cacheWritePerMillion = p.hasCacheWritePerMillionTokens ? p.cacheWritePerMillionTokens : nil
    }
}

public struct PsmithModelCapabilities: Sendable, Hashable, Codable {
    public let streaming: Bool
    public let thinking: Bool
    public let toolUse: Bool
    public let vision: Bool
    public let promptCaching: Bool
    public let generatesImages: Bool

    public init(
        streaming: Bool,
        thinking: Bool,
        toolUse: Bool,
        vision: Bool,
        promptCaching: Bool,
        generatesImages: Bool = false
    ) {
        self.streaming = streaming
        self.thinking = thinking
        self.toolUse = toolUse
        self.vision = vision
        self.promptCaching = promptCaching
        self.generatesImages = generatesImages
    }
}

extension PsmithModelCapabilities {
    init(from p: Psmith_V1_ModelCapabilities) {
        streaming       = p.streaming
        thinking        = p.thinking
        toolUse         = p.toolUse
        vision          = p.vision
        promptCaching   = p.promptCaching
        generatesImages = p.generatesImages
    }

    /// Zero-value caps — convenient default for "model has no capability info."
    public static let empty = PsmithModelCapabilities(
        streaming: false,
        thinking: false,
        toolUse: false,
        vision: false,
        promptCaching: false,
        generatesImages: false
    )

    /// True when no field is true. Used by callers that want to short-circuit
    /// "this model lacks capabilities" UI when no requirements are set.
    public var isEmpty: Bool {
        !(streaming || thinking || toolUse || vision || promptCaching || generatesImages)
    }

    /// Returns the names of capability fields set on `self` but missing from
    /// `actual`. Mirrors the server-side `ModelCapabilityRequirements.Names()`
    /// for shortfall checks: empty result means `actual` satisfies every
    /// requirement set on `self`.
    public func shortfall(against actual: PsmithModelCapabilities) -> [String] {
        var out: [String] = []
        if streaming       && !actual.streaming       { out.append("streaming") }
        if thinking        && !actual.thinking        { out.append("thinking") }
        if toolUse         && !actual.toolUse         { out.append("tool_use") }
        if vision          && !actual.vision          { out.append("vision") }
        if promptCaching   && !actual.promptCaching   { out.append("prompt_caching") }
        if generatesImages && !actual.generatesImages { out.append("generates_images") }
        return out
    }
}

public struct PsmithUserModel: Sendable, Identifiable, Hashable, Codable {
    public var id: String { modelID }
    public let providerID: String
    public let modelID: String
    public let displayName: String
    public let contextWindow: Int32?
    public let maxOutputTokens: Int32?
    public let pricing: PsmithModelPricing?
    public let knowledgeCutoff: String?
    public let modalities: [String]
    public let capabilities: PsmithModelCapabilities?
    public let favorite: Bool
    /// Per-model default CallSettings. Resolves below the profile layer in
    /// the merge chain — a profile's `defaultSettings.callSettings` overrides
    /// any field this layer sets.
    public let defaultSettings: PsmithCallSettings?
    /// Server-supplied UI guardrails for this model (clamped temperature
    /// ranges, locked-at values, hidden-control list). Sourced from
    /// internal/modelmeta/constraints.go and empirically refreshed via
    /// cmd/discover-constraints. nil = no known constraints; the UI
    /// offers the full range and reactively renders any upstream
    /// rejection inline.
    public let constraints: PsmithModelConstraints?
    /// Where the snapshotted metadata came from: "catalog" rows can be
    /// re-synced via RefreshUserModelMetadata; "manual" and
    /// "driver" rows have nothing to refresh against. Mirrors the
    /// proto MetadataSource enum as its lowercase name.
    public let metadataSource: String

    public init(
        providerID: String,
        modelID: String,
        displayName: String,
        contextWindow: Int32?,
        maxOutputTokens: Int32?,
        pricing: PsmithModelPricing?,
        knowledgeCutoff: String?,
        modalities: [String],
        capabilities: PsmithModelCapabilities?,
        favorite: Bool,
        defaultSettings: PsmithCallSettings? = nil,
        constraints: PsmithModelConstraints? = nil,
        metadataSource: String = "manual"
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.pricing = pricing
        self.knowledgeCutoff = knowledgeCutoff
        self.modalities = modalities
        self.capabilities = capabilities
        self.favorite = favorite
        self.defaultSettings = defaultSettings
        self.constraints = constraints
        self.metadataSource = metadataSource
    }
}

extension PsmithUserModel {
    init(from p: Psmith_V1_UserModel) {
        providerID     = p.userModelProviderID
        modelID        = p.modelID
        displayName    = p.displayName
        contextWindow  = p.hasContextWindow  ? p.contextWindow  : nil
        maxOutputTokens = p.hasMaxOutputTokens ? p.maxOutputTokens : nil
        pricing        = p.hasPricing        ? PsmithModelPricing(from: p.pricing)        : nil
        knowledgeCutoff = p.hasKnowledgeCutoff ? p.knowledgeCutoff : nil
        modalities     = p.modalities
        capabilities   = p.hasCapabilities   ? PsmithModelCapabilities(from: p.capabilities) : nil
        favorite       = p.favorite
        defaultSettings = p.hasDefaultSettings ? PsmithCallSettings(from: p.defaultSettings) : nil
        constraints   = p.hasConstraints    ? PsmithModelConstraints(from: p.constraints)  : nil
        switch p.metadataSource {
        case .catalog:   metadataSource = "catalog"
        case .driver:    metadataSource = "driver"
        case .manual:    metadataSource = "manual"
        default:         metadataSource = "manual"
        }
    }
}

/// Per-model UI guardrails for CallSettings. Sparse — any field left
/// nil means "no known constraint." Mirrors the Go `modelmeta.Constraints`
/// + `proto Psmith_V1_ModelConstraints`. Source-of-truth table lives in
/// `internal/modelmeta/constraints.go`.
public struct PsmithModelConstraints: Sendable, Hashable, Codable {
    /// Accepted temperature interval. nil = no constraint; UI offers
    /// the full slider range.
    public let temperature: PsmithRange?
    /// Dotted CallSettings field paths the model is known to reject
    /// (e.g. "openai.response_format" on some Z.AI models). UIs should
    /// hide or disable controls for any path in this list.
    public let unsupported: [String]

    public init(temperature: PsmithRange? = nil, unsupported: [String] = []) {
        self.temperature = temperature
        self.unsupported = unsupported
    }

    init(from p: Psmith_V1_ModelConstraints) {
        temperature = p.hasTemperature ? PsmithRange(from: p.temperature) : nil
        unsupported = p.unsupported
    }

    /// Convenience: true when the named field path is in `unsupported`.
    public func isUnsupported(_ path: String) -> Bool {
        unsupported.contains(path)
    }
}

/// Supported numeric range for a single setting. Min/max inclusive;
/// `lockedAt`, when set, overrides both — the only valid value is
/// exactly `lockedAt` (e.g. OpenAI's o-series + gpt-5 family lock
/// temperature at 1.0).
public struct PsmithRange: Sendable, Hashable, Codable {
    public let min: Double?
    public let max: Double?
    public let lockedAt: Double?

    public init(min: Double? = nil, max: Double? = nil, lockedAt: Double? = nil) {
        self.min = min
        self.max = max
        self.lockedAt = lockedAt
    }

    init(from p: Psmith_V1_Range) {
        min = p.hasMin ? p.min : nil
        max = p.hasMax ? p.max : nil
        lockedAt = p.hasLockedAt ? p.lockedAt : nil
    }

    /// Clamp `value` to the range. If `lockedAt` is set, returns it
    /// unconditionally. Otherwise applies min/max bounds.
    public func clamp(_ value: Double) -> Double {
        if let l = lockedAt { return l }
        var v = value
        if let lo = min, v < lo { v = lo }
        if let hi = max, v > hi { v = hi }
        return v
    }
}

public struct PsmithDiscoveredModel: Sendable, Identifiable, Hashable {
    public var id: String { modelID }
    public let modelID: String
    public let displayName: String
    public let contextWindow: Int32?
    public let pricing: PsmithModelPricing?
    public let capabilities: PsmithModelCapabilities?
    public let alreadyEnabled: Bool

    public init(
        modelID: String,
        displayName: String,
        contextWindow: Int32? = nil,
        pricing: PsmithModelPricing? = nil,
        capabilities: PsmithModelCapabilities? = nil,
        alreadyEnabled: Bool = false
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.pricing = pricing
        self.capabilities = capabilities
        self.alreadyEnabled = alreadyEnabled
    }
}

extension PsmithDiscoveredModel {
    init(from p: Psmith_V1_DiscoveredModel) {
        modelID       = p.modelID
        displayName   = p.displayName
        contextWindow = p.hasContextWindow ? p.contextWindow : nil
        pricing       = p.hasPricing       ? PsmithModelPricing(from: p.pricing)        : nil
        capabilities  = p.hasCapabilities  ? PsmithModelCapabilities(from: p.capabilities) : nil
        alreadyEnabled = p.alreadyEnabled
    }
}

// MARK: - Test results

/// Outcome of a "Test provider" action — verifies auth + reachability via
/// the driver's DiscoverModels. Server packs failures into the response so
/// clients can render them inline next to successful results.
public struct PsmithProviderTestResult: Sendable, Hashable {
    public let ok: Bool
    public let errorMessage: String
    public let modelCount: Int32
    public let latencyMs: Int64

    public init(ok: Bool, errorMessage: String, modelCount: Int32, latencyMs: Int64) {
        self.ok = ok
        self.errorMessage = errorMessage
        self.modelCount = modelCount
        self.latencyMs = latencyMs
    }
}

extension PsmithProviderTestResult {
    init(from p: Psmith_V1_TestUserModelProviderResponse) {
        ok = p.ok
        errorMessage = p.errorMessage
        modelCount = p.modelCount
        latencyMs = p.latencyMs
    }
}

/// Outcome of a "Test model" action — sends a tiny "Reply with the single
/// word OK." prompt and reports latency, tokens, and a sample of the reply.
public struct PsmithModelTestResult: Sendable, Hashable {
    public let ok: Bool
    public let errorMessage: String
    public let latencyMs: Int64
    public let inputTokens: Int32
    public let outputTokens: Int32
    public let sampleText: String

    public init(ok: Bool, errorMessage: String, latencyMs: Int64,
                inputTokens: Int32, outputTokens: Int32, sampleText: String) {
        self.ok = ok
        self.errorMessage = errorMessage
        self.latencyMs = latencyMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.sampleText = sampleText
    }
}

extension PsmithModelTestResult {
    init(from p: Psmith_V1_TestUserModelResponse) {
        ok = p.ok
        errorMessage = p.errorMessage
        latencyMs = p.latencyMs
        inputTokens = p.inputTokens
        outputTokens = p.outputTokens
        sampleText = p.sampleText
    }
}

