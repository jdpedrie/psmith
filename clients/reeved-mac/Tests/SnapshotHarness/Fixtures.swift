import Foundation
@_exported import ReeveKit

/// Pre-built ReeveKit domain models for snapshot tests. Every value is
/// deterministic — fixed UUID-shaped strings, fixed timestamps — so two
/// runs of the same test render identical pixel output. Callers compose
/// these into stub view-model state via `Stubs`.
public enum SnapshotFixtures {
    // MARK: - Determinism

    /// Fixed reference timestamp used everywhere a fixture would otherwise
    /// reach for `Date()`. Picked so the rendered "Created Apr 1, 2026"
    /// strings stay stable across runs.
    public static let referenceDate = Date(timeIntervalSince1970: 1_743_465_600) // 2026-04-01 00:00 UTC

    // MARK: - User

    public static func user(
        id: String = "user-fixed-1",
        username: String = "ada",
        displayName: String? = "Ada Lovelace",
        isAdmin: Bool = false
    ) -> ReeveUser {
        ReeveUser(id: id, username: username, displayName: displayName, isAdmin: isAdmin)
    }

    // MARK: - Profiles

    public static func profile(
        id: String = "profile-default",
        name: String = "Default",
        description: String = "General-purpose chats.",
        parentOnly: Bool = false,
        favorite: Bool = true,
        parent: ReeveProfile? = nil,
        defaultProviderID: String? = "provider-anthropic",
        defaultModelID: String? = "claude-opus-4-7"
    ) -> ReeveProfile {
        ReeveProfile(
            id: id,
            name: name,
            description: description,
            parentOnly: parentOnly,
            favorite: favorite,
            parentProfileID: parent?.id,
            systemMessage: "You are a helpful assistant.",
            defaultUserMessage: nil,
            compressionGuide: nil,
            compressionMode: nil,
            compressionProviderID: nil,
            compressionModelID: nil,
            defaultSettings: ReeveProfileDefaults(
                defaultProviderID: defaultProviderID,
                defaultModelID: defaultModelID
            ),
            titleProviderID: nil,
            titleModelID: nil,
            titleGuide: nil,
            titleProviderKind: nil,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
    }

    /// A minimal "parent only" profile — used by tests that want to verify
    /// the New Conversation button stays disabled when no chat-capable
    /// profile exists.
    public static func parentOnlyProfile(
        id: String = "profile-parent-only",
        name: String = "Shared Defaults"
    ) -> ReeveProfile {
        profile(id: id, name: name, description: "Inheritable settings only.", parentOnly: true, favorite: false)
    }

    // MARK: - Providers + models

    public static func userModelProvider(
        id: String = "provider-anthropic",
        type: String = "anthropic",
        label: String = "Anthropic"
    ) -> ReeveUserModelProvider {
        ReeveUserModelProvider(
            id: id,
            type: type,
            label: label,
            createdAt: referenceDate,
            updatedAt: referenceDate,
            defaultSettings: nil
        )
    }

    public static func userModel(
        providerID: String = "provider-anthropic",
        modelID: String = "claude-opus-4-7",
        displayName: String = "Claude Opus 4.7",
        contextWindow: Int32? = 200_000,
        favorite: Bool = true,
        capabilities: ReeveModelCapabilities? = ReeveModelCapabilities(
            streaming: true, thinking: true, toolUse: true, vision: true, promptCaching: true
        )
    ) -> ReeveUserModel {
        ReeveUserModel(
            providerID: providerID,
            modelID: modelID,
            displayName: displayName,
            contextWindow: contextWindow,
            maxOutputTokens: 8_192,
            pricing: ReeveModelPricing(
                inputPerMillion: 15.0,
                outputPerMillion: 75.0,
                cacheReadPerMillion: 1.5,
                cacheWritePerMillion: 18.75
            ),
            knowledgeCutoff: "2026-01",
            modalities: ["text", "image"],
            capabilities: capabilities,
            favorite: favorite,
            defaultSettings: nil
        )
    }

    /// Note: `ReeveDiscoveredModel` doesn't expose a public memberwise
    /// init — only the proto-bridging one. Snapshot tests that need a
    /// "discovered models" UI surface should drive ProvidersViewModel
    /// state directly via `.enabledModels` rather than building a
    /// fixture, or extend ReeveKit when that test ships.

    // MARK: - Conversations + messages

    public static func conversation(
        id: String = "conv-1",
        title: String? = "Snapshot test chat",
        profileID: String = "profile-default",
        createdAt: Date = referenceDate,
        lastActivityAt: Date? = nil
    ) -> ReeveConversation {
        ReeveConversation(
            id: id,
            profileID: profileID,
            title: title,
            activeContextID: "context-\(id)-1",
            ownerUserID: "user-fixed-1",
            createdAt: createdAt,
            updatedAt: createdAt,
            lastActivityAt: lastActivityAt ?? createdAt,
            settings: nil
        )
    }

    /// Four-conversation fixture used to fill out the "All Chats" list at
    /// realistic density. Titles vary in length so row layout assertions
    /// catch truncation bugs.
    public static func conversations(profileID: String = "profile-default") -> [ReeveConversation] {
        [
            conversation(id: "conv-1", title: "Initial planning notes",
                         profileID: profileID,
                         createdAt: referenceDate.addingTimeInterval(-3600)),
            conversation(id: "conv-2", title: "Architecture review — encryption tiers",
                         profileID: profileID,
                         createdAt: referenceDate.addingTimeInterval(-7200)),
            conversation(id: "conv-3", title: "Bug: snapshot harness flake",
                         profileID: profileID,
                         createdAt: referenceDate.addingTimeInterval(-10800)),
            conversation(id: "conv-4", title: nil,
                         profileID: profileID,
                         createdAt: referenceDate.addingTimeInterval(-14400)),
        ]
    }

    // MARK: - Contexts

    public static func context(
        id: String = "context-conv-1-1",
        conversationID: String = "conv-1",
        parentContextID: String? = nil,
        title: String? = nil,
        createdAt: Date = referenceDate,
        activationTime: Date? = nil,
        messageCount: Int = 0,
        lastMessageTotalTokens: Int64 = 0,
        cumulativeCostUsd: Double = 0
    ) -> ReeveContext {
        ReeveContext(
            id: id,
            conversationID: conversationID,
            parentContextID: parentContextID,
            activationTime: activationTime,
            createdAt: createdAt,
            currentLeafMessageID: nil,
            title: title,
            messageCount: messageCount,
            lastMessageTotalTokens: lastMessageTotalTokens,
            cumulativeCostUsd: cumulativeCostUsd
        )
    }

    /// Three-context chain that walks parent → child → grandchild for
    /// snapshot tests covering the contexts page's parent-link rendering.
    public static func contextChain(conversationID: String = "conv-1") -> [ReeveContext] {
        let root = context(
            id: "context-1",
            conversationID: conversationID,
            title: "Initial discussion",
            createdAt: referenceDate.addingTimeInterval(-7200),
            activationTime: referenceDate.addingTimeInterval(-3600),
            messageCount: 6,
            lastMessageTotalTokens: 1_240,
            cumulativeCostUsd: 0.0123
        )
        let mid = context(
            id: "context-2",
            conversationID: conversationID,
            parentContextID: root.id,
            title: "After first compaction",
            createdAt: referenceDate.addingTimeInterval(-3600),
            activationTime: referenceDate.addingTimeInterval(-1800),
            messageCount: 4,
            lastMessageTotalTokens: 880,
            cumulativeCostUsd: 0.0089
        )
        let leaf = context(
            id: "context-3",
            conversationID: conversationID,
            parentContextID: mid.id,
            title: nil,
            createdAt: referenceDate.addingTimeInterval(-600),
            activationTime: referenceDate,
            messageCount: 2,
            lastMessageTotalTokens: 320,
            cumulativeCostUsd: 0.0034
        )
        return [root, mid, leaf]
    }

    // MARK: - Messages

    public static func systemMessage(
        id: String = "msg-system",
        contextID: String = "context-conv-1-1",
        content: String = "You are a helpful assistant."
    ) -> ReeveMessage {
        ReeveMessage(
            id: id,
            contextID: contextID,
            parentID: nil,
            role: .system,
            content: content
        )
    }

    public static func userMessage(
        id: String = "msg-user-1",
        contextID: String = "context-conv-1-1",
        parentID: String? = "msg-system",
        content: String = "What's a good way to test SwiftUI views?"
    ) -> ReeveMessage {
        ReeveMessage(
            id: id,
            contextID: contextID,
            parentID: parentID,
            role: .user,
            content: content
        )
    }

    public static func assistantMessage(
        id: String = "msg-assistant-1",
        contextID: String = "context-conv-1-1",
        parentID: String? = "msg-user-1",
        content: String = "Snapshot testing is the standard approach. Render the view to a bitmap, compare against a committed reference image, and fail on diff.",
        providerID: String? = "provider-anthropic",
        modelID: String? = "claude-opus-4-7",
        usage: ReeveMessageUsage? = SnapshotFixtures.standardUsage(),
        toolCalls: [ReeveToolCall] = []
    ) -> ReeveMessage {
        ReeveMessage(
            id: id,
            contextID: contextID,
            parentID: parentID,
            role: .assistant,
            content: content,
            providerID: providerID,
            modelID: modelID,
            usage: usage,
            toolCalls: toolCalls
        )
    }

    /// Two web-search tool calls — one successful, one with an error —
    /// suitable for snapshotting the historical pill rendering on a
    /// MessageRow. Output bytes are deterministic so the snapshot diff
    /// stays stable across runs.
    public static func sampleToolCalls() -> [ReeveToolCall] {
        let input1 = #"{"query":"who won the 2026 kentucky derby"}"#.data(using: .utf8)!
        let output1 = #"{"results":[{"title":"Sample","url":"https://example.com","description":"…"}]}"#
            .data(using: .utf8)!
        let input2 = #"{"query":"2026 derby field"}"#.data(using: .utf8)!
        return [
            ReeveToolCall(
                id: "call-1",
                name: "web_search",
                input: input1,
                output: output1,
                error: nil,
                elapsedMs: 412,
                providerOpaque: nil
            ),
            ReeveToolCall(
                id: "call-2",
                name: "web_search",
                input: input2,
                output: Data(),
                error: "upstream rate-limited",
                elapsedMs: 1_240,
                providerOpaque: nil
            ),
        ]
    }

    /// Standard token + cost shape for a typical assistant turn. Includes
    /// cache-read tokens so the usage popover's cache-savings split renders.
    public static func standardUsage() -> ReeveMessageUsage {
        ReeveMessageUsage(
            inputTokens: 1_280,
            outputTokens: 462,
            cacheReadTokens: 980,
            cacheWriteTokens: 220,
            reasoningTokens: nil,
            inputCostUsd: 0.0192,
            outputCostUsd: 0.0347,
            cacheReadCostUsd: 0.00147,
            cacheWriteCostUsd: 0.00413,
            totalCostUsd: 0.0595
        )
    }

    /// Errored assistant message — paints the orange "FAILED" banner row.
    public static func erroredAssistantMessage(
        id: String = "msg-assistant-err",
        contextID: String = "context-conv-1-1",
        parentID: String? = "msg-user-1",
        partialContent: String = "I was about to explain when",
        errorText: String = "context_length_exceeded: too many tokens in prompt"
    ) -> ReeveMessage {
        ReeveMessage(
            id: id,
            contextID: contextID,
            parentID: parentID,
            role: .assistant,
            content: partialContent,
            providerID: "provider-anthropic",
            modelID: "claude-opus-4-7",
            usage: nil,
            errorText: errorText
        )
    }

    /// Compression summary message — the cards rendered between contexts.
    public static func compressionSummaryMessage(
        id: String = "msg-compression",
        contextID: String = "context-conv-1-1",
        content: String = "**Conversation summary:** The user asked about SwiftUI snapshot testing; the assistant explained the snapshot-on-disk + diff workflow and pointed at the swift-snapshot-testing package."
    ) -> ReeveMessage {
        ReeveMessage(
            id: id,
            contextID: contextID,
            parentID: nil,
            role: .compressionSummary,
            content: content,
            providerID: "provider-anthropic",
            modelID: "claude-opus-4-7"
        )
    }

    /// User + assistant pair (with a system prelude) for a "loaded conversation"
    /// snapshot. Sized small enough to render in the default snapshot canvas
    /// without scrolling.
    public static func sampleMessages() -> [ReeveMessage] {
        [
            systemMessage(),
            userMessage(),
            assistantMessage(),
        ]
    }

    // MARK: - Plugins

    public static func pluginType(
        name: String = "lettered_choices",
        description: String = "Multiple-choice scaffold with letter prefixes.",
        configFields: [ReeveConfigField] = SnapshotFixtures.letteredChoicesConfigFields()
    ) -> ReevePluginType {
        ReevePluginType(
            name: name,
            description: description,
            capabilities: ReevePluginCapabilities(
                configurable: true,
                systemPrompter: true,
                outgoingUserTransformer: false,
                historyTransformer: true,
                chunkTransformer: false,
                displayTransformer: true,
                toolProvider: false
            ),
            configFields: configFields
        )
    }

    /// Canonical lettered_choices config — mirrors the exact shape the
    /// `plugins/lettered_choices.go` server registers, so PluginConfigForm
    /// snapshots match what real users see when configuring the plugin.
    public static func letteredChoicesConfigFields() -> [ReeveConfigField] {
        [
            numberConfigField(
                name: "keep_last_n",
                display: "Keep last N",
                description: "Number of trailing assistant turns whose choice blocks are kept intact.",
                defaultJSON: "1"
            ),
            textConfigField(
                name: "open_tag",
                display: "Open tag",
                description: "Opening delimiter for the choices block.",
                defaultJSON: "\"<choices>\""
            ),
            textConfigField(
                name: "close_tag",
                display: "Close tag",
                description: "Closing delimiter for the choices block.",
                defaultJSON: "\"</choices>\""
            ),
            textareaConfigField(
                name: "system_instruction_override",
                display: "System instruction override",
                description: "If set, replaces the default system-message instruction.",
                defaultJSON: ""
            ),
        ]
    }

    // MARK: - ConfigField builders by type

    public static func numberConfigField(
        name: String = "keep_last_n",
        display: String = "Keep last N",
        description: String = "Number of trailing assistant turns whose choice blocks are kept intact.",
        defaultJSON: String = "1"
    ) -> ReeveConfigField {
        ReeveConfigField(
            name: name,
            display: display,
            description: description,
            type: .number,
            defaultJSON: defaultJSON,
            options: []
        )
    }

    public static func textConfigField(
        name: String = "open_tag",
        display: String = "Open tag",
        description: String = "Opening delimiter for the choices block.",
        defaultJSON: String = "\"<choices>\""
    ) -> ReeveConfigField {
        ReeveConfigField(
            name: name,
            display: display,
            description: description,
            type: .text,
            defaultJSON: defaultJSON,
            options: []
        )
    }

    public static func textareaConfigField(
        name: String = "system_instruction_override",
        display: String = "System instruction override",
        description: String = "If set, replaces the default system-message instruction.",
        defaultJSON: String = ""
    ) -> ReeveConfigField {
        ReeveConfigField(
            name: name,
            display: display,
            description: description,
            type: .textarea,
            defaultJSON: defaultJSON,
            options: []
        )
    }

    public static func booleanConfigField(
        name: String = "include_freeform",
        display: String = "Allow freeform reply",
        description: String = "When true, users may bypass the lettered options.",
        defaultJSON: String = "true"
    ) -> ReeveConfigField {
        ReeveConfigField(
            name: name,
            display: display,
            description: description,
            type: .boolean,
            defaultJSON: defaultJSON,
            options: []
        )
    }

    /// Select with ≤ 4 options — renders as the popover-with-buttons
    /// variant in `PluginConfigForm`. Three options keeps it well under
    /// the 4-option threshold while leaving headroom to add one without
    /// flipping the rendering branch.
    public static func selectShortConfigField(
        name: String = "preset",
        display: String = "Style preset",
        description: String = "Picks a built-in prompt phrasing.",
        defaultJSON: String = "\"compact\""
    ) -> ReeveConfigField {
        ReeveConfigField(
            name: name,
            display: display,
            description: description,
            type: .select,
            defaultJSON: defaultJSON,
            options: [
                ReeveConfigOption(value: "compact", label: "Compact"),
                ReeveConfigOption(value: "verbose", label: "Verbose"),
                ReeveConfigOption(value: "academic", label: "Academic"),
            ]
        )
    }

    /// Select with > 4 options — renders as `Picker(.menu)` collapsed.
    /// Six options is the minimum to exercise the >4 branch with a bit
    /// of margin.
    public static func selectLongConfigField(
        name: String = "tone",
        display: String = "Reply tone",
        description: String = "Voicing applied to the assistant's wrapped choice block.",
        defaultJSON: String = "\"neutral\""
    ) -> ReeveConfigField {
        ReeveConfigField(
            name: name,
            display: display,
            description: description,
            type: .select,
            defaultJSON: defaultJSON,
            options: [
                ReeveConfigOption(value: "neutral",   label: "Neutral"),
                ReeveConfigOption(value: "playful",   label: "Playful"),
                ReeveConfigOption(value: "formal",    label: "Formal"),
                ReeveConfigOption(value: "academic",  label: "Academic"),
                ReeveConfigOption(value: "concise",   label: "Concise"),
                ReeveConfigOption(value: "elaborate", label: "Elaborate"),
            ]
        )
    }

    // MARK: - ModelCapabilities profiles

    /// Capability profile for a top-tier reasoning model — every flag on.
    /// This is the default `userModel()` capabilities; spelled out here
    /// for readability when test bodies build models inline.
    public static func capabilitiesAllOn() -> ReeveModelCapabilities {
        ReeveModelCapabilities(
            streaming: true, thinking: true, toolUse: true, vision: true, promptCaching: true
        )
    }

    /// Capability profile for a model that explicitly does not support
    /// extended thinking — e.g. an older Claude or a vision-only model.
    /// Used to verify CallSettingsForm hides its Thinking section even
    /// when the driver type would otherwise allow it.
    public static func capabilitiesNoThinking() -> ReeveModelCapabilities {
        ReeveModelCapabilities(
            streaming: true, thinking: false, toolUse: true, vision: true, promptCaching: true
        )
    }

    // MARK: - CallSettings with extras populated by driver

    /// Inherited-settings vector with values across the universal common
    /// section (so unset fields show "Inherit" pills with concrete values).
    /// Drivers that need their own extras inherited should compose these
    /// further via the `*Inherited` helpers below.
    public static func commonInheritedCallSettings() -> ReeveCallSettings {
        ReeveCallSettings(
            temperature: 0.7,
            topP: 0.95,
            maxOutputTokens: 4_096,
            stopSequences: ["</done>"],
            topK: 40,
            thinking: ReeveThinkingSettings(enabled: true, budgetTokens: 8_192)
        )
    }

    /// Explicit Anthropic-driver extras, every field set so the section
    /// renders fully populated when used as the active settings.
    public static func anthropicExtrasCallSettings() -> ReeveCallSettings {
        var s = ReeveCallSettings()
        s.anthropic = ReeveAnthropicExtras(cacheEnabled: true, cacheTTL: .oneHour)
        s.thinking  = ReeveThinkingSettings(enabled: true, budgetTokens: 12_000)
        return s
    }

    /// Explicit OpenAI-driver extras with every field populated. Used to
    /// snapshot the OpenAI section in its "fully overridden" state.
    public static func openaiExtrasCallSettings() -> ReeveCallSettings {
        var s = ReeveCallSettings()
        s.openai = ReeveOpenAIExtras(
            seed: 42,
            frequencyPenalty: 0.5,
            presencePenalty: -0.25,
            topLogprobs: 3,
            parallelToolCalls: true,
            serviceTier: .priority,
            responseFormat: .jsonObject,
            logitBias: [50256: -50.0, 198: 5.0]
        )
        return s
    }

    /// Explicit Google-driver extras. Hits every field including the
    /// nested SafetySettings object and the response_schema bytes blob.
    public static func googleExtrasCallSettings() -> ReeveCallSettings {
        var s = ReeveCallSettings()
        s.google = ReeveGoogleExtras(
            safetySettings: ReeveSafetySettings(
                harassment: .blockMediumAndAbove,
                hateSpeech: .blockOnlyHigh,
                sexuallyExplicit: .blockLowAndAbove,
                dangerousContent: .blockNone
            ),
            responseMimeType: "application/json",
            responseSchema: Data(#"{"type":"object"}"#.utf8),
            candidateCount: 2
        )
        return s
    }

    // MARK: - Settings: profile chains, providers, models, plugins

    /// Three-profile chain — Root (parent-only) → Coding → Coding · Rust.
    /// Used by tests that need the parent-chain renderer to print more than
    /// one level (ProfilePickerRow, ProfileViewer with parent badge,
    /// ProfileCard parent chain text).
    public static func profileChain() -> [ReeveProfile] {
        let root = profile(
            id: "profile-root",
            name: "Shared Defaults",
            description: "Inheritable settings only.",
            parentOnly: true,
            favorite: false,
            parent: nil
        )
        let middle = profile(
            id: "profile-coding",
            name: "Coding",
            description: "Concise, code-first answers.",
            parentOnly: false,
            favorite: true,
            parent: root
        )
        let leaf = profile(
            id: "profile-coding-rust",
            name: "Coding · Rust",
            description: "Rust-flavoured coding profile.",
            parentOnly: false,
            favorite: false,
            parent: middle
        )
        return [root, middle, leaf]
    }

    /// Three providers covering the three driver types the UI special-cases:
    /// Anthropic (native), OpenAI-compatible (Groq), Google. Used by
    /// snapshots that want a more realistic providers list than the single
    /// Anthropic default.
    public static func providers() -> [ReeveUserModelProvider] {
        [
            userModelProvider(id: "provider-anthropic", type: "anthropic", label: "Anthropic"),
            userModelProvider(id: "provider-groq", type: "openai-compatible", label: "Groq"),
            userModelProvider(id: "provider-google", type: "google", label: "Google AI"),
        ]
    }

    /// Five models split across the three providers from `providers()`.
    /// Mix of capabilities and pricing so the badges + cost buckets render
    /// at variety in the model list snapshots.
    public static func enabledModels() -> [ReeveUserModel] {
        [
            ReeveUserModel(
                providerID: "provider-anthropic",
                modelID: "claude-opus-4-7",
                displayName: "Claude Opus 4.7",
                contextWindow: 200_000,
                maxOutputTokens: 8_192,
                pricing: ReeveModelPricing(
                    inputPerMillion: 15.0,
                    outputPerMillion: 75.0,
                    cacheReadPerMillion: 1.5,
                    cacheWritePerMillion: 18.75
                ),
                knowledgeCutoff: "2026-01",
                modalities: ["text", "image"],
                capabilities: ReeveModelCapabilities(
                    streaming: true, thinking: true, toolUse: true, vision: true, promptCaching: true
                ),
                favorite: true,
                defaultSettings: nil
            ),
            ReeveUserModel(
                providerID: "provider-anthropic",
                modelID: "claude-haiku-4-7",
                displayName: "Claude Haiku 4.7",
                contextWindow: 200_000,
                maxOutputTokens: 8_192,
                pricing: ReeveModelPricing(
                    inputPerMillion: 1.0,
                    outputPerMillion: 5.0,
                    cacheReadPerMillion: 0.10,
                    cacheWritePerMillion: 1.25
                ),
                knowledgeCutoff: "2025-10",
                modalities: ["text", "image"],
                capabilities: ReeveModelCapabilities(
                    streaming: true, thinking: false, toolUse: true, vision: true, promptCaching: true
                ),
                favorite: false,
                defaultSettings: nil
            ),
            ReeveUserModel(
                providerID: "provider-groq",
                modelID: "llama-3.3-70b-versatile",
                displayName: "Llama 3.3 70B Versatile",
                contextWindow: 128_000,
                maxOutputTokens: 8_192,
                pricing: ReeveModelPricing(
                    inputPerMillion: 0.59,
                    outputPerMillion: 0.79,
                    cacheReadPerMillion: nil,
                    cacheWritePerMillion: nil
                ),
                knowledgeCutoff: "2024-12",
                modalities: ["text"],
                capabilities: ReeveModelCapabilities(
                    streaming: true, thinking: false, toolUse: true, vision: false, promptCaching: false
                ),
                favorite: false,
                defaultSettings: nil
            ),
            ReeveUserModel(
                providerID: "provider-google",
                modelID: "gemini-2.5-pro",
                displayName: "Gemini 2.5 Pro",
                contextWindow: 2_000_000,
                maxOutputTokens: 65_536,
                pricing: ReeveModelPricing(
                    inputPerMillion: 1.25,
                    outputPerMillion: 10.0,
                    cacheReadPerMillion: 0.31,
                    cacheWritePerMillion: nil
                ),
                knowledgeCutoff: "2025-06",
                modalities: ["text", "image", "video", "audio"],
                capabilities: ReeveModelCapabilities(
                    streaming: true, thinking: true, toolUse: true, vision: true, promptCaching: true
                ),
                favorite: true,
                defaultSettings: nil
            ),
            ReeveUserModel(
                providerID: "provider-google",
                modelID: "gemini-2.5-flash",
                displayName: "Gemini 2.5 Flash",
                contextWindow: 1_000_000,
                maxOutputTokens: 8_192,
                pricing: ReeveModelPricing(
                    inputPerMillion: 0.10,
                    outputPerMillion: 0.40,
                    cacheReadPerMillion: 0.025,
                    cacheWritePerMillion: nil
                ),
                knowledgeCutoff: "2025-06",
                modalities: ["text", "image"],
                capabilities: ReeveModelCapabilities(
                    streaming: true, thinking: false, toolUse: true, vision: true, promptCaching: true
                ),
                favorite: false,
                defaultSettings: nil
            ),
        ]
    }

    /// Five-template catalog covering both driver types. Lets the
    /// AddProviderForm template grid render at realistic density.
    public static func providerTemplates() -> [ReeveProviderTemplate] {
        [
            ReeveProviderTemplate(
                catalogProviderID: "anthropic",
                name: "Anthropic",
                driverType: "anthropic",
                apiBase: "https://api.anthropic.com",
                envKey: "ANTHROPIC_API_KEY",
                docURL: "https://docs.anthropic.com"
            ),
            ReeveProviderTemplate(
                catalogProviderID: "groq",
                name: "Groq",
                driverType: "openai-compatible",
                apiBase: "https://api.groq.com/openai/v1",
                envKey: "GROQ_API_KEY",
                docURL: "https://console.groq.com/docs"
            ),
            ReeveProviderTemplate(
                catalogProviderID: "openrouter",
                name: "OpenRouter",
                driverType: "openai-compatible",
                apiBase: "https://openrouter.ai/api/v1",
                envKey: "OPENROUTER_API_KEY",
                docURL: nil
            ),
            ReeveProviderTemplate(
                catalogProviderID: "openai",
                name: "OpenAI",
                driverType: "openai-compatible",
                apiBase: "https://api.openai.com/v1",
                envKey: "OPENAI_API_KEY",
                docURL: nil
            ),
            ReeveProviderTemplate(
                catalogProviderID: "deepseek",
                name: "DeepSeek",
                driverType: "openai-compatible",
                apiBase: "https://api.deepseek.com",
                envKey: "DEEPSEEK_API_KEY",
                docURL: nil
            ),
        ]
    }

    /// Realistic discovered-models list for the DiscoverModelsInline
    /// snapshot — three already enabled, three not. Mix of capabilities so
    /// the row badges render at variety.
    public static func discoveredModels() -> [ReeveDiscoveredModel] {
        [
            ReeveDiscoveredModel(
                modelID: "claude-opus-4-7",
                displayName: "Claude Opus 4.7",
                contextWindow: 200_000,
                pricing: ReeveModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.5, cacheWritePerMillion: 18.75),
                capabilities: ReeveModelCapabilities(streaming: true, thinking: true, toolUse: true, vision: true, promptCaching: true),
                alreadyEnabled: true
            ),
            ReeveDiscoveredModel(
                modelID: "claude-sonnet-4-7",
                displayName: "Claude Sonnet 4.7",
                contextWindow: 200_000,
                pricing: ReeveModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
                capabilities: ReeveModelCapabilities(streaming: true, thinking: true, toolUse: true, vision: true, promptCaching: true),
                alreadyEnabled: false
            ),
            ReeveDiscoveredModel(
                modelID: "claude-haiku-4-7",
                displayName: "Claude Haiku 4.7",
                contextWindow: 200_000,
                pricing: ReeveModelPricing(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheReadPerMillion: 0.10, cacheWritePerMillion: 1.25),
                capabilities: ReeveModelCapabilities(streaming: true, thinking: false, toolUse: true, vision: true, promptCaching: true),
                alreadyEnabled: true
            ),
            ReeveDiscoveredModel(
                modelID: "claude-opus-4-5",
                displayName: "Claude Opus 4.5",
                contextWindow: 200_000,
                pricing: ReeveModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.5, cacheWritePerMillion: 18.75),
                capabilities: ReeveModelCapabilities(streaming: true, thinking: false, toolUse: true, vision: true, promptCaching: true),
                alreadyEnabled: false
            ),
            ReeveDiscoveredModel(
                modelID: "claude-3-5-sonnet-20241022",
                displayName: "Claude 3.5 Sonnet",
                contextWindow: 200_000,
                pricing: ReeveModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
                capabilities: ReeveModelCapabilities(streaming: true, thinking: false, toolUse: true, vision: true, promptCaching: true),
                alreadyEnabled: false
            ),
            ReeveDiscoveredModel(
                modelID: "claude-3-haiku-20240307",
                displayName: "Claude 3 Haiku",
                contextWindow: 200_000,
                pricing: ReeveModelPricing(inputPerMillion: 0.25, outputPerMillion: 1.25, cacheReadPerMillion: nil, cacheWritePerMillion: nil),
                capabilities: ReeveModelCapabilities(streaming: true, thinking: false, toolUse: true, vision: true, promptCaching: false),
                alreadyEnabled: true
            ),
        ]
    }

    /// One ReeveProfilePlugin attached to a profile. JSON config encodes
    /// realistic lettered_choices values.
    public static func attachedPlugin(
        pluginName: String = "lettered_choices",
        config: [String: Any] = [
            "tag": "choices",
            "max_options": 6,
            "include_freeform": true,
            "preset": "compact"
        ]
    ) -> ReeveProfilePlugin {
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data()
        return ReeveProfilePlugin(pluginName: pluginName, ordinal: 0, config: data)
    }
}
