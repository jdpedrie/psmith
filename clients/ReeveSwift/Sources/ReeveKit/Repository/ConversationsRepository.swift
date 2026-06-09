import Foundation
import Connect

public final class ConversationsRepository: Sendable {
    private let client: Reeve_V1_ConversationsServiceClientInterface
    private let cache: ReeveCache?

    public init(
        client: Reeve_V1_ConversationsServiceClientInterface,
        cache: ReeveCache? = nil
    ) {
        self.client = client
        self.cache = cache
    }

    public func list(
        pageSize: Int32 = 100,
        pageToken: String? = nil,
        order: ReeveConversationOrder? = nil,
        titleQuery: String? = nil,
        profileID: String? = nil
    ) async throws -> (items: [ReeveConversation], nextPageToken: String?) {
        var req = Reeve_V1_ListConversationsRequest()
        req.pageSize = pageSize
        if let pageToken { req.pageToken = pageToken }
        if let order { req.order = order.proto }
        if let titleQuery, !titleQuery.isEmpty { req.titleQuery = titleQuery }
        if let profileID { req.profileID = profileID }

        // Bounded by a short timeout: on a dead server the default
        // URLSession wait is ~60s, which pins the launch spinner.
        // The cache fallback below absorbs the failure (timeout
        // included) so the user lands on cached data instead.
        let frozenReq = req
        let resp = try? await withRPCTimeout(seconds: 6) { [client] in
            await client.listConversations(request: frozenReq, headers: [:])
        }
        if let msg = resp?.message {
            let items = msg.conversations.map(ReeveConversation.init(from:))
            // Cache only the unfiltered first page — that's what
            // ChatsRoot loads on launch, and it's the version that
            // actually matters offline. Filtered/paged calls are
            // cosmetic features that can be skipped offline.
            if pageToken == nil && titleQuery == nil && profileID == nil,
               let cache {
                try? await cache.set(items, kind: CacheKind.conversationsList, id: "all", capBytes: CachePreferences.capBytes)
            }
            return (items, msg.nextPageToken.isEmpty ? nil : msg.nextPageToken)
        }
        // Server failed (or timed out). If this is the unfiltered
        // first-page call, try the cache before re-throwing so the
        // user lands on a populated list rather than an error screen.
        if pageToken == nil && titleQuery == nil && profileID == nil,
           let cache,
           let cached: [ReeveConversation] = await cache.get([ReeveConversation].self, kind: CacheKind.conversationsList, id: "all") {
            return (cached, nil)
        }
        throw resp?.error.map(ReeveError.from) ?? .missingPayload("list conversations")
    }

    public func get(id: String) async throws -> (ReeveConversation, ReeveContext) {
        var req = Reeve_V1_GetConversationRequest()
        req.id = id
        let resp = await client.getConversation(request: req, headers: [:])
        if let msg = resp.message {
            let conv = ReeveConversation(from: msg.conversation)
            let ctx = ReeveContext(from: msg.activeContext)
            if let cache {
                // Two entries so the conversation row and the active
                // context can age independently — opening a different
                // context shouldn't keep a stale conversation row warm
                // and vice versa.
                try? await cache.set(conv, kind: "conversation", id: id, capBytes: CachePreferences.capBytes)
                try? await cache.set(ctx, kind: "activeContext", id: id, capBytes: CachePreferences.capBytes)
            }
            return (conv, ctx)
        }
        if let cache,
           let conv: ReeveConversation = await cache.get(ReeveConversation.self, kind: "conversation", id: id),
           let ctx: ReeveContext = await cache.get(ReeveContext.self, kind: "activeContext", id: id) {
            return (conv, ctx)
        }
        throw resp.error.map(ReeveError.from) ?? .missingPayload("get conversation")
    }

    public func create(
        profileID: String,
        title: String? = nil,
        settings: ReeveConversationSettings? = nil
    ) async throws -> ReeveConversation {
        var req = Reeve_V1_CreateConversationRequest()
        req.profileID = profileID
        if let title { req.title = title }
        if let settings { req.settings = settings.proto }
        let resp = await client.createConversation(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("create conversation") }
        return ReeveConversation(from: msg.conversation)
    }

    public func delete(id: String) async throws {
        var req = Reeve_V1_DeleteConversationRequest()
        req.id = id
        let resp = await client.deleteConversation(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ReeveError.from(err) }
    }

    /// Updates the conversation's title. Pass `nil` to leave it unchanged;
    /// pass an empty string to clear it back to NULL. Used by the Mac
    /// client's on-device titler to push a locally-generated title back to
    /// the server (the same call any other UI uses for manual rename).
    @discardableResult
    public func updateTitle(id: String, title: String) async throws -> ReeveConversation {
        var req = Reeve_V1_UpdateConversationRequest()
        req.id = id
        req.title = title
        let resp = await client.updateConversation(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("update conversation") }
        return ReeveConversation(from: msg.conversation)
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
        settings: ReeveConversationSettings
    ) async throws -> ReeveConversation {
        var req = Reeve_V1_UpdateConversationRequest()
        req.id = id
        if let title { req.title = title }
        req.settings = settings.proto
        let resp = await client.updateConversation(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("update conversation") }
        return ReeveConversation(from: msg.conversation)
    }

    public func sendMessage(
        conversationID: String,
        content: String,
        parentMessageID: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        attachmentFileIDs: [String] = [],
        deviceFacts: [ReeveDeviceFact] = []
    ) async throws -> (userMessage: ReeveMessage, streamRun: ReeveStreamRun) {
        var req = Reeve_V1_SendMessageRequest()
        req.conversationID = conversationID
        req.content = content
        if let parentMessageID { req.parentMessageID = parentMessageID }
        if let providerID { req.providerID = providerID }
        if let modelID { req.modelID = modelID }
        if !attachmentFileIDs.isEmpty { req.attachmentFileIds = attachmentFileIDs }
        if !deviceFacts.isEmpty { req.deviceFacts = deviceFacts.map { $0.proto } }
        let resp = await client.sendMessage(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("send message") }
        return (ReeveMessage(from: msg.userMessage), ReeveStreamRun(from: msg.streamRun))
    }

    /// Regenerate-mode SendMessage. Server-side this skips the user-row
    /// insert and starts the assistant stream off `parentMessageID`
    /// directly. Two valid shapes:
    ///
    /// - parent.role == .user: the new assistant becomes a SIBLING of any
    ///   previous assistant under the same user message. Powers the
    ///   "Reload" affordance on assistant rows.
    /// - parent.role == .assistant: the new assistant chains AFTER the
    ///   parent assistant — produces two assistants in a row. Powers
    ///   "Save and Resend" on an edited assistant: the edit stays in
    ///   place and the model continues from there. Not all upstream
    ///   providers support a wire prefix that ends in assistant
    ///   (Anthropic does via prefill, OpenAI Chat may error). The server
    ///   surfaces upstream errors verbatim.
    ///
    /// Other roles are rejected by the server.
    public func regenerateAssistant(
        conversationID: String,
        parentMessageID: String,
        providerID: String? = nil,
        modelID: String? = nil
    ) async throws -> (parentMessage: ReeveMessage, streamRun: ReeveStreamRun) {
        var req = Reeve_V1_SendMessageRequest()
        req.conversationID = conversationID
        req.parentMessageID = parentMessageID
        req.regenerate = true
        if let providerID { req.providerID = providerID }
        if let modelID { req.modelID = modelID }
        let resp = await client.sendMessage(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("regenerate") }
        return (ReeveMessage(from: msg.userMessage), ReeveStreamRun(from: msg.streamRun))
    }

    public func listMessages(
        contextID: String,
        leafMessageID: String? = nil,
        fullTree: Bool = false
    ) async throws -> [ReeveMessage] {
        var req = Reeve_V1_ListMessagesRequest()
        req.contextID = contextID
        if let leafMessageID { req.leafMessageID = leafMessageID }
        // `full_tree=true` swaps the server from the linear-ancestor-chain
        // CTE to a flat ListMessagesByContext dump — used by the branch
        // switcher in the client to discover sibling IDs and walk down to
        // the deepest descendant of a chosen fork.
        req.fullTree = fullTree
        let resp = await client.listMessages(request: req, headers: [:])
        if let msg = resp.message {
            let items = msg.messages.map(ReeveMessage.init(from:))
            // Cache the linear-chain shape only (fullTree blobs would
            // double-spend the cap on every conversation with branches).
            // Per-leaf overrides are skipped too — the client only
            // requests them when actively branch-switching.
            if !fullTree && leafMessageID == nil, let cache {
                try? await cache.set(items, kind: CacheKind.messagesByContext, id: contextID, capBytes: CachePreferences.capBytes)
            }
            return items
        }
        if !fullTree && leafMessageID == nil,
           let cache,
           let cached: [ReeveMessage] = await cache.get([ReeveMessage].self, kind: CacheKind.messagesByContext, id: contextID) {
            return cached
        }
        throw resp.error.map(ReeveError.from) ?? .missingPayload("list messages")
    }

    /// Repositions the per-context leaf cursor to the given message — the
    /// branch the user is currently viewing in this context. The next
    /// SendMessage without an explicit parent will fork off this leaf;
    /// `listMessages` with no leafMessageID returns the chain ending at it.
    /// Pass `messageID = nil` to clear the cursor (server falls back to
    /// latest-by-created_at on the next send).
    public func setCurrentLeaf(contextID: String, messageID: String?) async throws {
        var req = Reeve_V1_SetCurrentLeafRequest()
        req.contextID = contextID
        // Empty string is the "clear" sentinel per the proto comment.
        req.messageID = messageID ?? ""
        let resp = await client.setCurrentLeaf(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ReeveError.from(err) }
    }

    public func countContextTokens(contextID: String, providerID: String, modelID: String) async throws -> (tokenCount: Int32, contextWindow: Int32) {
        var req = Reeve_V1_CountContextTokensRequest()
        req.contextID = contextID
        req.providerID = providerID
        req.modelID = modelID
        let resp = await client.countContextTokens(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("count context tokens") }
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
    ) async throws -> ReeveStreamRun {
        var req = Reeve_V1_CompactRequest()
        req.conversationID = conversationID
        if let guide      { req.compressionGuide      = guide }
        if let providerID { req.compressionProviderID = providerID }
        if let modelID    { req.compressionModelID    = modelID }
        let resp = await client.compact(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("compact") }
        return ReeveStreamRun(from: msg.streamRun)
    }

    public func promoteCompactionToNewContext(messageID: String) async throws -> ReeveContext {
        var req = Reeve_V1_PromoteCompactionToNewContextRequest()
        req.messageID = messageID
        let resp = await client.promoteCompactionToNewContext(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("promote compaction") }
        return ReeveContext(from: msg.context)
    }

    /// Manually creates a fresh active context in an existing conversation
    /// without going through compression. Mode selects whether the new
    /// context inherits the prior context's framing (APPEND) or starts
    /// fresh (REPLACE / unspecified).
    public func createContextManual(
        conversationID: String,
        initialUserMessage: String,
        mode: ReeveCompressionMode
    ) async throws -> (context: ReeveContext, userMessage: ReeveMessage?) {
        var req = Reeve_V1_CreateContextManualRequest()
        req.conversationID = conversationID
        req.initialUserMessage = initialUserMessage
        req.mode = mode.toProto()
        let resp = await client.createContextManual(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("create context manual") }
        let userMsg: ReeveMessage? = msg.hasUserMessage ? ReeveMessage(from: msg.userMessage) : nil
        return (ReeveContext(from: msg.context), userMsg)
    }

    public func editMessage(
        id: String,
        content: String,
        role: ReeveMessageRole? = nil
    ) async throws -> ReeveMessage {
        var req = Reeve_V1_EditMessageRequest()
        req.id = id
        req.content = content
        // Optional role override. The server accepts only user/assistant
        // here (system/context/summary stay locked); we let the server
        // enforce that and surface the error if the caller passes an
        // invalid role.
        if let role {
            req.role = role.toProto()
        }
        let resp = await client.editMessage(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("edit message") }
        return ReeveMessage(from: msg.message)
    }

    public func deleteMessage(id: String, cascade: Bool = false) async throws {
        var req = Reeve_V1_DeleteMessageRequest()
        req.id = id
        req.cascade = cascade
        let resp = await client.deleteMessage(request: req, headers: [:])
        if resp.message == nil, let err = resp.error { throw ReeveError.from(err) }
    }

    public func listContexts(conversationID: String) async throws -> [ReeveContext] {
        var req = Reeve_V1_ListContextsRequest()
        req.conversationID = conversationID
        let resp = await client.listContexts(request: req, headers: [:])
        if let msg = resp.message {
            let items = msg.contexts.map(ReeveContext.init(from:))
            if let cache {
                try? await cache.set(items, kind: CacheKind.contextsByConversation, id: conversationID, capBytes: CachePreferences.capBytes)
            }
            return items
        }
        if let cache,
           let cached: [ReeveContext] = await cache.get([ReeveContext].self, kind: CacheKind.contextsByConversation, id: conversationID) {
            return cached
        }
        throw resp.error.map(ReeveError.from) ?? .missingPayload("list contexts")
    }

    public func activateContext(contextID: String) async throws -> ReeveContext {
        var req = Reeve_V1_ActivateContextRequest()
        req.contextID = contextID
        let resp = await client.activateContext(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("activate context") }
        return ReeveContext(from: msg.context)
    }

    // MARK: - Conversation plugin overrides

    /// Read the conversation's literal plugin overrides (not the merged view).
    /// Empty list means the conversation falls back to the profile-chain pipeline.
    public func getPlugins(conversationID: String) async throws -> [ReeveConversationPlugin] {
        var req = Reeve_V1_GetConversationPluginsRequest()
        req.conversationID = conversationID
        let resp = await client.getConversationPlugins(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("get conversation plugins") }
        return msg.plugins.map(ReeveConversationPlugin.init(from:))
    }

    /// Atomically replace the conversation's plugin overrides. Pass an empty
    /// list to clear all overrides (the conversation falls back to the
    /// profile-chain pipeline). `disabled: true` entries subtract a same-name
    /// inherited plugin from this conversation's resolved pipeline.
    @discardableResult
    public func setPlugins(conversationID: String, plugins: [ReeveConversationPlugin]) async throws -> [ReeveConversationPlugin] {
        var req = Reeve_V1_SetConversationPluginsRequest()
        req.conversationID = conversationID
        req.plugins = plugins.map { $0.proto }
        let resp = await client.setConversationPlugins(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("set conversation plugins") }
        return msg.plugins.map(ReeveConversationPlugin.init(from:))
    }

    /// Returns the merged view of the conversation's pipeline — profile chain
    /// plus conversation overrides, with `disabled` subtracts already applied.
    /// Each entry is tagged with where it came from.
    public func resolvePipeline(conversationID: String) async throws -> [ReeveResolvedPipelineEntry] {
        var req = Reeve_V1_ResolveConversationPipelineRequest()
        req.conversationID = conversationID
        let resp = await client.resolveConversationPipeline(request: req, headers: [:])
        guard let msg = resp.message else { throw resp.error.map(ReeveError.from) ?? .missingPayload("resolve conversation pipeline") }
        return msg.entries.map(ReeveResolvedPipelineEntry.init(from:))
    }
}

extension ReeveError {
    public static func from(_ err: ConnectError) -> ReeveError {
        .rpc(code: err.code, message: err.message ?? err.code.name)
    }
}
