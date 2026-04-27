import Foundation

public struct ClarkConversation: Sendable, Hashable, Identifiable {
    public let id: String
    public let profileID: String
    public let title: String?
    public let activeContextID: String
    public let ownerUserID: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        profileID: String,
        title: String?,
        activeContextID: String,
        ownerUserID: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.activeContextID = activeContextID
        self.ownerUserID = ownerUserID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension ClarkConversation {
    init(from p: Clark_V1_Conversation) {
        self.init(
            id: p.id,
            profileID: p.profileID,
            title: p.hasTitle ? p.title : nil,
            activeContextID: p.activeContextID,
            ownerUserID: p.ownerUserID,
            createdAt: p.hasCreatedAt ? p.createdAt.date : Date(timeIntervalSince1970: 0),
            updatedAt: p.hasUpdatedAt ? p.updatedAt.date : Date(timeIntervalSince1970: 0)
        )
    }
}

public struct ClarkContext: Sendable, Hashable, Identifiable {
    public let id: String
    public let conversationID: String
    public let parentContextID: String?
    public let activationTime: Date?
    public let createdAt: Date
    public let currentLeafMessageID: String?
    public let title: String?
    /// Total messages in this context (every role). Populated by ListContexts;
    /// zero on responses from single-context RPCs that don't aggregate.
    public let messageCount: Int
}

extension ClarkContext {
    init(from p: Clark_V1_Context) {
        self.init(
            id: p.id,
            conversationID: p.conversationID,
            parentContextID: p.hasParentContextID ? p.parentContextID : nil,
            activationTime: p.hasActivationTime ? p.activationTime.date : nil,
            createdAt: p.hasCreatedAt ? p.createdAt.date : Date(timeIntervalSince1970: 0),
            currentLeafMessageID: p.hasCurrentLeafMessageID ? p.currentLeafMessageID : nil,
            title: p.hasTitle ? p.title : nil,
            messageCount: Int(p.messageCount)
        )
    }
}

public enum ClarkMessageRole: String, Sendable, Hashable {
    case system, context, user, assistant, compressionSummary, unknown

    init(from p: Clark_V1_MessageRole) {
        switch p {
        case .system: self = .system
        case .context: self = .context
        case .user: self = .user
        case .assistant: self = .assistant
        case .compressionSummary: self = .compressionSummary
        default: self = .unknown
        }
    }
}

/// Full token and cost breakdown for a single assistant message.
public struct ClarkMessageUsage: Sendable, Hashable {
    public let inputTokens: Int32?
    public let outputTokens: Int32?
    public let cacheReadTokens: Int32?
    public let cacheWriteTokens: Int32?
    public let reasoningTokens: Int32?
    public let inputCostUsd: Double?
    public let outputCostUsd: Double?
    public let cacheReadCostUsd: Double?
    public let cacheWriteCostUsd: Double?
    public let totalCostUsd: Double?
}

extension ClarkMessageUsage {
    init(from p: Clark_V1_MessageUsage) {
        inputTokens       = p.hasInputTokens       ? p.inputTokens       : nil
        outputTokens      = p.hasOutputTokens      ? p.outputTokens      : nil
        cacheReadTokens   = p.hasCacheReadTokens   ? p.cacheReadTokens   : nil
        cacheWriteTokens  = p.hasCacheWriteTokens  ? p.cacheWriteTokens  : nil
        reasoningTokens   = p.hasReasoningTokens   ? p.reasoningTokens   : nil
        inputCostUsd      = p.hasInputCostUsd      ? p.inputCostUsd      : nil
        outputCostUsd     = p.hasOutputCostUsd     ? p.outputCostUsd     : nil
        cacheReadCostUsd  = p.hasCacheReadCostUsd  ? p.cacheReadCostUsd  : nil
        cacheWriteCostUsd = p.hasCacheWriteCostUsd ? p.cacheWriteCostUsd : nil
        totalCostUsd      = p.hasTotalCostUsd      ? p.totalCostUsd      : nil
    }
}

public struct ClarkMessage: Sendable, Hashable, Identifiable {
    public let id: String
    public let contextID: String
    public let parentID: String?
    public let role: ClarkMessageRole
    public let content: String
    /// Plugin display_content when a DisplayTransformer ran; else nil.
    public let displayContent: String?
    /// Number of sibling messages sharing this message's parent (0 = no fork).
    public let siblingCount: Int32
    /// Non-nil on assistant messages that were produced by a model.
    public let providerID: String?
    public let modelID: String?
    /// Full token/cost breakdown; nil when the server sent no usage data.
    public let usage: ClarkMessageUsage?
    /// Non-nil when this message has been edited via EditMessage.
    public let editedAt: Date?

    /// Convenience forwarder used by costToDate roll-ups.
    public var totalCostUsd: Double? { usage?.totalCostUsd }
}

extension ClarkMessage {
    init(from p: Clark_V1_Message) {
        self.init(
            id: p.id,
            contextID: p.contextID,
            parentID: p.hasParentID ? p.parentID : nil,
            role: ClarkMessageRole(from: p.role),
            content: p.content,
            displayContent: p.displayContent.isEmpty ? nil : p.displayContent,
            siblingCount: p.siblingCount,
            providerID: p.hasProviderID ? p.providerID : nil,
            modelID: p.hasModelID ? p.modelID : nil,
            usage: p.hasUsage ? ClarkMessageUsage(from: p.usage) : nil,
            editedAt: p.hasEditedAt ? p.editedAt.date : nil
        )
    }
}

public enum ClarkCompressionMode: Sendable, Hashable {
    case unspecified
    case replace
    case append
}

public struct ClarkProfileDefaults: Sendable, Hashable {
    public var defaultProviderID: String?
    public var defaultModelID: String?
    public var includeThinkingInHistory: Bool?

    public init(defaultProviderID: String? = nil, defaultModelID: String? = nil, includeThinkingInHistory: Bool? = nil) {
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        self.includeThinkingInHistory = includeThinkingInHistory
    }
}

public struct ClarkProfile: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let parentProfileID: String?
    public let systemMessage: String?
    public let defaultUserMessage: String?
    public let compressionGuide: String?
    public let compressionMode: ClarkCompressionMode?
    public let compressionProviderID: String?
    public let compressionModelID: String?
    public let defaultSettings: ClarkProfileDefaults?
    public let titleProviderID: String?
    public let titleModelID: String?
    public let titleGuide: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: String,
        name: String,
        parentProfileID: String? = nil,
        systemMessage: String? = nil,
        defaultUserMessage: String? = nil,
        compressionGuide: String? = nil,
        compressionMode: ClarkCompressionMode? = nil,
        compressionProviderID: String? = nil,
        compressionModelID: String? = nil,
        defaultSettings: ClarkProfileDefaults? = nil,
        titleProviderID: String? = nil,
        titleModelID: String? = nil,
        titleGuide: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.parentProfileID = parentProfileID
        self.systemMessage = systemMessage
        self.defaultUserMessage = defaultUserMessage
        self.compressionGuide = compressionGuide
        self.compressionMode = compressionMode
        self.compressionProviderID = compressionProviderID
        self.compressionModelID = compressionModelID
        self.defaultSettings = defaultSettings
        self.titleProviderID = titleProviderID
        self.titleModelID = titleModelID
        self.titleGuide = titleGuide
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension ClarkProfile {
    init(from p: Clark_V1_Profile) {
        let mode: ClarkCompressionMode? = p.hasCompressionMode
            ? {
                switch p.compressionMode {
                case .replace: return .replace
                case .append:  return .append
                default:       return .unspecified
                }
            }()
            : nil
        let defaults: ClarkProfileDefaults? = p.hasDefaultSettings
            ? ClarkProfileDefaults(
                defaultProviderID:        p.defaultSettings.hasDefaultProviderID ? p.defaultSettings.defaultProviderID : nil,
                defaultModelID:           p.defaultSettings.hasDefaultModelID    ? p.defaultSettings.defaultModelID    : nil,
                includeThinkingInHistory: p.defaultSettings.hasIncludeThinkingInHistory ? p.defaultSettings.includeThinkingInHistory : nil
            )
            : nil
        self.init(
            id: p.id,
            name: p.name,
            parentProfileID:       p.hasParentProfileID       ? p.parentProfileID       : nil,
            systemMessage:         p.hasSystemMessage         ? p.systemMessage         : nil,
            defaultUserMessage:    p.hasDefaultUserMessage    ? p.defaultUserMessage    : nil,
            compressionGuide:      p.hasCompressionGuide      ? p.compressionGuide      : nil,
            compressionMode:       mode,
            compressionProviderID: p.hasCompressionProviderID ? p.compressionProviderID : nil,
            compressionModelID:    p.hasCompressionModelID    ? p.compressionModelID    : nil,
            defaultSettings:       defaults,
            titleProviderID:       p.hasTitleProviderID       ? p.titleProviderID       : nil,
            titleModelID:          p.hasTitleModelID          ? p.titleModelID          : nil,
            titleGuide:            p.hasTitleGuide            ? p.titleGuide            : nil,
            createdAt:             p.hasCreatedAt ? p.createdAt.date : nil,
            updatedAt:             p.hasUpdatedAt ? p.updatedAt.date : nil
        )
    }
}

import SwiftProtobuf

extension Google_Protobuf_Timestamp {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }
}
