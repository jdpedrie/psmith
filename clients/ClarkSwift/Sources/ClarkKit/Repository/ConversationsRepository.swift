import Foundation
import Connect

public final class ConversationsRepository: Sendable {
    private let client: Clark_V1_ConversationsServiceClientInterface

    public init(client: Clark_V1_ConversationsServiceClientInterface) {
        self.client = client
    }

    public func list(
        pageSize: Int32 = 100,
        pageToken: String? = nil,
        order: ClarkConversationOrder? = nil,
        titleQuery: String? = nil,
        profileID: String? = nil
    ) async throws -> (items: [ClarkConversation], nextPageToken: String?) {
        var req = Clark_V1_ListConversationsRequest()
        req.pageSize = pageSize
        if let pageToken { req.pageToken = pageToken }
        if let order { req.order = order.proto }
        if let titleQuery, !titleQuery.isEmpty { req.titleQuery = titleQuery }
        if let profileID { req.profileID = profileID }

        let resp = await client.listConversations(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list conversations") }
        let items = msg.conversations.map(ClarkConversation.init(from:))
        return (items, msg.nextPageToken.isEmpty ? nil : msg.nextPageToken)
    }

    public func get(id: String) async throws -> (ClarkConversation, ClarkContext) {
        var req = Clark_V1_GetConversationRequest()
        req.id = id
        let resp = await client.getConversation(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("get conversation") }
        return (ClarkConversation(from: msg.conversation), ClarkContext(from: msg.activeContext))
    }

    public func create(
        profileID: String,
        title: String? = nil,
        settings: ClarkConversationSettings? = nil
    ) async throws -> ClarkConversation {
        var req = Clark_V1_CreateConversationRequest()
        req.profileID = profileID
        if let title { req.title = title }
        if let settings { req.settings = settings.proto }
        let resp = await client.createConversation(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("create conversation") }
        return ClarkConversation(from: msg.conversation)
    }

    public func delete(id: String) async throws {
        var req = Clark_V1_DeleteConversationRequest()
        req.id = id
        let resp = await client.deleteConversation(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ClarkError.from(err) }
    }

    /// Updates the conversation's title. Pass `nil` to leave it unchanged;
    /// pass an empty string to clear it back to NULL. Used by the Mac
    /// client's on-device titler to push a locally-generated title back to
    /// the server (the same call any other UI uses for manual rename).
    @discardableResult
    public func updateTitle(id: String, title: String) async throws -> ClarkConversation {
        var req = Clark_V1_UpdateConversationRequest()
        req.id = id
        req.title = title
        let resp = await client.updateConversation(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("update conversation") }
        return ClarkConversation(from: msg.conversation)
    }

    /// Updates the conversation's per-conversation settings — bound to
    /// `conversations.settings` JSONB. Pass `nil` for `title` to leave it
    /// unchanged. The server replaces (not merges) the settings blob, so
    /// callers should pass the *full* desired settings shape (typically
    /// loaded via `get`, mutated, then sent back).
    @discardableResult
    public func updateSettings(
        id: String,
        title: String? = nil,
        settings: ClarkConversationSettings
    ) async throws -> ClarkConversation {
        var req = Clark_V1_UpdateConversationRequest()
        req.id = id
        if let title { req.title = title }
        req.settings = settings.proto
        let resp = await client.updateConversation(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("update conversation") }
        return ClarkConversation(from: msg.conversation)
    }

    public func sendMessage(
        conversationID: String,
        content: String,
        parentMessageID: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil
    ) async throws -> (userMessage: ClarkMessage, streamRun: ClarkStreamRun) {
        var req = Clark_V1_SendMessageRequest()
        req.conversationID = conversationID
        req.content = content
        if let parentMessageID { req.parentMessageID = parentMessageID }
        if let providerID { req.providerID = providerID }
        if let modelID { req.modelID = modelID }
        let resp = await client.sendMessage(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("send message") }
        return (ClarkMessage(from: msg.userMessage), ClarkStreamRun(from: msg.streamRun))
    }

    public func listMessages(contextID: String, leafMessageID: String? = nil) async throws -> [ClarkMessage] {
        var req = Clark_V1_ListMessagesRequest()
        req.contextID = contextID
        if let leafMessageID { req.leafMessageID = leafMessageID }
        let resp = await client.listMessages(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list messages") }
        return msg.messages.map(ClarkMessage.init(from:))
    }

    public func countContextTokens(contextID: String, providerID: String, modelID: String) async throws -> (tokenCount: Int32, contextWindow: Int32) {
        var req = Clark_V1_CountContextTokensRequest()
        req.contextID = contextID
        req.providerID = providerID
        req.modelID = modelID
        let resp = await client.countContextTokens(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("count context tokens") }
        return (msg.tokenCount, msg.contextWindow)
    }

    /// Trigger compression on the active context. The `guide` /
    /// `providerID` / `modelID` arguments, when non-nil, override the
    /// profile's resolved compression settings for this single call —
    /// nothing is persisted. Use this from the Compact page to let the
    /// user edit the prompt and pick a different model per-invocation.
    public func compact(
        conversationID: String,
        guide: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil
    ) async throws -> ClarkStreamRun {
        var req = Clark_V1_CompactRequest()
        req.conversationID = conversationID
        if let guide      { req.compressionGuide      = guide }
        if let providerID { req.compressionProviderID = providerID }
        if let modelID    { req.compressionModelID    = modelID }
        let resp = await client.compact(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("compact") }
        return ClarkStreamRun(from: msg.streamRun)
    }

    public func promoteCompactionToNewContext(messageID: String) async throws -> ClarkContext {
        var req = Clark_V1_PromoteCompactionToNewContextRequest()
        req.messageID = messageID
        let resp = await client.promoteCompactionToNewContext(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("promote compaction") }
        return ClarkContext(from: msg.context)
    }

    public func editMessage(id: String, content: String) async throws -> ClarkMessage {
        var req = Clark_V1_EditMessageRequest()
        req.id = id
        req.content = content
        let resp = await client.editMessage(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("edit message") }
        return ClarkMessage(from: msg.message)
    }

    public func deleteMessage(id: String, cascade: Bool = false) async throws {
        var req = Clark_V1_DeleteMessageRequest()
        req.id = id
        req.cascade = cascade
        let resp = await client.deleteMessage(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ClarkError.from(err) }
    }

    public func listContexts(conversationID: String) async throws -> [ClarkContext] {
        var req = Clark_V1_ListContextsRequest()
        req.conversationID = conversationID
        let resp = await client.listContexts(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("list contexts") }
        return msg.contexts.map(ClarkContext.init(from:))
    }

    public func activateContext(contextID: String) async throws -> ClarkContext {
        var req = Clark_V1_ActivateContextRequest()
        req.contextID = contextID
        let resp = await client.activateContext(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ClarkError.from) ?? .missingPayload("activate context") }
        return ClarkContext(from: msg.context)
    }
}

extension ClarkError {
    public static func from(_ err: ConnectError) -> ClarkError {
        .rpc(code: err.code, message: err.message ?? err.code.name)
    }
}
