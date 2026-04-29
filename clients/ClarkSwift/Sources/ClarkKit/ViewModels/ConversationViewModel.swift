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
    /// Optional client-side title generator. When the conversation's profile
    /// resolves to `title_provider_kind == "apple_foundation"`, the server
    /// skips its cloud title call and this generator runs locally instead.
    /// Nil on platforms that don't ship a local implementation — the kind
    /// sentinel is then a no-op and titles stay blank until the user renames.
    private let localTitler: LocalTitler?

    /// Tracks whether `maybeGenerateLocalTitle` has fired for this
    /// conversation in the current view-model lifetime. Each
    /// ConversationViewModel is recreated when the user navigates away and
    /// back (see ConversationView's `task(id: conversation.id)`), so this
    /// resets cleanly on context-change. Idempotent across in-flight calls
    /// — we only fire once per open.
    private var localTitleAttempted = false

    /// Snapshot of the profile cache (keyed by id) used by
    /// `maybeGenerateLocalTitle` to walk the parent chain. Populated by
    /// ConversationView after the conversation loads; refreshed when the
    /// user navigates back to a conversation.
    public var localTitleProfilesByID: [String: ClarkProfile] = [:]

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
    /// When true, the conversation pane swaps the message scroll for a
    /// full Compact page (per the "no popups" rule). The page lets the
    /// user edit the compression prompt and pick a model per-invocation
    /// before kicking off compaction. Replaces the old confirmation dialog.
    public var showingCompactView: Bool = false
    /// Editable per-call compression prompt. Pre-populated from the
    /// resolved profile's `compressionGuide` when the Compact page opens
    /// (via `prepareCompactView`). Edits don't persist to the profile.
    public var compactPromptDraft: String = ""
    /// Per-call compression provider/model selection. Pre-populated from
    /// the resolved profile when the Compact page opens; user can pick
    /// any other enabled (provider, model) pair. Forwarded as overrides
    /// on the Compact RPC.
    public var compactProviderID: String?
    public var compactModelID: String?
    /// Tracks `prepareCompactView` lifecycle so the page can render a
    /// loading indicator while the resolved profile is being fetched.
    public var preparingCompactView = false

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

    /// Total spend across every context in this conversation, summed from
    /// the per-context aggregate the server stamps on `ClarkContext.cumulativeCostUsd`.
    /// Surfaces in the title bar so the user sees lifetime conversation cost
    /// regardless of which context is active.
    public var conversationCost: Double {
        contexts.map(\.cumulativeCostUsd).reduce(0, +)
    }

    /// Stable per-context ordinal — oldest = 1, newest = N — derived from
    /// creation order. Used as the fallback "Context N" label when a context
    /// has no title, so the contexts page, navigation subtitle, and parent
    /// references all agree on the same number.
    public func contextNumber(for id: String) -> Int? {
        let asc = contexts.sorted { $0.createdAt < $1.createdAt }
        guard let idx = asc.firstIndex(where: { $0.id == id }) else { return nil }
        return idx + 1
    }

    public var costToDate: Double {
        messages.compactMap(\.totalCostUsd).reduce(0, +)
    }

    public var hasPendingCompression: Bool {
        // Errored compression_summary messages are first-class history
        // entries, NOT pending work — the user retries by deleting the
        // failed summary or kicking off a fresh compaction. Only clean
        // (non-errored) summaries gate the conversation.
        messages.contains { $0.role == .compressionSummary && $0.errorText == nil }
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
        onTerminal: @MainActor @escaping () async -> Void,
        localTitler: LocalTitler? = nil
    ) {
        self.conversation = conversation
        self.client = client
        self.onTerminal = onTerminal
        self.localTitler = localTitler
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

    // MARK: Local (on-device) title generation

    /// Decides whether this open should run the local title generator and,
    /// if so, fires it. Conditions (all must hold):
    ///   - a `LocalTitler` was injected (platform supports on-device gen)
    ///   - the local model is `isAvailable` right now
    ///   - this view-model hasn't already attempted titling this open
    ///   - the conversation currently has no title (server might also be
    ///     racing; idempotency through the existing UpdateConversation RPC
    ///     keeps both paths safe)
    ///   - the profile's resolved `title_provider_kind ==
    ///     "apple_foundation"`
    ///   - at least two real (user/assistant) messages exist — enough
    ///     signal to title meaningfully
    /// On success, persists via `updateTitle` and refreshes the sidebar so
    /// the title shows up live without a re-mount.
    public func maybeGenerateLocalTitle(profilesByID: [String: ClarkProfile]) async {
        // Cache the latest profile snapshot so terminal-stream-driven
        // re-attempts can resolve without the view passing the map again.
        if !profilesByID.isEmpty {
            localTitleProfilesByID = profilesByID
        }
        guard let titler = localTitler else { return }
        guard !localTitleAttempted else { return }
        guard titler.isAvailable else { return }
        // Read the live conversation title — if another path already set one
        // (manual rename, server, parallel client) skip silently.
        if !(conversation.title ?? "").isEmpty { return }
        let resolveMap = profilesByID.isEmpty ? localTitleProfilesByID : profilesByID
        // Determine the resolved profile kind. The cheap path: walk the
        // local profile cache up the parent chain (mirrors server-side
        // `Resolve` first-non-null logic). The Mac client always loads the
        // full profile list at startup, so the cache should be populated.
        guard resolvedTitleProviderKind(profilesByID: resolveMap) == ClarkTitleProviderKind.appleFoundation else { return }
        let realMessages = messages.filter { $0.role == .user || $0.role == .assistant }
        guard realMessages.count >= 2 else { return }

        localTitleAttempted = true
        let transcript = renderLocalTitleTranscript(realMessages)
        guard !transcript.isEmpty else { return }
        let guide = resolvedTitleGuide(profilesByID: resolveMap)

        do {
            let title = try await titler.generateTitle(transcript: transcript, guide: guide)
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            _ = try await client.conversations.updateTitle(id: conversation.id, title: trimmed)
            // Bubble the new title into the sidebar without a re-mount.
            await onTerminal()
        } catch {
            // Non-fatal — leave the title blank; the user can rename.
        }
    }

    /// First-non-null walk of `title_provider_kind` up the parent chain.
    /// Mirrors server-side `profiles.Resolve`. Cycle-safe (8 hops).
    /// Package-internal so unit tests can exercise the resolver without
    /// constructing a full ConversationViewModel against a live network.
    func resolvedTitleProviderKind(profilesByID: [String: ClarkProfile]) -> String? {
        guard var current = profilesByID[conversation.profileID] else { return nil }
        if let kind = current.titleProviderKind, !kind.isEmpty { return kind }
        var seen: Set<String> = [current.id]
        var depth = 0
        while let pid = current.parentProfileID, !seen.contains(pid), depth < 8 {
            seen.insert(pid)
            depth += 1
            guard let parent = profilesByID[pid] else { return nil }
            if let kind = parent.titleProviderKind, !kind.isEmpty { return kind }
            current = parent
        }
        return nil
    }

    /// First-non-null walk of `title_guide` up the parent chain.
    private func resolvedTitleGuide(profilesByID: [String: ClarkProfile]) -> String? {
        guard var current = profilesByID[conversation.profileID] else { return nil }
        if let g = current.titleGuide, !g.isEmpty { return g }
        var seen: Set<String> = [current.id]
        var depth = 0
        while let pid = current.parentProfileID, !seen.contains(pid), depth < 8 {
            seen.insert(pid)
            depth += 1
            guard let parent = profilesByID[pid] else { return nil }
            if let g = parent.titleGuide, !g.isEmpty { return g }
            current = parent
        }
        return nil
    }

    private func renderLocalTitleTranscript(_ msgs: [ClarkMessage]) -> String {
        // Match the server's tiny-transcript shape (user → assistant) so the
        // local model gets prompted with a familiar pattern.
        var lines: [String] = []
        for m in msgs.prefix(4) {  // first two turns is plenty of signal
            let label = m.role == .user ? "[user]" : "[assistant]"
            let text = (m.displayContent ?? m.content).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            lines.append("\(label): \(text)")
        }
        return lines.joined(separator: "\n\n")
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
                        // First assistant turn just landed — give the local
                        // titler a chance. Idempotent: bails immediately if
                        // already attempted, profile isn't apple_foundation,
                        // or another path beat us to setting the title.
                        await maybeGenerateLocalTitle(profilesByID: localTitleProfilesByID)
                    case .failed:
                        // The supervisor materializes a real assistant
                        // message row (with content + error_payload) on
                        // errored runs, so the right thing to do is reload
                        // the message list and let MessageRow render the
                        // failure inline. No banner — the errored message
                        // is now first-class history.
                        await load()
                        await onTerminal()
                        streamingText = ""
                        streamRunID = nil
                    }
                }
            }
        } catch {
            // Pre-stream RPC failure (validation, network before the
            // server even spawned a run): no message row exists. Reload
            // so any optimistic state clears, but also keep the inline
            // error for the composer banner since there's nothing in the
            // history to surface it.
            pendingUserText = nil
            await load()
            loadError = error.localizedDescription
        }
    }

    public func cancelStream() {
        guard let id = streamRunID else { return }
        Task { try? await client.streams.cancel(streamRunID: id) }
    }

    // MARK: Compact

    /// Pre-populates `compactPromptDraft` / `compactProviderID` /
    /// `compactModelID` from the resolved profile so the Compact page opens
    /// with the user's "default" compression settings already filled in.
    /// Resolves through the profile inheritance chain by asking the server
    /// for the resolved view (`GetProfileRequest.resolve = true`). On
    /// failure the page just opens with empty fields — non-fatal.
    public func prepareCompactView() async {
        preparingCompactView = true
        defer { preparingCompactView = false }
        do {
            let (_, resolved) = try await client.profiles.get(id: conversation.profileID, resolve: true)
            guard let resolved else { return }
            compactPromptDraft = resolved.compressionGuide ?? ""
            compactProviderID  = resolved.compressionProviderID
            compactModelID     = resolved.compressionModelID
        } catch {
            // Non-fatal — the user just sees blanks and picks values
            // themselves. They get a clearer error from the Compact RPC if
            // things still aren't right when they hit submit.
        }
    }

    /// Trigger compaction, optionally with per-call overrides for prompt
    /// and (provider, model). The Compact page passes its current draft
    /// values; the toolbar's old "compact directly" path can call with
    /// no arguments to use the profile's resolved settings.
    public func compact(
        guide: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil
    ) async {
        guard !isCompacting, !sending else { return }
        isCompacting = true
        compactError = nil
        do {
            let run = try await client.conversations.compact(
                conversationID: conversation.id,
                guide: guide,
                providerID: providerID,
                modelID: modelID
            )
            streamRunID = run.id
            streamingText = ""
            streamTask?.cancel()
            streamTask = Task { @MainActor in
                for await event in client.streams.subscribe(streamRunID: run.id) {
                    switch event {
                    case .chunk(let c):
                        // Render compression chunks the same way send() does so
                        // the user sees the summary build in real time, instead
                        // of staring at a "Summarizing…" placeholder. The
                        // running text gets cleared when the terminal `load()`
                        // pulls in the materialized compression_summary message.
                        if c.type == .textDelta, let s = c.textIfDelta {
                            streamingText += s
                        }
                    case .terminal:
                        isCompacting = false
                        streamRunID = nil
                        streamingText = ""
                        await load()
                        await onTerminal()
                    case .failed:
                        // Errored compaction now materializes a real
                        // compression_summary row in the source context
                        // (with empty/partial content + the error
                        // captured inline). Reload so the user sees the
                        // failure as a first-class card in the
                        // conversation, with the error text + a Dismiss
                        // affordance — instead of bouncing them back
                        // into the Compact page under a banner.
                        isCompacting = false
                        streamRunID = nil
                        streamingText = ""
                        await load()
                        await onTerminal()
                    }
                }
            }
        } catch {
            // Pre-stream RPC failure — no run was created so there's no
            // errored summary to render. Surface the error inline on the
            // Compact page so the user can adjust the prompt or model
            // picker and try again.
            isCompacting = false
            compactError = error.localizedDescription
            showingCompactView = true
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
