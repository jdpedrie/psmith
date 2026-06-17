import Foundation
@_exported import SpaltKit

/// Builders for fully-populated SpaltKit view models that drive snapshot
/// rendering without ever calling out to a spaltd server.
///
/// Strategy: every `@Observable` view model in SpaltKit exposes its
/// pre-load state through public `var` properties. We construct a real
/// instance against a `SpaltClient` aimed at a non-routable host (so any
/// stray RPC blows up loud rather than hanging the snapshot), then push
/// fixture data straight into those properties. No method that hits the
/// wire is ever called — the views just render the state we hand them.
///
/// SpaltMac-internal observables (`Navigator`, `WindowState`, `AppMode`)
/// live in the executable target — the test target wires those up itself
/// after `@testable import SpaltMac`.
public enum SnapshotStubs {
    /// Fake host URL used for the no-op SpaltClient. The host won't be
    /// reached because every snapshot path injects pre-loaded state and
    /// avoids triggering view-model methods that issue RPCs (the views'
    /// `.task { … }` blocks won't fire during a one-shot
    /// `assertSnapshot(of: view, …)` render either).
    public static let nullHost = URL(string: "http://snapshot.invalid")!

    @MainActor
    public static func makeClient() -> SpaltClient {
        SpaltClient(
            host: nullHost,
            tokenStore: InMemoryTokenStore(),
            authState: AuthState()
        )
    }

    // MARK: - AppModel

    @MainActor
    public static func makeAppModel(
        providers: [SpaltUserModelProvider] = [SnapshotFixtures.userModelProvider()],
        models: [SpaltUserModel] = [SnapshotFixtures.userModel()],
        profiles: [SpaltProfile] = [SnapshotFixtures.profile()]
    ) -> AppModel {
        let model = AppModel(
            host: nullHost,
            tokenStore: InMemoryTokenStore(),
            authState: AuthState()
        )
        model.providers.providers = providers
        model.providers.enabledModels = models
        model.providers.selectedID = providers.first?.id
        model.profiles.profiles = profiles
        model.profiles.selectedID = profiles.first?.id
        model.profiles.availableModels = models
        model.profiles.providerLabels = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.label) })
        model.profiles.providerTypes = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.type) })
        return model
    }

    // MARK: - ConversationViewModel

    /// Builds a fully-populated ConversationViewModel for snapshot rendering.
    /// Every property the ConversationBody / CompactPane / ContextListPane /
    /// ConversationSettingsView views read is settable as `@Observable var`,
    /// so we just push fixture state into the live model. The underlying
    /// client is wired to `nullHost` — any RPC kicked off by a `.task { … }`
    /// will fail loudly rather than hanging the snapshot.
    @MainActor
    public static func makeConversationViewModel(
        conversation: SpaltConversation = SnapshotFixtures.conversation(),
        client: SpaltClient? = nil,
        messages: [SpaltMessage] = SnapshotFixtures.sampleMessages(),
        contexts: [SpaltContext] = [SnapshotFixtures.context()],
        availableModels: [SpaltUserModel] = [SnapshotFixtures.userModel()],
        providerLabels: [String: String] = ["provider-anthropic": "Anthropic"],
        providerTypes: [String: String] = ["provider-anthropic": "anthropic"],
        selectedProviderID: String? = "provider-anthropic",
        selectedModelID: String? = "claude-opus-4-7",
        tokenCount: Int32? = 1_742,
        contextWindow: Int32? = 200_000,
        loading: Bool = false,
        sending: Bool = false,
        streamRunID: String? = nil,
        streamingText: String = "",
        streamingToolCalls: [LiveToolCall] = [],
        isCompacting: Bool = false,
        showingCompactView: Bool = false,
        showingContextList: Bool = false,
        showingSettingsView: Bool = false,
        compactPromptDraft: String = "",
        compactProviderID: String? = nil,
        compactModelID: String? = nil,
        compactError: String? = nil,
        editingMessage: SpaltMessage? = nil,
        conversationCallSettingsDraft: SpaltCallSettings = SpaltCallSettings(),
        resolvedCallSettings: SpaltCallSettings? = nil,
        settingsResolvedProfile: SpaltProfile? = nil,
        loadError: String? = nil
    ) -> ConversationViewModel {
        let c = client ?? makeClient()
        let hub = StreamHub(subscriber: c.streams)
        let vm = ConversationViewModel(
            conversation: conversation,
            client: c,
            hub: hub,
            onTerminal: { /* no-op for snapshots */ }
        )
        vm.messages = messages
        vm.contexts = contexts
        vm.activeContext = contexts.first(where: { $0.id == conversation.activeContextID }) ?? contexts.first
        vm.availableModels = availableModels
        vm.providerLabels = providerLabels
        vm.providerTypes = providerTypes
        vm.selectedProviderID = selectedProviderID
        vm.selectedModelID = selectedModelID
        vm.tokenCount = tokenCount
        vm.contextWindow = contextWindow
        vm.loading = loading
        vm.sending = sending
        vm.streamRunID = streamRunID
        vm.streamingText = streamingText
        vm.streamingToolCalls = streamingToolCalls
        vm.isCompacting = isCompacting
        vm.showingCompactView = showingCompactView
        vm.showingContextList = showingContextList
        vm.showingSettingsView = showingSettingsView
        vm.compactPromptDraft = compactPromptDraft
        vm.compactProviderID = compactProviderID
        vm.compactModelID = compactModelID
        vm.compactError = compactError
        vm.editingMessage = editingMessage
        vm.conversationCallSettingsDraft = conversationCallSettingsDraft
        vm.resolvedCallSettings = resolvedCallSettings
        vm.settingsResolvedProfile = settingsResolvedProfile
        vm.loadError = loadError
        return vm
    }

    // MARK: - ConversationsModel

    @MainActor
    public static func makeConversationsModel(
        client: SpaltClient,
        conversations: [SpaltConversation] = SnapshotFixtures.conversations(),
        profiles: [SpaltProfile] = [SnapshotFixtures.profile()],
        selectedID: String? = nil,
        listMode: ConversationListMode = .allChats,
        listOrder: SpaltConversationOrder = .recentlyUsed,
        searchQuery: String = ""
    ) -> ConversationsModel {
        let convos = ConversationsModel(client: client)
        convos.conversations = conversations
        convos.profiles = profiles
        convos.selectedID = selectedID
        convos.listMode = listMode
        convos.listOrder = listOrder
        convos.searchQuery = searchQuery
        return convos
    }

    // MARK: - ProvidersViewModel

    /// Builds a fully-loaded ProvidersViewModel for snapshot tests. Every
    /// `@Observable` property set here is the post-load state — the real
    /// view model would have arrived at it after `load()` + `selectProvider`.
    /// Snapshot views render directly without ever issuing an RPC.
    @MainActor
    public static func makeProvidersModel(
        providers: [SpaltUserModelProvider] = SnapshotFixtures.providers(),
        enabledModels: [SpaltUserModel] = SnapshotFixtures.enabledModels(),
        selectedID: String? = "provider-anthropic",
        detailMode: ProvidersDetailMode = .viewing,
        templates: [SpaltProviderTemplate] = SnapshotFixtures.providerTemplates(),
        templatesLoaded: Bool = true
    ) -> ProvidersViewModel {
        let m = ProvidersViewModel(client: makeClient())
        m.providers = providers
        m.enabledModels = enabledModels
        m.selectedID = selectedID
        m.detailMode = detailMode
        m.templates = templates
        m.templatesLoaded = templatesLoaded
        return m
    }

    // MARK: - ProfilesViewModel

    /// Builds a fully-loaded ProfilesViewModel for snapshot tests. Models +
    /// provider labels/types come from the standard Providers fixture so the
    /// model-picker labels resolve to the same strings the real UI would
    /// render.
    @MainActor
    public static func makeProfilesModel(
        profiles: [SpaltProfile] = [SnapshotFixtures.profile()],
        selectedID: String? = nil,
        detailMode: ProfilesDetailMode = .viewing,
        availableModels: [SpaltUserModel] = SnapshotFixtures.enabledModels(),
        providers: [SpaltUserModelProvider] = SnapshotFixtures.providers(),
        pluginTypes: [SpaltPluginType] = [SnapshotFixtures.pluginType()],
        profilePlugins: [String: [SpaltProfilePlugin]] = [:]
    ) -> ProfilesViewModel {
        let m = ProfilesViewModel(client: makeClient())
        m.profiles = profiles
        m.selectedID = selectedID ?? profiles.first?.id
        m.detailMode = detailMode
        m.availableModels = availableModels
        m.providerLabels = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.label) })
        m.providerTypes = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.type) })
        m.pluginTypes = pluginTypes
        m.profilePlugins = profilePlugins
        return m
    }
}
