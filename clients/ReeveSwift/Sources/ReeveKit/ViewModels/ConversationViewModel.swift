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
    /// App-lifetime owner of active stream subscriptions. Passed in so
    /// the view model can register newly-started runs + observe state
    /// without owning the subscriber task itself.
    private let hub: StreamHub
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

    /// Optimistic user message text shown before the RPC returns.
    public var pendingUserText: String?

    // MARK: - Streaming state (read-through to `StreamHub`)
    //
    // The active stream's accumulated text / thinking / tool calls /
    // sequence cursor live on `AppModel.streamHub` so they survive the
    // view-model being torn down (user leaves the chat, comes back).
    // These computed properties forward reads — SwiftUI's `@Observable`
    // tracks the nested access into `hub.streams[conversation.id]`, so
    // chunk-driven updates propagate to the View tree automatically.

    public var streamingText: String {
        hub.streams[conversation.id]?.streamingText ?? ""
    }
    public var streamRunID: String? {
        hub.streams[conversation.id]?.runID
    }
    public var streamingThinking: String {
        hub.streams[conversation.id]?.streamingThinking ?? ""
    }
    public var streamingThinkingStartedAt: Date? {
        hub.streams[conversation.id]?.streamingThinkingStartedAt
    }
    public var streamingThinkingFinishedAt: Date? {
        hub.streams[conversation.id]?.streamingThinkingFinishedAt
    }

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
    /// Mirrored from `hub.streams[conversation.id]?.streamingToolCalls`.
    public var streamingToolCalls: [LiveToolCall] {
        hub.streams[conversation.id]?.streamingToolCalls ?? []
    }

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

    // Compact state — `isCompacting` is computed from the hub so an
    // active compression stream survives the view-model's lifecycle.
    public var isCompacting: Bool {
        hub.streams[conversation.id]?.purpose == .compression
    }
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

    public var isStreaming: Bool {
        hub.streams[conversation.id]?.purpose == .assistantResponse
    }

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
        hub: StreamHub,
        onTerminal: @MainActor @escaping () async -> Void,
        onAssistantTurnComplete: AssistantTurnCompleteHandler? = nil,
        localTitler: LocalTitler? = nil
    ) {
        self.conversation = conversation
        self.client = client
        self.hub = hub
        self.onTerminal = onTerminal
        self.onAssistantTurnComplete = onAssistantTurnComplete
        self.localTitler = localTitler
        // Restore any unsent composer text from a previous visit.
        // Init-time so the field is populated before the first
        // render frame — no flicker between empty and restored.
        if let saved = DraftStore.load(conversationID: conversation.id) {
            self.draft = saved
        }
        // Register this view as the terminal listener for our
        // conversation. Replaces any earlier registration (e.g. if the
        // user thrashes between the same conversation rapidly). Hub
        // already-active streams remain subscribing; on terminal the
        // hub fires this callback.
        hub.attach(conversationID: conversation.id) { [weak self] run in
            await self?.handleStreamTerminal(run)
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
        guard !text.isEmpty, !sending, !isStreaming, !isCompacting, !hasPendingCompression else { return }
        draft = ""
        // Whatever the user had saved as a draft is now in flight —
        // clear so a successful send doesn't leave a stale draft
        // ready to greet them on next open.
        DraftStore.clear(conversationID: conversation.id)
        sending = true
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
            // Hand the run to the hub — it owns the subscriber task
            // and accumulates streaming state. Terminal arrives via
            // the callback registered in init(), regardless of
            // whether this view model is still mounted at the time.
            hub.register(
                runID: run.id,
                conversationID: conversation.id,
                contextID: run.contextID,
                purpose: .assistantResponse
            )
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
        Task { await hub.cancel(conversationID: conversation.id) }
    }

    // MARK: - ScenePhase suspend / resume (iOS)
    //
    // No-ops now — `StreamHub` owns the subscriber Task and keeps it
    // running across view-model dismissal. iOS's app-level suspend
    // (~30s grace, then process freeze) is handled inside the
    // subscriber's transparent-retry loop (see StreamSubscriber): on
    // foreground the underlying URLSession reconnects from the last
    // seen sequence. Kept as kept-open-stubs so existing scenePhase
    // wiring in `ConversationView` still compiles; if you want to
    // forcibly drop the active subscription on backgrounding (battery
    // savings), call `hub.cancel(conversationID:)` instead.
    public func suspendActiveStream() {}
    public func resumeStreamIfPaused() {}

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
        guard !isCompacting, !sending, !isStreaming else { return }
        compactError = nil
        do {
            let run = try await client.conversations.compact(
                conversationID: conversation.id,
                guide: guide,
                providerID: providerID,
                modelID: modelID
            )
            // Hub takes ownership; isCompacting flips true via the
            // computed property (hub.streams[conv.id]?.purpose == .compression).
            hub.register(
                runID: run.id,
                conversationID: conversation.id,
                contextID: run.contextID,
                purpose: .compression
            )
        } catch {
            // Pre-stream RPC failure — no run was created so there's no
            // errored summary to render. Surface the error inline on the
            // Compact page so the user can adjust the prompt or model
            // picker and try again. isCompacting is hub-derived now —
            // since `hub.register` was never called on this path, it's
            // already false.
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

    /// Manually create a new active context in this conversation, bypassing
    /// the compress-then-promote flow. The new context becomes active and
    /// the conversation is reloaded so the seeded user message (if any) is
    /// visible in the chain.
    public func createContextManual(
        initialUserMessage: String,
        mode: ReeveCompressionMode
    ) async {
        do {
            let result = try await client.conversations.createContextManual(
                conversationID: conversation.id,
                initialUserMessage: initialUserMessage,
                mode: mode
            )
            tokenCount = nil
            contextWindow = nil
            await loadContexts()
            await activateContext(result.context.id)
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
        guard !sending, !isStreaming, !isCompacting, !hasPendingCompression else { return }
        sending = true
        defer { sending = false }

        do {
            let (_, run) = try await client.conversations.regenerateAssistant(
                conversationID: conversation.id,
                parentMessageID: parentMessageID,
                providerID: selectedProviderID,
                modelID: selectedModelID
            )
            await load()
            hub.register(
                runID: run.id,
                conversationID: conversation.id,
                contextID: run.contextID,
                purpose: .assistantResponse
            )
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
        guard !text.isEmpty, !sending, !isStreaming, !isCompacting, !hasPendingCompression else { return }
        sending = true
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
            hub.register(
                runID: run.id,
                conversationID: conversation.id,
                contextID: run.contextID,
                purpose: .assistantResponse
            )
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

    // MARK: - Stream terminal handling
    //
    // `StreamHub` owns chunk routing and accumulation now (see
    // StreamHub.applyChunk). When the hub sees a terminal event for
    // this conversation it invokes the closure registered in init() —
    // which lands in `handleStreamTerminal` below.

    /// Fired by `StreamHub` when the conversation's active run reaches
    /// terminal. Hub-owned streaming state is already cleared by the
    /// time this runs, so `streamingText` etc. read empty and the
    /// streaming bubble disappears. We reload the chain so the
    /// materialised assistant turn appears, run app-level hooks, and
    /// hand off the live disclosure's expanded flag to the new row.
    ///
    /// Order matters: the expanded-state hand-off must happen BEFORE
    /// `load()`. The terminal event carries `resultMessageID`, which
    /// is the id of the just-materialised assistant turn (the same id
    /// `load()` will pull in). If we deferred the hand-off until after
    /// `load()`, SwiftUI would re-render the new MessageRow with the
    /// disclosure collapsed (the id isn't in `expandedThinkingMessageIDs`
    /// yet), then a second pass would expand it once the hand-off
    /// landed — the visible "thinking collapses then expands" hiccup
    /// at terminal. Pre-inserting means the MessageRow's first render
    /// already sees the expanded state.
    @MainActor
    private func handleStreamTerminal(_ run: ReeveStreamRun) async {
        let purpose = run.purpose
        if streamingThinkingExpanded, let resultID = run.resultMessageID, !resultID.isEmpty {
            expandedThinkingMessageIDs.insert(resultID)
        }
        streamingThinkingExpanded = false
        await load()
        await onTerminal()
        if purpose == .assistantResponse {
            fireAssistantTurnComplete()
            await maybeGenerateLocalTitle(profilesByID: localTitleProfilesByID)
        }
    }

    /// Returns the most recently-created assistant message in the loaded
    /// list. Returns nil when the message list hasn't loaded yet or
    /// there are no assistant turns (a freshly-failed first send).
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
    ///
    /// Mutations rebuild the derived caches (`childrenByParentCache`,
    /// `branchInfoCache`, `descendantCountCache`) once per change so
    /// per-row lookups in `MessageRow` are O(1) instead of O(N) walks.
    /// In long contexts the previous "compute on every access" pattern
    /// was the dominant per-frame cost — N rows × N tree messages.
    public var treeMessages: [ReeveMessage] = [] {
        didSet { rebuildTreeCaches() }
    }

    /// Children indexed by parent id (or `""` for root-level rows whose
    /// parent is nil). Values sorted by id — UUIDv7s sort by creation,
    /// so sibling order matches fork-spawn order. Refreshed by
    /// `rebuildTreeCaches()` on treeMessages mutation.
    private var childrenByParentCache: [String: [ReeveMessage]] = [:]

    /// Per-message branch-switcher info. nil when the message has no
    /// siblings — the common case, and the marker the UI uses to elide
    /// the pill entirely.
    private var branchInfoCache: [String: (siblingIDs: [String], index: Int)] = [:]

    /// Per-message descendant counts, computed bottom-up via memoised
    /// DFS in O(N) total. Drives the cascade-delete affordance ("Delete
    /// all replies… (N)") and `hasDescendants` gating.
    private var descendantCountCache: [String: Int] = [:]

    private func rebuildTreeCaches() {
        var children: [String: [ReeveMessage]] = [:]
        for m in treeMessages {
            let key = m.parentID ?? ""
            children[key, default: []].append(m)
        }
        for k in children.keys {
            children[k]?.sort { $0.id < $1.id }
        }
        self.childrenByParentCache = children

        var branchInfo: [String: (siblingIDs: [String], index: Int)] = [:]
        for m in treeMessages {
            let key = m.parentID ?? ""
            let siblings = children[key] ?? []
            guard siblings.count > 1 else { continue }
            guard let idx = siblings.firstIndex(where: { $0.id == m.id }) else { continue }
            branchInfo[m.id] = (siblings.map(\.id), idx)
        }
        self.branchInfoCache = branchInfo

        var counts: [String: Int] = [:]
        func dfs(_ id: String) -> Int {
            if let c = counts[id] { return c }
            var c = 0
            for child in children[id] ?? [] {
                c += 1 + dfs(child.id)
            }
            counts[id] = c
            return c
        }
        for m in treeMessages { _ = dfs(m.id) }
        self.descendantCountCache = counts
    }

    /// Sibling info for a given message — its position among messages
    /// sharing the same parent. Returns nil when the message has no
    /// siblings (the common case) so the UI can elide the switcher
    /// entirely. `index` is 0-based. O(1) — backed by `branchInfoCache`.
    public func branchInfo(for messageID: String) -> (siblingIDs: [String], index: Int)? {
        branchInfoCache[messageID]
    }

    /// O(1) "does this message have any direct or indirect children?"
    /// query. Used by the context menu to decide whether to surface the
    /// cascade-delete affordance.
    public func hasDescendants(_ messageID: String) -> Bool {
        (descendantCountCache[messageID] ?? 0) > 0
    }

    /// O(1) count of descendants for the cascade-delete confirmation
    /// alert. Returns 0 for unknown ids.
    public func descendantCount(of messageID: String) -> Int {
        descendantCountCache[messageID] ?? 0
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
        let map = childrenByParentCache
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
