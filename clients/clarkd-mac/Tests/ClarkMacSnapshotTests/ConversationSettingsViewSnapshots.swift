import Testing
import SwiftUI
@testable import ClarkMac
import ClarkKit
import SnapshotHarness

/// ConversationSettingsView snapshots. The full-pane "Conversation
/// settings" view shown when the user taps the gear toolbar button.
/// Drives a pre-populated `ConversationViewModel` so the form renders
/// against the right inheritance preview + driver-extras section without
/// firing `prepareSettingsView` against the null host.
///
/// Each variant locks in a specific cell of the form's matrix:
///   - inherit-everywhere with no overrides
///   - one common-section override (temperature)
///   - thinking section toggled on
///   - the three driver-specific extension blocks (anthropic / openai / google)
@MainActor
struct ConversationSettingsViewSnapshots {

    private func wrap(model: ConversationViewModel) -> some View {
        // The CallSettingsForm reads `app.profiles.providerTypes` indirectly
        // through the view model, but the view itself takes the driver type
        // from `model.providerTypes[…]`. The standard env provider list is
        // fine here.
        let env = SnapshotEnvironment.standard()
        return ClarkMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) { ConversationSettingsView(model: model) }
    }

    /// Builds a conversation that points at a specific (provider, model)
    /// pair so the settings view's `effectiveDriverType` resolves to the
    /// driver we want to exercise. Anthropic is the standard fixture; the
    /// other drivers ship as alternates.
    private func conversationFor(providerID: String, modelID: String) -> ClarkConversation {
        var settings = ClarkConversationSettings()
        settings.defaultProviderID = providerID
        settings.defaultModelID = modelID
        return ClarkConversation(
            id: "conv-1",
            profileID: "profile-default",
            title: "Settings test",
            activeContextID: "context-conv-1-1",
            ownerUserID: "user-fixed-1",
            createdAt: SnapshotFixtures.referenceDate,
            updatedAt: SnapshotFixtures.referenceDate,
            lastActivityAt: SnapshotFixtures.referenceDate,
            settings: settings
        )
    }

    @Test
    func noOverrides() {
        // Empty draft + a resolved-from-below snapshot so each field shows
        // its "Inherits …" caption rather than "—".
        let inherited = ClarkCallSettings(
            temperature: 1.0,
            topP: 0.95,
            maxOutputTokens: 4_096,
            stopSequences: [],
            topK: 50,
            thinking: ClarkThinkingSettings(enabled: false, budgetTokens: 1_024)
        )
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [SnapshotFixtures.systemMessage()],
            showingSettingsView: true,
            conversationCallSettingsDraft: ClarkCallSettings(),
            resolvedCallSettings: inherited,
            settingsResolvedProfile: SnapshotFixtures.profile()
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func temperatureOverride() {
        var draft = ClarkCallSettings()
        draft.temperature = 0.45
        let inherited = ClarkCallSettings(temperature: 1.0, topP: 0.95, maxOutputTokens: 4_096)
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [SnapshotFixtures.systemMessage()],
            showingSettingsView: true,
            conversationCallSettingsDraft: draft,
            resolvedCallSettings: inherited,
            settingsResolvedProfile: SnapshotFixtures.profile()
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func thinkingOverride() {
        var draft = ClarkCallSettings()
        draft.thinking = ClarkThinkingSettings(enabled: true, budgetTokens: 4_096)
        let inherited = ClarkCallSettings(
            temperature: 1.0,
            thinking: ClarkThinkingSettings(enabled: false, budgetTokens: 1_024)
        )
        let model = SnapshotStubs.makeConversationViewModel(
            messages: [SnapshotFixtures.systemMessage()],
            showingSettingsView: true,
            conversationCallSettingsDraft: draft,
            resolvedCallSettings: inherited,
            settingsResolvedProfile: SnapshotFixtures.profile()
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func anthropicProvider() {
        // Conversation pinned to the anthropic provider type (the default
        // standard env). Sets a cache override so the AnthropicExtras
        // section has something visible to render under "Inherit".
        var draft = ClarkCallSettings()
        draft.anthropic = ClarkAnthropicExtras(cacheEnabled: false, cacheTTL: .oneHour)
        let inherited = ClarkCallSettings(
            temperature: 1.0,
            anthropic: ClarkAnthropicExtras(cacheEnabled: true, cacheTTL: .fiveMinutes)
        )
        let model = SnapshotStubs.makeConversationViewModel(
            conversation: conversationFor(providerID: "provider-anthropic", modelID: "claude-opus-4-7"),
            messages: [SnapshotFixtures.systemMessage()],
            showingSettingsView: true,
            conversationCallSettingsDraft: draft,
            resolvedCallSettings: inherited,
            settingsResolvedProfile: SnapshotFixtures.profile()
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func openaiProvider() {
        // Wires a second provider so the conversation can resolve to the
        // openai-compatible driver type; CallSettingsForm then renders its
        // OpenAI extras block.
        let openai = SnapshotFixtures.userModelProvider(
            id: "provider-openai",
            type: "openai-compatible",
            label: "OpenAI"
        )
        let openaiModel = ClarkUserModel(
            providerID: openai.id,
            modelID: "gpt-5-pro",
            displayName: "GPT-5 Pro",
            contextWindow: 256_000,
            maxOutputTokens: 8_192,
            pricing: nil,
            knowledgeCutoff: "2026-01",
            modalities: ["text"],
            capabilities: ClarkModelCapabilities(
                streaming: true, thinking: true, toolUse: true,
                vision: true, promptCaching: true
            ),
            favorite: false,
            defaultSettings: nil
        )
        var draft = ClarkCallSettings()
        draft.openai = ClarkOpenAIExtras(seed: 42, frequencyPenalty: 0.5)
        let inherited = ClarkCallSettings(
            temperature: 0.8,
            openai: ClarkOpenAIExtras(seed: 0, frequencyPenalty: 0)
        )
        let model = SnapshotStubs.makeConversationViewModel(
            conversation: conversationFor(providerID: openai.id, modelID: openaiModel.modelID),
            messages: [SnapshotFixtures.systemMessage()],
            availableModels: [openaiModel],
            providerLabels: [openai.id: openai.label],
            providerTypes: [openai.id: openai.type],
            selectedProviderID: openai.id,
            selectedModelID: openaiModel.modelID,
            showingSettingsView: true,
            conversationCallSettingsDraft: draft,
            resolvedCallSettings: inherited,
            settingsResolvedProfile: SnapshotFixtures.profile()
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }

    @Test
    func googleProvider() {
        let google = SnapshotFixtures.userModelProvider(
            id: "provider-google",
            type: "google",
            label: "Google"
        )
        let googleModel = ClarkUserModel(
            providerID: google.id,
            modelID: "gemini-3-pro",
            displayName: "Gemini 3 Pro",
            contextWindow: 1_000_000,
            maxOutputTokens: 8_192,
            pricing: nil,
            knowledgeCutoff: "2026-01",
            modalities: ["text", "image"],
            capabilities: ClarkModelCapabilities(
                streaming: true, thinking: true, toolUse: true,
                vision: true, promptCaching: true
            ),
            favorite: false,
            defaultSettings: nil
        )
        var draft = ClarkCallSettings()
        draft.google = ClarkGoogleExtras(
            safetySettings: ClarkSafetySettings(
                harassment: .blockOnlyHigh,
                hateSpeech: .blockMediumAndAbove,
                sexuallyExplicit: nil,
                dangerousContent: nil
            ),
            responseMimeType: "application/json"
        )
        let inherited = ClarkCallSettings(
            temperature: 0.7,
            google: ClarkGoogleExtras(
                safetySettings: ClarkSafetySettings(harassment: .blockNone),
                candidateCount: 1
            )
        )
        let model = SnapshotStubs.makeConversationViewModel(
            conversation: conversationFor(providerID: google.id, modelID: googleModel.modelID),
            messages: [SnapshotFixtures.systemMessage()],
            availableModels: [googleModel],
            providerLabels: [google.id: google.label],
            providerTypes: [google.id: google.type],
            selectedProviderID: google.id,
            selectedModelID: googleModel.modelID,
            showingSettingsView: true,
            conversationCallSettingsDraft: draft,
            resolvedCallSettings: inherited,
            settingsResolvedProfile: SnapshotFixtures.profile()
        )
        assertViewSnapshots(wrap(model: model), sizes: columnSizes)
    }
}
