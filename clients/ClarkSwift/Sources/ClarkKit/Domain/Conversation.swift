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

/// Per-conversation overrides that shadow the profile's defaults.
/// Mirrors `Clark_V1_ConversationSettings` but exposes a Swift-friendly
/// shape (no proto-generated has-getters / value defaults).
public struct ClarkConversationSettings: Sendable, Hashable {
    public var defaultProviderID: String?
    public var defaultModelID: String?
    public var includeThinkingInHistory: Bool?

    public init(
        defaultProviderID: String? = nil,
        defaultModelID: String? = nil,
        includeThinkingInHistory: Bool? = nil
    ) {
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        self.includeThinkingInHistory = includeThinkingInHistory
    }

    /// True if no overrides are set — caller should pass `nil` to the
    /// repository in that case rather than an empty proto.
    public var isEmpty: Bool {
        defaultProviderID == nil && defaultModelID == nil && includeThinkingInHistory == nil
    }

    var proto: Clark_V1_ConversationSettings {
        var s = Clark_V1_ConversationSettings()
        if let v = defaultProviderID        { s.defaultProviderID = v }
        if let v = defaultModelID           { s.defaultModelID = v }
        if let v = includeThinkingInHistory { s.includeThinkingInHistory = v }
        return s
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
    /// Total tokens (input + output) of the most recent assistant message in
    /// this context. Populated by ListContexts; zero when retrieved via
    /// single-context RPCs or when no assistant message with usage exists yet.
    public let lastMessageTotalTokens: Int64
    /// Cumulative cost in USD across every message in this context. Populated
    /// by ListContexts; zero on single-context RPCs that don't aggregate.
    public let cumulativeCostUsd: Double
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
            messageCount: Int(p.messageCount),
            lastMessageTotalTokens: p.lastMessageTotalTokens,
            cumulativeCostUsd: p.cumulativeCostUsd
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
    /// Non-nil when the stream that produced this message terminated in an
    /// errored/cancelled state. The UI renders messages with `errorText`
    /// using a warning accent + the error text + (if any) the partial content
    /// captured before the failure. Provider/model identification is still
    /// populated so a future retry has all the data it needs.
    public let errorText: String?

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
            editedAt: p.hasEditedAt ? p.editedAt.date : nil,
            errorText: p.hasErrorText ? p.errorText : nil
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

/// Sentinel naming a non-server title generator. v1 case is on-device
/// generation via Apple's FoundationModels framework on macOS 26+.
public enum ClarkTitleProviderKind {
    /// Wire string for `title_provider_kind = "apple_foundation"`. Surfacing
    /// this as a constant rather than a raw string avoids typos at every
    /// call site that switches on it.
    public static let appleFoundation = "apple_foundation"
}

public struct ClarkProfile: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let parentOnly: Bool
    public let favorite: Bool
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
    /// Sentinel for non-server title generation (e.g.
    /// `ClarkTitleProviderKind.appleFoundation`). When set, the server
    /// skips its cloud title call and the client owns title generation.
    public let titleProviderKind: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: String,
        name: String,
        description: String = "",
        parentOnly: Bool = false,
        favorite: Bool = false,
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
        titleProviderKind: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parentOnly = parentOnly
        self.favorite = favorite
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
        self.titleProviderKind = titleProviderKind
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
            description: p.description_p,
            parentOnly: p.parentOnly,
            favorite: p.favorite,
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
            titleProviderKind:     p.hasTitleProviderKind     ? p.titleProviderKind     : nil,
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
