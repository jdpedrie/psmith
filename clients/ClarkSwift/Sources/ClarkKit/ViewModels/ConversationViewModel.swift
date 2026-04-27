import Foundation
import Observation

/// Per-conversation orchestration: messages, send + stream, compaction,
/// context switching, message edits, model selection.
/// Reusable across macOS / iOS.
@Observable
@MainActor
public final class ConversationViewModel {
    public let conversation: ClarkConversation
    private let client: ClarkClient
    private let onTerminal: @MainActor () async -> Void

    // Load state
    public var activeContext: ClarkContext?
    public var messages: [ClarkMessage] = []
    public var loadError: String?
    public var loading = false

    // Send state
    public var draft: String = ""
    public var sending = false
    public var streamingText: String = ""
    public var streamRunID: String?
    private var streamTask: Task<Void, Never>?
    /// Optimistic user message text shown before the RPC returns.
    public var pendingUserText: String?

    // Compact state
    public var isCompacting = false
    public var compactError: String?
    public var showCompactConfirm = false

    // Edit state
    public var editingMessage: ClarkMessage?

    // Context switcher
    public var contexts: [ClarkContext] = []
    /// When true, the conversation pane swaps the message scroll for a
    /// full context-list view (per the "no popups" rule). Toggled from the
    /// title menu's "View contexts…" entry.
    public var showingContextList: Bool = false

    // Model switcher
    public var availableModels: [ClarkUserModel] = []
    public var providerLabels: [String: String] = [:]
    public var selectedProviderID: String?
    public var selectedModelID: String?

    // Token count (advisory; nil when unavailable)
    public var tokenCount: Int32?
    public var contextWindow: Int32?

    // MARK: Computed

    public var costToDate: Double {
        messages.compactMap(\.totalCostUsd).reduce(0, +)
    }

    public var hasPendingCompression: Bool {
        messages.contains { $0.role == .compressionSummary }
    }

    public var isStreaming: Bool { streamRunID != nil && !isCompacting }

    /// Provider + model from the most recent assistant message — used for
    /// CountContextTokens. Nil when no assistant message exists yet.
    private var tokenCountTarget: (providerID: String, modelID: String)? {
        for msg in messages.reversed() where msg.role == .assistant {
            if let p = msg.providerID, let m = msg.modelID {
                return (p, m)
            }
        }
        return nil
    }

    public init(
        conversation: ClarkConversation,
        client: ClarkClient,
        onTerminal: @MainActor @escaping () async -> Void
    ) {
        self.conversation = conversation
        self.client = client
        self.onTerminal = onTerminal
    }

    // MARK: Load

    public func load() async {
        loading = true
        defer { loading = false }
        do {
            let (_, ctx) = try await client.conversations.get(id: conversation.id)
            self.activeContext = ctx
            self.messages = try await client.conversations.listMessages(contextID: ctx.id)
            self.loadError = nil
            // Seed model selection from last assistant message (always tracks latest used).
            if let target = tokenCountTarget {
                selectedProviderID = target.providerID
                selectedModelID    = target.modelID
            }
            await refreshTokenCount()
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    public func loadAvailableModels() async {
        do {
            let providers = try await client.modelProviders.list()
            providerLabels = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.label) })
            availableModels = try await withThrowingTaskGroup(of: [ClarkUserModel].self) { group in
                for p in providers {
                    group.addTask { try await self.client.modelProviders.listModels(providerID: p.id) }
                }
                var all: [ClarkUserModel] = []
                for try await models in group { all.append(contentsOf: models) }
                return all.sorted { $0.displayName < $1.displayName }
            }
        } catch {
            // Non-fatal; model picker stays hidden if unavailable
        }
    }

    // MARK: Token count

    public func refreshTokenCount() async {
        guard let ctx = activeContext, let target = tokenCountTarget else { return }
        do {
            let result = try await client.conversations.countContextTokens(
                contextID: ctx.id,
                providerID: target.providerID,
                modelID: target.modelID
            )
            self.tokenCount = result.tokenCount
            self.contextWindow = result.contextWindow
        } catch {
            // Token count is advisory; don't surface errors
        }
    }

    // MARK: Send

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !isCompacting, !hasPendingCompression else { return }
        draft = ""
        sending = true
        streamingText = ""
        // Show message optimistically before the RPC round-trip completes.
        pendingUserText = text
        defer { sending = false }

        do {
            let (userMsg, run) = try await client.conversations.sendMessage(
                conversationID: conversation.id,
                content: text,
                providerID: selectedProviderID,
                modelID: selectedModelID
            )
            pendingUserText = nil
            messages.append(userMsg)
            streamRunID = run.id

            streamTask?.cancel()
            streamTask = Task { @MainActor in
                for await event in client.streams.subscribe(streamRunID: run.id) {
                    switch event {
                    case .chunk(let c):
                        if c.type == .textDelta, let s = c.textIfDelta {
                            streamingText += s
                        }
                    case .terminal:
                        await load()
                        await onTerminal()
                        streamingText = ""
                        streamRunID = nil
                    case .failed(let err):
                        loadError = err.localizedDescription
                        streamingText = ""
                        streamRunID = nil
                    }
                }
            }
        } catch {
            pendingUserText = nil
            loadError = error.localizedDescription
        }
    }

    public func cancelStream() {
        guard let id = streamRunID else { return }
        Task { try? await client.streams.cancel(streamRunID: id) }
    }

    // MARK: Compact

    public func compact() async {
        guard !isCompacting, !sending else { return }
        isCompacting = true
        compactError = nil
        do {
            let run = try await client.conversations.compact(conversationID: conversation.id)
            streamRunID = run.id
            streamTask?.cancel()
            streamTask = Task { @MainActor in
                for await event in client.streams.subscribe(streamRunID: run.id) {
                    switch event {
                    case .chunk: break // Compaction chunks aren't displayed
                    case .terminal:
                        isCompacting = false
                        streamRunID = nil
                        await load()
                        await onTerminal()
                    case .failed(let err):
                        isCompacting = false
                        streamRunID = nil
                        compactError = err.localizedDescription
                    }
                }
            }
        } catch {
            isCompacting = false
            compactError = error.localizedDescription
        }
    }

    public func promoteCompaction(messageID: String) async {
        do {
            _ = try await client.conversations.promoteCompactionToNewContext(messageID: messageID)
            tokenCount = nil
            contextWindow = nil
            await load()
            await loadContexts()
            await onTerminal()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Context switching

    public func loadContexts() async {
        do {
            contexts = try await client.conversations.listContexts(conversationID: conversation.id)
        } catch {
            // Non-fatal; context switcher stays empty
        }
    }

    public func activateContext(_ contextID: String) async {
        do {
            let ctx = try await client.conversations.activateContext(contextID: contextID)
            activeContext = ctx
            tokenCount = nil
            contextWindow = nil
            await load()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Message mutations

    public func editMessage(id: String, content: String) async {
        do {
            let updated = try await client.conversations.editMessage(id: id, content: content)
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx] = updated
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func deleteMessage(id: String, cascade: Bool = false) async {
        do {
            try await client.conversations.deleteMessage(id: id, cascade: cascade)
            await load()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
