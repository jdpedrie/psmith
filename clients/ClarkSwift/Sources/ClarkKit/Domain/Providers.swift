import Foundation

public struct ClarkProviderType: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String          // "anthropic", "openai-compatible"
    public let displayName: String
    public let stateful: Bool
}

extension ClarkProviderType {
    init(from p: Clark_V1_ProviderType) {
        name        = p.name
        displayName = p.displayName
        stateful    = p.stateful
    }
}

public struct ClarkProviderTemplate: Sendable, Identifiable, Hashable {
    public var id: String { catalogProviderID }
    public let catalogProviderID: String   // "groq", "anthropic"
    public let name: String                // "Groq"
    public let driverType: String          // "openai-compatible"
    public let apiBase: String?
    public let envKey: String?
    public let docURL: String?
}

extension ClarkProviderTemplate {
    init(from p: Clark_V1_ProviderTemplate) {
        catalogProviderID = p.catalogProviderID
        name              = p.name
        driverType        = p.driverType
        apiBase           = p.hasApiBase ? p.apiBase : nil
        envKey            = p.hasEnvKey  ? p.envKey  : nil
        docURL            = p.hasDocURL  ? p.docURL  : nil
    }
}

public struct ClarkUserModelProvider: Sendable, Identifiable, Hashable {
    public let id: String
    public let type: String       // driver type name
    public let label: String
    public let createdAt: Date
    public let updatedAt: Date
}

extension ClarkUserModelProvider {
    init(from p: Clark_V1_UserModelProvider) {
        id        = p.id
        type      = p.type
        label     = p.label
        createdAt = p.hasCreatedAt ? p.createdAt.date : Date(timeIntervalSince1970: 0)
        updatedAt = p.hasUpdatedAt ? p.updatedAt.date : Date(timeIntervalSince1970: 0)
    }
}

public struct ClarkModelPricing: Sendable, Hashable {
    public let inputPerMillion: Double?
    public let outputPerMillion: Double?
    public let cacheReadPerMillion: Double?
    public let cacheWritePerMillion: Double?
}

extension ClarkModelPricing {
    init(from p: Clark_V1_ModelPricing) {
        inputPerMillion      = p.hasInputPerMillionTokens      ? p.inputPerMillionTokens      : nil
        outputPerMillion     = p.hasOutputPerMillionTokens     ? p.outputPerMillionTokens     : nil
        cacheReadPerMillion  = p.hasCacheReadPerMillionTokens  ? p.cacheReadPerMillionTokens  : nil
        cacheWritePerMillion = p.hasCacheWritePerMillionTokens ? p.cacheWritePerMillionTokens : nil
    }
}

public struct ClarkModelCapabilities: Sendable, Hashable {
    public let streaming: Bool
    public let thinking: Bool
    public let toolUse: Bool
    public let vision: Bool
    public let promptCaching: Bool
}

extension ClarkModelCapabilities {
    init(from p: Clark_V1_ModelCapabilities) {
        streaming     = p.streaming
        thinking      = p.thinking
        toolUse       = p.toolUse
        vision        = p.vision
        promptCaching = p.promptCaching
    }
}

public struct ClarkUserModel: Sendable, Identifiable, Hashable {
    public var id: String { modelID }
    public let providerID: String
    public let modelID: String
    public let displayName: String
    public let contextWindow: Int32?
    public let maxOutputTokens: Int32?
    public let pricing: ClarkModelPricing?
    public let knowledgeCutoff: String?
    public let modalities: [String]
    public let capabilities: ClarkModelCapabilities?
}

extension ClarkUserModel {
    init(from p: Clark_V1_UserModel) {
        providerID     = p.userModelProviderID
        modelID        = p.modelID
        displayName    = p.displayName
        contextWindow  = p.hasContextWindow  ? p.contextWindow  : nil
        maxOutputTokens = p.hasMaxOutputTokens ? p.maxOutputTokens : nil
        pricing        = p.hasPricing        ? ClarkModelPricing(from: p.pricing)        : nil
        knowledgeCutoff = p.hasKnowledgeCutoff ? p.knowledgeCutoff : nil
        modalities     = p.modalities
        capabilities   = p.hasCapabilities   ? ClarkModelCapabilities(from: p.capabilities) : nil
    }
}

public struct ClarkDiscoveredModel: Sendable, Identifiable, Hashable {
    public var id: String { modelID }
    public let modelID: String
    public let displayName: String
    public let contextWindow: Int32?
    public let pricing: ClarkModelPricing?
    public let capabilities: ClarkModelCapabilities?
    public let alreadyEnabled: Bool
}

extension ClarkDiscoveredModel {
    init(from p: Clark_V1_DiscoveredModel) {
        modelID       = p.modelID
        displayName   = p.displayName
        contextWindow = p.hasContextWindow ? p.contextWindow : nil
        pricing       = p.hasPricing       ? ClarkModelPricing(from: p.pricing)        : nil
        capabilities  = p.hasCapabilities  ? ClarkModelCapabilities(from: p.capabilities) : nil
        alreadyEnabled = p.alreadyEnabled
    }
}

