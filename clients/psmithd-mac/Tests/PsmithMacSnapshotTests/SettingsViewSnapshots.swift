import Testing
import SwiftUI
@testable import PsmithMac
import PsmithKit
import SnapshotHarness

/// Snapshots of the Settings window, one per pane that renders without a
/// live server. Outside the Settings scene the TabView draws its tabs
/// inline rather than as the window toolbar; the panes under it are the
/// same views either way.
@MainActor
struct SettingsViewSnapshots {
    private let settingsSize: [(label: String, size: CGSize)] = [("window", CGSize(width: 1050, height: 640))]

    private func settings(
        _ pane: SettingsCategory,
        providers: ProvidersViewModel = SnapshotStubs.makeProvidersModel(),
        profiles: ProfilesViewModel = SnapshotStubs.makeProfilesModel(),
        providerTab: SettingsProviderTab = .models,
        profileTab: SettingsProfileTab = .general
    ) -> some View {
        let env = SnapshotEnvironment.standard(navMode: .settings)
        env.navigator.settingsCategory = pane
        env.navigator.settingsProviderTab = providerTab
        env.navigator.settingsProfileTab = profileTab
        return PsmithMacEnvironment(
            app: env.app, convos: env.convos,
            navigator: env.navigator, windowState: env.windowState
        ) {
            SettingsView(
                providersModel: providers,
                profilesModel: profiles,
                mcpServersModel: SnapshotStubs.makeMCPServersModel()
            )
        }
    }

    /// No providers yet: the list holds only "Add provider…".
    @Test
    func modelsEmpty() {
        let providers = SnapshotStubs.makeProvidersModel(providers: [], enabledModels: [], selectedID: nil)
        assertViewSnapshots(settings(.models, providers: providers), sizes: settingsSize)
    }

    /// A provider selected: header, models table, provider defaults.
    @Test
    func modelsPopulated() {
        assertViewSnapshots(settings(.models), sizes: settingsSize)
    }

    @Test
    func modelsConnection() {
        assertViewSnapshots(settings(.models, providerTab: .connection), sizes: settingsSize)
    }

    @Test
    func modelsDefaults() {
        assertViewSnapshots(settings(.models, providerTab: .defaults), sizes: settingsSize)
    }

    /// A model drilled into from the table.
    @Test
    func modelPage() {
        let providers = SnapshotStubs.makeProvidersModel()
        if let first = providers.enabledModels.first { providers.detailMode = .editingModel(first.modelID) }
        assertViewSnapshots(settings(.models, providers: providers), sizes: settingsSize)
    }

    @Test
    func addProvider() {
        let providers = SnapshotStubs.makeProvidersModel()
        providers.detailMode = .adding
        assertViewSnapshots(settings(.models, providers: providers), sizes: settingsSize)
    }

    @Test
    func addModel() {
        let providers = SnapshotStubs.makeProvidersModel()
        providers.detailMode = .addingManualModel
        assertViewSnapshots(settings(.models, providers: providers), sizes: settingsSize)
    }

    @Test
    func profiles() {
        let profiles = SnapshotStubs.makeProfilesModel(
            profiles: [SnapshotFixtures.profile()],
            detailMode: .viewing
        )
        assertViewSnapshots(settings(.profiles, profiles: profiles), sizes: settingsSize)
    }

    private func oneProfile() -> ProfilesViewModel {
        SnapshotStubs.makeProfilesModel(profiles: [SnapshotFixtures.profile()], detailMode: .viewing)
    }

    @Test
    func profilePrompt() {
        assertViewSnapshots(settings(.profiles, profiles: oneProfile(), profileTab: .prompt), sizes: settingsSize)
    }

    @Test
    func profileModel() {
        assertViewSnapshots(settings(.profiles, profiles: oneProfile(), profileTab: .model), sizes: settingsSize)
    }

    @Test
    func profilePlugins() {
        assertViewSnapshots(settings(.profiles, profiles: oneProfile(), profileTab: .plugins), sizes: settingsSize)
    }

    @Test
    func profileAutomation() {
        assertViewSnapshots(settings(.profiles, profiles: oneProfile(), profileTab: .automation), sizes: settingsSize)
    }

    @Test
    func newProfile() {
        let profiles = oneProfile()
        profiles.detailMode = .adding
        assertViewSnapshots(settings(.profiles, profiles: profiles), sizes: settingsSize)
    }

    @Test
    func plugins() {
        assertViewSnapshots(settings(.plugins), sizes: settingsSize)
    }

    @Test
    func servers() {
        assertViewSnapshots(settings(.servers), sizes: settingsSize)
    }

    @Test
    func general() {
        assertViewSnapshots(settings(.general), sizes: settingsSize)
    }

    @Test
    func appearance() {
        assertViewSnapshots(settings(.appearance), sizes: settingsSize)
    }
}
