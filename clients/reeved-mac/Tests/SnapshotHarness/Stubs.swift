import Foundation
@_exported import ReeveKit

/// Builders for fully-populated ReeveKit view models that drive snapshot
/// rendering without ever calling out to a reeved server.
///
/// Strategy: every `@Observable` view model in ReeveKit exposes its
/// pre-load state through public `var` properties. We construct a real
/// instance against a `ReeveClient` aimed at a non-routable host (so any
/// stray RPC blows up loud rather than hanging the snapshot), then push
/// fixture data straight into those properties. No method that hits the
/// wire is ever called — the views just render the state we hand them.
///
/// ReeveMac-internal observables (`Navigator`, `WindowState`, `AppMode`)
/// live in the executable target — the test target wires those up itself
/// after `@testable import ReeveMac`.
public enum SnapshotStubs {
    /// Fake host URL used for the no-op ReeveClient. The host won't be
    /// reached because every snapshot path injects pre-loaded state and
    /// avoids triggering view-model methods that issue RPCs (the views'
    /// `.task { … }` blocks won't fire during a one-shot
    /// `assertSnapshot(of: view, …)` render either).
    public static let nullHost = URL(string: "http://snapshot.invalid")!

    @MainActor
    public static func makeClient() -> ReeveClient {
        ReeveClient(
            host: nullHost,
            tokenStore: InMemoryTokenStore(),
            authState: AuthState()
        )
    }

    // MARK: - AppModel

    @MainActor
    public static func makeAppModel(
        providers: [ReeveUserModelProvider] = [SnapshotFixtures.userModelProvider()],
        models: [ReeveUserModel] = [SnapshotFixtures.userModel()],
        profiles: [ReeveProfile] = [SnapshotFixtures.profile()]
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
        conversation: ReeveConversation = SnapshotFixtures.conversation(),
        client: ReeveClient? = nil,
        messages: [ReeveMessage] = SnapshotFixtures.sampleMessages(),
        contexts: [ReeveContext] = [SnapshotFixtures.context()],
        availableModels: [ReeveUserModel] = [SnapshotFixtures.userModel()],
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
        isCompacting: Bool = false,
        showingCompactView: Bool = false,
        showingContextList: Bool = false,
        showingSettingsView: Bool = false,
        compactPromptDraft: String = "",
        compactProviderID: String? = nil,
        compactModelID: String? = nil,
        compactError: String? = nil,
        editingMessage: ReeveMessage? = nil,
        conversationCallSettingsDraft: ReeveCallSettings = ReeveCallSettings(),
        resolvedCallSettings: ReeveCallSettings? = nil,
        settingsResolvedProfile: ReeveProfile? = nil,
        loadError: String? = nil
    ) -> ConversationViewModel {
        let c = client ?? makeClient()
        let vm = ConversationViewModel(
            conversation: conversation,
            client: c,
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
        client: ReeveClient,
        conversations: [ReeveConversation] = SnapshotFixtures.conversations(),
        profiles: [ReeveProfile] = [SnapshotFixtures.profile()],
        selectedID: String? = nil,
        listMode: ConversationListMode = .allChats,
        listOrder: ReeveConversationOrder = .recentlyUsed,
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
        providers: [ReeveUserModelProvider] = SnapshotFixtures.providers(),
        enabledModels: [ReeveUserModel] = SnapshotFixtures.enabledModels(),
        selectedID: String? = "provider-anthropic",
        detailMode: ProvidersDetailMode = .viewing,
        templates: [ReeveProviderTemplate] = SnapshotFixtures.providerTemplates(),
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
        profiles: [ReeveProfile] = [SnapshotFixtures.profile()],
        selectedID: String? = nil,
        detailMode: ProfilesDetailMode = .viewing,
        availableModels: [ReeveUserModel] = SnapshotFixtures.enabledModels(),
        providers: [ReeveUserModelProvider] = SnapshotFixtures.providers(),
        pluginTypes: [ReevePluginType] = [SnapshotFixtures.pluginType()],
        profilePlugins: [String: [ReeveProfilePlugin]] = [:]
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
