import Foundation
import Observation

/// Per-conversation orchestration: messages, send + stream, compaction,
/// context switching, message edits, model selection.
/// Reusable across macOS / iOS.
@Observable
@MainActor
public final class ConversationViewModel {
    public let conversation: ReeveConversation
    private let client: ReeveClient
    private let onTerminal: @MainActor () async -> Void
    /// Fires after a successful assistant turn lands in `messages`. The
    /// app uses it to drive side effects that depend on completed turns
    /// (Mac notification when window isn't focused, future iOS push
    /// registration etc). Skipped on errored / cancelled runs — those
    /// already surface inline as failed-message rows. Optional so test
    /// fixtures can omit it.
    public typealias AssistantTurnCompleteHandler = @MainActor (
        _ conversationID: String,
        _ conversationTitle: String?,
        _ assistantMessageID: String,
        _ preview: String
    ) -> Void
    private let onAssistantTurnComplete: AssistantTurnCompleteHandler?
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
    public var localTitleProfilesByID: [String: ReeveProfile] = [:]

    // Load state
    public var activeContext: ReeveContext?
    public var messages: [ReeveMessage] = []
    public var loadError: String?
    public var loading = false

    // Send state
    public var draft: String = ""
    public var sending = false
    public var streamingText: String = ""
    public var streamRunID: String?
    private var streamTask: Task<Void, Never>?

    /// Sequence number of the most recent chunk seen on the active
    /// stream. Used by `resumeStreamIfPaused()` to re-subscribe with
    /// `fromSequence = lastStreamChunkSequence + 1` after a ScenePhase
    /// background dropped the live SSE connection.
    ///
    /// Reset to 0 in `clearStreamingState()` and on each new `send()`
    /// so a stale sequence from a previous run doesn't leak into the
    /// next one. Mac never reads it (Mac apps don't suspend the same
    /// way) but the per-chunk write costs nothing.
    private var lastStreamChunkSequence: Int64 = 0
    /// Optimistic user message text shown before the RPC returns.
    public var pendingUserText: String?

    /// Accumulated thinking text streamed for the active run. Reset to ""
    /// on stream start; appended on each `.thinkingDelta` chunk; cleared on
    /// terminal once the assistant message is materialised (the rendered
    /// text moves to `messages[i].thinkingRenderedText` for historical
    /// display). Empty string + non-nil `streamingThinkingStartedAt` is the
    /// "reasoning started, no text yet" marker the UI shows as
    /// "Thinking… (0.0s)".
    public var streamingThinking: String = ""
    /// Wall-clock at which the first thinking delta arrived for the active
    /// run. Drives the live "Thinking… (X.Ys)" timer client-side: the view
    /// polls `Date()` and subtracts. Nil before any thinking arrives, and
    /// reset to nil on terminal.
    public var streamingThinkingStartedAt: Date?
    /// True once the assistant has produced its first `.textDelta`. Once
    /// true, the live "Thinking…" badge in the UI flips to "Thought for
    /// X.Ys" — reasoning is over for this turn even though the run hasn't
    /// terminated yet, and we want the badge to read accurately the moment
    /// the user can see the answer being typed out.
    public var streamingThinkingFinishedAt: Date?

    /// Open/closed state for the live streaming row's thinking disclosure.
    /// Owned by the view-model (rather than @State inside the disclosure)
    /// so a click during the live stream can carry forward to the
    /// materialised MessageRow at terminal time without the disclosure
    /// snapping shut on the StreamingRow → MessageRow view-tree swap.
    public var streamingThinkingExpanded: Bool = false

    /// Open/closed state for thinking disclosures on historical messages,
    /// keyed by message id. A `Set` of "currently expanded ids" is the
    /// minimal shape — absence == collapsed (the common case). Persisted
    /// across `load()` calls so reloading the conversation doesn't snap
    /// every disclosure shut.
    public var expandedThinkingMessageIDs: Set<String> = []

    /// Tool calls captured on the active stream, ordered by start time.
    /// Built up from `tool_use_start` / `tool_use_delta` / `tool_use_end` /
    /// `tool_result` chunks. Each entry's computed `phase` flips through
    /// generating → executing → done as more chunks arrive. Wiped on
    /// terminal — historical tool calls live on the materialised
    /// message row's `toolCalls` instead.
    public var streamingToolCalls: [LiveToolCall] = []

    /// Open/closed state for tool-call disclosures on historical messages,
    /// keyed by `"\(messageID):\(toolCallIndex)"` to disambiguate when a
    /// single message carries multiple calls and Gemini's synthetic
    /// per-round id resets cause id collisions.
    public var expandedToolCallKeys: Set<String> = []

    /// Per-message expansion state for system + context message bubbles.
    /// Default behaviour for those roles is collapsed (the bubble shows
    /// just a header strip with the role + first line of the content);
    /// set membership flips it open. Distinct from
    /// `expandedThinkingMessageIDs` so a user expanding the system
    /// message doesn't also affect any thinking disclosure on the same
    /// message — the two states are independent.
    public var expandedHeaderMessageIDs: Set<String> = []

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
    public var editingMessage: ReeveMessage?

    // Context switcher
    public var contexts: [ReeveContext] = []
    /// When true, the conversation pane swaps the message scroll for a
    /// full context-list view (per the "no popups" rule). Toggled from the
    /// title menu's "View contexts…" entry.
    public var showingContextList: Bool = false
    /// Set by `promoteCompaction` after a successful promote-and-
    /// activate. The view layer reads this to mint a toast ("Switched
    /// to new context after compression") and clears it back to nil
    /// after the toast renders. Pure presentation signal; not
    /// persisted.
    public var lastPromotedContextID: String?

    // Settings page
    /// When true, the conversation pane swaps the message scroll for the
    /// in-conversation Settings page (Compact / Contexts / Settings share
    /// the same page-replaces-pane pattern).
    public var showingSettingsView: Bool = false
    /// Editable conversation-level CallSettings draft. Mutations here are
    /// pushed to the server via `saveCallSettings()` on dismiss.
    public var conversationCallSettingsDraft: ReeveCallSettings = ReeveCallSettings()
    /// Snapshot of the resolved-from-below CallSettings (model + profile)
    /// used by the form's "Inherit (X)" mute previews. Loaded by
    /// `prepareSettingsView()`.
    public var resolvedCallSettings: ReeveCallSettings?
    /// Tracks the resolved profile so the form can pick the correct driver
    /// extension block (anthropic / openai / google) based on the
    /// effective default model. Loaded by `prepareSettingsView()`.
    public var settingsResolvedProfile: ReeveProfile?
    public var preparingSettingsView = false

    // Model switcher
    public var availableModels: [ReeveUserModel] = []
    public var providerLabels: [String: String] = [:]
    /// Provider driver type keyed by provider ID — e.g. "anthropic" /
    /// "openai-compatible" / "google". Populated by `loadAvailableModels`.
    /// Used by views to decide which CallSettings extension block to render
    /// and to compute cache-savings discount factors.
    public var providerTypes: [String: String] = [:]
    /// Per-provider preset id parsed out of the JSON config — only
    /// populated for openai-compatible providers that were created from
    /// a preset (xAI, OpenRouter, DeepSeek, …). Native drivers
    /// (anthropic, google) and pre-preset legacy custom configs map to
    /// nil here; the type alone is sufficient for those to find a logo
    /// (see ConversationView's logoSlug helper). Drives the input
    /// composer's model chip rendering + the new ConversationModelPicker.
    public var providerPresetIDs: [String: String] = [:]
    public var selectedProviderID: String?
    public var selectedModelID: String?

    // Conversation model picker page (page-replaces-pane pattern,
    // sibling to Compact / Contexts / Settings). When true, the
    // conversation pane swaps the message scroll for a model-picker
    // surface that lists available models grouped by provider with the
    // same metadata strip as the providers Settings page.
    public var showingModelPicker: Bool = false

    // Token count (advisory; nil when unavailable)
    public var tokenCount: Int32?
    public var contextWindow: Int32?

    // MARK: Computed

    /// Total spend across every context in this conversation, summed from
    /// the per-context aggregate the server stamps on `ReeveContext.cumulativeCostUsd`.
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
        conversation: ReeveConversation,
        client: ReeveClient,
        onTerminal: @MainActor @escaping () async -> Void,
        onAssistantTurnComplete: AssistantTurnCompleteHandler? = nil,
        localTitler: LocalTitler? = nil
    ) {
        self.conversation = conversation
        self.client = client
        self.onTerminal = onTerminal
        self.onAssistantTurnComplete = onAssistantTurnComplete
        self.localTitler = localTitler
        // Restore any unsent composer text from a previous visit.
        // Init-time so the field is populated before the first
        // render frame — no flicker between empty and restored.
        if let saved = DraftStore.load(conversationID: conversation.id) {
            self.draft = saved
        }
    }

    // MARK: Load

    public func load() async {
        loading = true
        defer { loading = false }
        do {
            let (conv, ctx) = try await client.conversations.get(id: conversation.id)
            self.activeContext = ctx
            self.messages = try await client.conversations.listMessages(contextID: ctx.id)
            self.loadError = nil
            // Selection priority:
            //   1. conversations.settings.{default_provider_id, default_model_id}
            //      — explicit per-conversation choice persisted to the
            //      server. Stays put across deletes / reloads / branch
            //      switches (the previous behaviour of "default to last
            //      used assistant" silently shifted the selection when
            //      messages were deleted, which the user found annoying).
            //   2. last assistant message in the loaded chain — fallback
            //      for conversations that haven't had an explicit choice
            //      written yet (legacy rows or fresh conversations with
            //      no settings blob).
            //   3. leave the existing selection alone — caller may have
            //      seeded from elsewhere.
            if let s = conv.settings,
               let p = s.defaultProviderID, !p.isEmpty,
               let m = s.defaultModelID, !m.isEmpty {
                selectedProviderID = p
                selectedModelID    = m
            } else if let target = tokenCountTarget {
                selectedProviderID = target.providerID
                selectedModelID    = target.modelID
            }
            await refreshTokenCount()
            // Refresh the full message tree alongside the active chain so
            // the branch switcher knows about every fork. Failures are
            // non-blocking — chain mode keeps working without it.
            await loadTree()
        } catch {
            self.loadError = ReeveError.display(error)
        }
    }

    /// Updates the per-conversation provider+model selection and persists
    /// to the server in one shot. Called from the composer's model picker
    /// when the user picks a different model. Optimistically updates
    /// local state, then writes; on failure surfaces via `loadError` and
    /// rolls back to whatever the server returns. Idempotent — picking
    /// the same model is a no-op write.
    public func selectModel(providerID: String, modelID: String) async {
        guard providerID != selectedProviderID || modelID != selectedModelID else { return }
        selectedProviderID = providerID
        selectedModelID = modelID
        // Build the full settings blob (UpdateConversation replaces, doesn't
        // merge). Start from the existing snapshot so we don't accidentally
        // wipe call_settings / include_thinking on a model swap.
        var s = conversation.settings ?? ReeveConversationSettings()
        s.defaultProviderID = providerID
        s.defaultModelID    = modelID
        do {
            _ = try await client.conversations.updateSettings(
                id: conversation.id,
                settings: s
            )
        } catch {
            // Don't roll back the in-memory selection — the user picked it
            // and should be able to continue using it for this turn even
            // if persistence fails. Surface the error so they know.
            loadError = ReeveError.display(error)
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
    public func maybeGenerateLocalTitle(profilesByID: [String: ReeveProfile]) async {
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
        guard resolvedTitleProviderKind(profilesByID: resolveMap) == ReeveTitleProviderKind.appleFoundation else { return }
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
    func resolvedTitleProviderKind(profilesByID: [String: ReeveProfile]) -> String? {
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
    private func resolvedTitleGuide(profilesByID: [String: ReeveProfile]) -> String? {
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

    private func renderLocalTitleTranscript(_ msgs: [ReeveMessage]) -> String {
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
            providerTypes  = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.type) })
            providerPresetIDs = Dictionary(uniqueKeysWithValues:
                providers.compactMap { p in p.presetID.map { (p.id, $0) } }
            )
            availableModels = try await withThrowingTaskGroup(of: [ReeveUserModel].self) { group in
                for p in providers {
                    group.addTask { try await self.client.modelProviders.listModels(providerID: p.id) }
                }
                var all: [ReeveUserModel] = []
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
        let originalDraft = draft
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !isCompacting, !hasPendingCompression else { return }
        draft = ""
        // Whatever the user had saved as a draft is now in flight —
        // clear so a successful send doesn't leave a stale draft
        // ready to greet them on next open.
        DraftStore.clear(conversationID: conversation.id)
        sending = true
        streamingText = ""
        streamingThinking = ""
        streamingThinkingStartedAt = nil
        streamingThinkingFinishedAt = nil
        streamingToolCalls = []
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
                        applyStreamChunk(c)
                    case .terminal:
                        await load()
                        await onTerminal()
                        // Hand off any open disclosure to the materialised
                        // assistant turn so the user's click during the
                        // stream survives the StreamingRow → MessageRow
                        // swap.
                        clearStreamingState(handOffExpandedTo: latestAssistantMessageID)
                        // App-level "assistant turn complete" hook —
                        // drives Mac local notifications, etc. Skipped
                        // for errored / cancelled runs (those land in
                        // .failed below).
                        fireAssistantTurnComplete()
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
                        clearStreamingState(handOffExpandedTo: latestAssistantMessageID)
                    }
                }
            }
        } catch {
            // Pre-stream RPC failure (validation, network before the
            // server even spawned a run): no message row exists. Restore
            // the user's typed text into the composer so they can retry
            // without losing what they wrote — losing the draft on a
            // network blip is worst-case UX. Then reload to clear any
            // stale optimistic state, and surface the error inline.
            pendingUserText = nil
            if draft.isEmpty { draft = originalDraft }
            // Re-persist the restored text so it survives a quick
            // background/relaunch — we cleared the store optimistically
            // above on the assumption the send would succeed.
            DraftStore.save(conversationID: conversation.id, text: draft)
            await load()
            loadError = ReeveError.display(error)
        }
    }

    public func cancelStream() {
        guard let id = streamRunID else { return }
        Task { try? await client.streams.cancel(streamRunID: id) }
    }

    // MARK: - ScenePhase suspend / resume (iOS)
    //
    // iOS aggressively suspends backgrounded apps; the SSE socket the
    // streamTask holds dies on the way out. The supervisor on the
    // server side keeps streaming regardless and persists chunks to
    // `stream_chunks` — the existing replay path. These two methods
    // wire that path to the iOS ScenePhase observer in `ReeveiOSApp`.
    //
    // Mac doesn't need them (NSApp doesn't suspend connections the
    // same way) but the API is harmless to call there too — Mac wires
    // up `suspendActiveStream()` from a window-occluded notification
    // would get the same behavior.

    /// Cancels the local subscription Task without telling the server
    /// to cancel the run. The streamRunID + lastStreamChunkSequence
    /// stay in place so `resumeStreamIfPaused()` can re-subscribe
    /// where we left off. No-op when no stream is active.
    public func suspendActiveStream() {
        guard streamRunID != nil else { return }
        streamTask?.cancel()
        streamTask = nil
    }

    /// Re-subscribes to the active stream from `lastStreamChunkSequence + 1`
    /// if a stream was running and got suspended. No-op when there's
    /// no stream OR when a streamTask is already running (e.g. the
    /// user foregrounded faster than the cancel-then-resubscribe
    /// race could complete).
    public func resumeStreamIfPaused() {
        guard let runID = streamRunID, streamTask == nil else { return }
        let resumeFrom = lastStreamChunkSequence + 1
        streamTask = Task { @MainActor in
            for await event in client.streams.subscribe(streamRunID: runID, fromSequence: resumeFrom) {
                switch event {
                case .chunk(let c):
                    applyStreamChunk(c)
                case .terminal:
                    await load()
                    await onTerminal()
                    clearStreamingState(handOffExpandedTo: latestAssistantMessageID)
                    fireAssistantTurnComplete()
                    await maybeGenerateLocalTitle(profilesByID: localTitleProfilesByID)
                case .failed:
                    await load()
                    await onTerminal()
                    clearStreamingState(handOffExpandedTo: latestAssistantMessageID)
                }
            }
        }
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

    // MARK: Settings page

    /// Loads the data the in-conversation Settings page needs:
    ///   - the conversation-level CallSettings draft (seeded from the
    ///     conversation's existing `settings.callSettings`, if any).
    ///   - the resolved-from-below CallSettings snapshot used by the form's
    ///     "Inherit (X)" mute previews. Computed by merging the profile's
    ///     resolved CallSettings with the active model's defaults; the
    ///     server will additionally consult provider defaults at SendMessage
    ///     time, which we don't surface in the preview.
    ///   - the resolved profile, used by the form to pick the correct
    ///     driver-specific extension block.
    public func prepareSettingsView() async {
        preparingSettingsView = true
        defer { preparingSettingsView = false }

        // Always re-fetch the live conversation so we pick up settings
        // that another path may have written.
        let liveConvo: ReeveConversation
        do {
            (liveConvo, _) = try await client.conversations.get(id: conversation.id)
        } catch {
            return
        }
        conversationCallSettingsDraft = liveConvo.settings?.callSettings ?? ReeveCallSettings()

        // Resolve the profile through the parent chain so we can render
        // the inheritance preview against the profile's effective settings.
        var resolved: ReeveCallSettings = ReeveCallSettings()
        if let (_, resolvedProfile) = try? await client.profiles.get(id: liveConvo.profileID, resolve: true),
           let resolvedProfile {
            settingsResolvedProfile = resolvedProfile
            if let cs = resolvedProfile.defaultSettings?.callSettings {
                resolved = cs
            }
            // Layer the resolved profile's default model defaults *under*
            // the profile's own callSettings — model is lower precedence.
            // We don't know the per-model defaults until we look the model
            // up in the available-models list.
            if let pid = liveConvo.settings?.defaultProviderID ?? resolvedProfile.defaultSettings?.defaultProviderID,
               let mid = liveConvo.settings?.defaultModelID    ?? resolvedProfile.defaultSettings?.defaultModelID,
               let model = availableModels.first(where: { $0.providerID == pid && $0.modelID == mid }),
               let modelDefaults = model.defaultSettings {
                resolved = mergeCallSettings(higher: resolved, lower: modelDefaults)
            }
        }
        resolvedCallSettings = resolved
    }

    /// Persists the current `conversationCallSettingsDraft` back to the
    /// server. Preserves any non-call-settings fields on the conversation's
    /// existing settings (default provider/model, include-thinking flag).
    /// Called on dismiss of the in-conversation Settings page.
    public func saveCallSettings() async {
        var settings = conversation.settings ?? ReeveConversationSettings()
        settings.callSettings = conversationCallSettingsDraft.isEmpty ? nil : conversationCallSettingsDraft
        do {
            _ = try await client.conversations.updateSettings(
                id: conversation.id,
                settings: settings
            )
        } catch {
            loadError = ReeveError.display(error)
        }
    }

    /// Sparse merge — `higher` wins when set, otherwise `lower` field is
    /// adopted. Mirrors the server-side `mergeCallSettings` in
    /// `internal/profiles/callsettings.go`. Used for the inherit-preview.
    private func mergeCallSettings(higher: ReeveCallSettings, lower: ReeveCallSettings) -> ReeveCallSettings {
        var out = higher
        if out.temperature == nil      { out.temperature = lower.temperature }
        if out.topP == nil             { out.topP = lower.topP }
        if out.maxOutputTokens == nil  { out.maxOutputTokens = lower.maxOutputTokens }
        if out.stopSequences.isEmpty   { out.stopSequences = lower.stopSequences }
        if out.topK == nil             { out.topK = lower.topK }
        // Thinking / extras: take whichever is non-nil; no nested merge in v1.
        if out.thinking == nil  || (out.thinking?.isEmpty ?? true)  { out.thinking  = lower.thinking }
        if out.anthropic == nil || (out.anthropic?.isEmpty ?? true) { out.anthropic = lower.anthropic }
        if out.openai == nil    || (out.openai?.isEmpty ?? true)    { out.openai    = lower.openai }
        if out.google == nil    || (out.google?.isEmpty ?? true)    { out.google    = lower.google }
        return out
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
            streamingThinking = ""
            streamingThinkingStartedAt = nil
            streamingThinkingFinishedAt = nil
            streamingToolCalls = []
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
                        applyStreamChunk(c)
                    case .terminal:
                        isCompacting = false
                        clearStreamingState()
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
                        clearStreamingState()
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
            compactError = ReeveError.display(error)
            showingCompactView = true
        }
    }

    /// Promotes a compression summary into its own context, refreshes
    /// the contexts list, and **activates the new context** so the
    /// user lands inside the freshly-promoted prefix without an
    /// extra navigation step. Sets `lastPromotedContextID` so the
    /// caller (iOS conversation view) can surface a toast on the next
    /// render — the binding is consumed and cleared by the toast view
    /// modifier.
    public func promoteCompaction(messageID: String) async {
        do {
            let newCtx = try await client.conversations.promoteCompactionToNewContext(messageID: messageID)
            tokenCount = nil
            contextWindow = nil
            await loadContexts()
            await activateContext(newCtx.id)
            await onTerminal()
            lastPromotedContextID = newCtx.id
        } catch {
            loadError = ReeveError.display(error)
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
            loadError = ReeveError.display(error)
        }
    }

    // MARK: Message mutations

    public func editMessage(id: String, content: String, role: ReeveMessageRole? = nil) async {
        do {
            let updated = try await client.conversations.editMessage(id: id, content: content, role: role)
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx] = updated
            }
        } catch {
            loadError = ReeveError.display(error)
        }
    }

    /// Reload-as-fork. Two semantics depending on what was clicked:
    ///
    ///  - User turn: re-send a copy of the user content at its parent —
    ///    creates a sibling user message + a fresh assistant under it.
    ///    The fork lives at the user level; both branches carry their
    ///    own user content (which may be identical).
    ///  - Assistant turn: regenerate. Walk up to the parent user, then
    ///    start a new assistant stream under that SAME user. The fork
    ///    lives at the assistant level (one user → many assistants), no
    ///    duplicate user row. Server-side this is `SendMessage` with
    ///    `regenerate=true`.
    ///
    /// Never edits the existing row in either path. Matches the spec's
    /// "every Reload creates a fork, don't edit existing messages."
    public func reloadFromMessage(id: String) async {
        guard !sending, !isStreaming else { return }
        guard let target = messages.first(where: { $0.id == id }) else { return }
        switch target.role {
        case .user:
            await sendForking(content: target.content, parentMessageID: target.parentID)
        case .assistant:
            guard let pid = target.parentID,
                  let parent = messages.first(where: { $0.id == pid }),
                  parent.role == .user else { return }
            await regenerateAssistant(parentMessageID: parent.id)
        default:
            return
        }
    }

    /// Composer-side reload. Re-streams off the most recent user turn
    /// using regenerate semantics — produces a sibling assistant under
    /// the existing user message rather than duplicating the user. Only
    /// meaningful when the trailing turn is a user message awaiting an
    /// assistant; the UI gates on this.
    public func reloadLastUser() async {
        guard let last = messages.last(where: { $0.role == .user }) else { return }
        await regenerateAssistant(parentMessageID: last.id)
    }

    /// Regenerate-mode SendMessage. Streams a new assistant parented to
    /// `parentMessageID`. Two valid shapes (server-validated):
    ///
    /// - parent.role == .user: sibling assistant under the same user.
    ///   Powers Reload on assistant rows.
    /// - parent.role == .assistant: chained assistant — produces two
    ///   assistants in a row (parent stays put, new one continues from
    ///   it). Powers Save and Resend on edited assistant rows.
    ///
    /// Mirrors `sendForking`'s setup/teardown machinery so chunk
    /// routing, terminal hand-off, and error resilience are identical.
    public func regenerateAssistant(parentMessageID: String) async {
        guard !sending, !isCompacting, !hasPendingCompression else { return }
        sending = true
        streamingText = ""
        streamingThinking = ""
        streamingThinkingStartedAt = nil
        streamingThinkingFinishedAt = nil
        streamingToolCalls = []
        defer { sending = false }

        do {
            let (_, run) = try await client.conversations.regenerateAssistant(
                conversationID: conversation.id,
                parentMessageID: parentMessageID,
                providerID: selectedProviderID,
                modelID: selectedModelID
            )
            await load()
            streamRunID = run.id
            streamTask?.cancel()
            streamTask = Task { @MainActor in
                for await event in client.streams.subscribe(streamRunID: run.id) {
                    switch event {
                    case .chunk(let c):
                        applyStreamChunk(c)
                    case .terminal:
                        await load()
                        await onTerminal()
                        clearStreamingState(handOffExpandedTo: latestAssistantMessageID)
                        await maybeGenerateLocalTitle(profilesByID: localTitleProfilesByID)
                    case .failed:
                        await load()
                        await onTerminal()
                        clearStreamingState(handOffExpandedTo: latestAssistantMessageID)
                    }
                }
            }
        } catch {
            await load()
            loadError = ReeveError.display(error)
        }
    }

    /// Send-with-explicit-parent. Powers send() (parent = current leaf,
    /// implicit) and reloadFromMessage (parent = explicit, forking).
    /// Keeps the streaming/teardown machinery in one place — both call
    /// sites benefit from the same chunk routing, terminal hand-off, and
    /// error resilience. Empty content short-circuits silently.
    public func sendForking(content: String, parentMessageID: String?) async {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !isCompacting, !hasPendingCompression else { return }
        sending = true
        streamingText = ""
        streamingThinking = ""
        streamingThinkingStartedAt = nil
        streamingThinkingFinishedAt = nil
        streamingToolCalls = []
        pendingUserText = text
        defer { sending = false }

        do {
            let (userMsg, run) = try await client.conversations.sendMessage(
                conversationID: conversation.id,
                content: text,
                parentMessageID: parentMessageID,
                providerID: selectedProviderID,
                modelID: selectedModelID
            )
            pendingUserText = nil
            // Reload so the new sibling appears alongside the old branch
            // — appending alone would mis-order the tree view.
            await load()
            // Make sure the just-inserted user message is visible in the
            // local list even if `load()` somehow misses it (ordering
            // race).
            if !messages.contains(where: { $0.id == userMsg.id }) {
                messages.append(userMsg)
            }
            streamRunID = run.id
            streamTask?.cancel()
            streamTask = Task { @MainActor in
                for await event in client.streams.subscribe(streamRunID: run.id) {
                    switch event {
                    case .chunk(let c):
                        applyStreamChunk(c)
                    case .terminal:
                        await load()
                        await onTerminal()
                        clearStreamingState(handOffExpandedTo: latestAssistantMessageID)
                        await maybeGenerateLocalTitle(profilesByID: localTitleProfilesByID)
                    case .failed:
                        await load()
                        await onTerminal()
                        clearStreamingState(handOffExpandedTo: latestAssistantMessageID)
                    }
                }
            }
        } catch {
            pendingUserText = nil
            await load()
            loadError = ReeveError.display(error)
        }
    }

    public func deleteMessage(id: String, cascade: Bool = false) async {
        do {
            try await client.conversations.deleteMessage(id: id, cascade: cascade)
            await load()
        } catch {
            loadError = ReeveError.display(error)
        }
    }

    // MARK: - Streaming chunk routing

    /// Routes one chunk from the live stream into the relevant accumulator
    /// (text → `streamingText`, thinking → `streamingThinking`). Also stamps
    /// `streamingThinkingStartedAt` on the first thinking delta and
    /// `streamingThinkingFinishedAt` on the first text delta after thinking
    /// — that's the moment the live "Thinking…" badge flips to "Thought
    /// for X.Ys" because reasoning is over even though the run hasn't
    /// terminated. Other chunk types are ignored at this layer.
    func applyStreamChunk(_ c: ReeveChunk) {
        // Track the highest sequence seen so resumeStreamIfPaused can
        // re-subscribe from `c.sequence + 1` after a ScenePhase drop.
        // Use max() defensively: chunks should arrive in order but
        // recording the highest is safe under any ordering quirk.
        lastStreamChunkSequence = max(lastStreamChunkSequence, c.sequence)
        switch c.type {
        case .textDelta:
            if let s = c.textIfDelta {
                if streamingThinkingStartedAt != nil, streamingThinkingFinishedAt == nil {
                    streamingThinkingFinishedAt = Date()
                }
                streamingText += s
            }
        case .thinkingDelta:
            if let s = c.textIfDelta {
                if streamingThinkingStartedAt == nil {
                    streamingThinkingStartedAt = Date()
                }
                streamingThinking += s
            }
        case .toolUseStart:
            if let info = c.toolUseStartInfo {
                streamingToolCalls.append(LiveToolCall(id: info.id, name: info.name, startedAt: Date()))
            }
        case .toolUseDelta:
            if let partial = c.toolUseDeltaPartialJSON,
               let last = streamingToolCalls.indices.last {
                streamingToolCalls[last].input.append(partial)
            }
        case .toolUseEnd:
            // Match against the most-recent live call without an
            // `argsCompletedAt` — the loop dispatches serially, so this
            // is invariant-safe even when Gemini reuses synthetic ids.
            if let idx = streamingToolCalls.lastIndex(where: { $0.argsCompletedAt == nil }) {
                streamingToolCalls[idx].argsCompletedAt = Date()
            }
        case .toolResult:
            guard let info = c.toolResultInfo else { break }
            // Same "last unresolved" lookup as above; falls back to id
            // match when somehow ahead of the args-end chunk (defensive).
            let idx = streamingToolCalls.lastIndex(where: { $0.resultArrivedAt == nil })
                ?? streamingToolCalls.lastIndex(where: { $0.id == info.toolUseID })
            if let idx {
                streamingToolCalls[idx].output = info.output
                streamingToolCalls[idx].error = info.error
                streamingToolCalls[idx].elapsedMs = info.elapsedMs
                streamingToolCalls[idx].resultArrivedAt = Date()
                // Defensive: if we got the result before the End chunk
                // (shouldn't happen, but the wire is non-deterministic),
                // synthesise the args-done timestamp so phase doesn't
                // get stuck in `.generating`.
                if streamingToolCalls[idx].argsCompletedAt == nil {
                    streamingToolCalls[idx].argsCompletedAt = streamingToolCalls[idx].resultArrivedAt
                }
            }
        default:
            break
        }
    }

    /// Wipes all per-stream live state. Called from terminal/failed branches
    /// of every subscribe loop so the next send starts from a clean slate.
    /// `handOffExpandedTo`, when non-nil, transfers the live disclosure's
    /// expanded state to the historical-message expanded set under that id
    /// — so a stream that finished with the disclosure open lands a
    /// MessageRow with its disclosure also open, no snap-shut on the
    /// view-tree swap.
    func clearStreamingState(handOffExpandedTo materialisedMessageID: String? = nil) {
        if streamingThinkingExpanded, let id = materialisedMessageID {
            expandedThinkingMessageIDs.insert(id)
        }
        streamingText = ""
        streamingThinking = ""
        streamingThinkingStartedAt = nil
        streamingThinkingFinishedAt = nil
        streamingThinkingExpanded = false
        streamingToolCalls = []
        streamRunID = nil
        lastStreamChunkSequence = 0
    }

    /// Returns the most recently-created assistant message in the loaded
    /// list. Used at terminal time to find the just-materialised row so
    /// `clearStreamingState` can transfer the disclosure-expanded flag
    /// onto its id. Returns nil when the message list hasn't loaded yet
    /// or there are no assistant turns (a freshly-failed first send).
    public var latestAssistantMessageID: String? {
        messages.last(where: { $0.role == .assistant })?.id
    }

    /// Calls onAssistantTurnComplete with a short content preview when
    /// the most recent assistant message is non-empty. No-op when no
    /// assistant message landed (early-error runs) or no handler is
    /// wired. Preview is the first ~140 chars of plain content with
    /// markdown left intact (the notification UI can flatten further
    /// if needed).
    private func fireAssistantTurnComplete() {
        guard let handler = onAssistantTurnComplete,
              let id = latestAssistantMessageID,
              let msg = messages.last(where: { $0.id == id })
        else { return }
        let body = msg.displayContent ?? msg.content
        let preview: String
        if body.count > 140 {
            preview = body.prefix(140).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        } else {
            preview = body
        }
        handler(conversation.id, conversation.title, id, preview)
    }

    // MARK: - Branch / fork navigation

    /// Full tree of messages in the active context — every branch, not
    /// just the current chain. Used by the branch switcher to discover
    /// sibling IDs and walk down to the deepest leaf when the user picks
    /// a different fork. Empty until `loadTree()` runs (called from
    /// `load()` after the linear chain is populated).
    public var treeMessages: [ReeveMessage] = []

    /// Children-by-parent map derived from `treeMessages`. Keys are
    /// parent message ids (or "" for root-level rows whose parent is
    /// nil). Values are children sorted by created_at — sibling order in
    /// the switcher matches the order in which forks were spawned.
    private var childrenByParent: [String: [ReeveMessage]] {
        var out: [String: [ReeveMessage]] = [:]
        for m in treeMessages {
            let key = m.parentID ?? ""
            out[key, default: []].append(m)
        }
        for k in out.keys {
            out[k]?.sort { ($0.id) < ($1.id) }  // UUIDv7 ids sort by creation
        }
        return out
    }

    /// Sibling info for a given message — its position among messages
    /// sharing the same parent. Returns nil when the message has no
    /// siblings (the common case) so the UI can elide the switcher
    /// entirely. `index` is 0-based.
    public func branchInfo(for messageID: String) -> (siblingIDs: [String], index: Int)? {
        guard let m = treeMessages.first(where: { $0.id == messageID }) else { return nil }
        let key = m.parentID ?? ""
        let siblings = childrenByParent[key] ?? []
        guard siblings.count > 1 else { return nil }
        guard let idx = siblings.firstIndex(where: { $0.id == messageID }) else { return nil }
        return (siblings.map(\.id), idx)
    }

    /// Switches the active branch by repositioning the per-context leaf
    /// cursor to the deepest descendant of `siblingID`. Reloads the
    /// linear chain afterwards so the UI shows the new branch.
    /// Best-effort: errors land in `loadError`.
    public func switchToBranch(siblingID: String) async {
        guard let activeContext else { return }
        let leafID = deepestDescendantID(of: siblingID) ?? siblingID
        do {
            try await client.conversations.setCurrentLeaf(contextID: activeContext.id, messageID: leafID)
            await load()
        } catch {
            loadError = ReeveError.display(error)
        }
    }

    /// Walks `treeMessages` from `messageID` down through its single
    /// child each time until a leaf (no children) or a fork (>1 child)
    /// is reached. The first hit is returned. For the branch-switch
    /// case this is "the natural place to land when picking this
    /// branch" — most chat UIs feel right when "go to branch" lands at
    /// the latest activity rather than the parent itself.
    private func deepestDescendantID(of messageID: String) -> String? {
        var cur = messageID
        let map = childrenByParent
        while true {
            let kids = map[cur] ?? []
            switch kids.count {
            case 0: return cur
            case 1: cur = kids[0].id
            default:
                // Pick the most recently-created child at every fork —
                // matches the spec's "default: deepest descendant of the
                // alternate child's subtree" guidance.
                cur = kids.last!.id
            }
        }
    }

    /// Fetches the full message tree for the active context. Called
    /// after `load()` so the branch switcher knows who is sibling to
    /// whom. Failures land in `loadError` but don't block the linear
    /// chain — the switcher just hides itself when `treeMessages` is
    /// empty.
    public func loadTree() async {
        guard let activeContext else { return }
        do {
            self.treeMessages = try await client.conversations.listMessages(
                contextID: activeContext.id,
                fullTree: true
            )
        } catch {
            // The branch switcher is the only consumer of `treeMessages` —
            // missing it just means the chevrons don't appear. Surfacing
            // the failure as `loadError` would shadow the cached chain
            // we just rendered (e.g. while reeved is unreachable). Drop
            // the error silently and leave the tree empty.
            self.treeMessages = []
        }
    }
}
