import SwiftUI
import PsmithKit
import PsmithUI

/// The Settings window, built to the "Settings" page of the redesign
/// canvas: a header of pane tabs, then the pane. Panes that manage records
/// (Accounts, Models, Profiles, Plugins, Servers, Integrations) list them
/// on the left and show the selected one on the right; the rest are one
/// column of groups.
struct SettingsView: View {
    @Bindable var providersModel: ProvidersViewModel
    @Bindable var profilesModel: ProfilesViewModel
    @Bindable var mcpServersModel: MCPServersViewModel

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(spacing: 0) {
            SettingsToolbar()
            content(navigator.settingsCategory)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SK.window.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .environment(\.colorScheme, .dark)
        .tint(SK.accent)
        .background(SettingsWindowConfigurator(title: navigator.settingsCategory.label))
        .frame(minWidth: 1052, idealWidth: 1052, minHeight: 600, idealHeight: 672)
        .onAppear { consumePendingProfileSelection() }
        .onChange(of: navigator.pendingProfileSelection) { _, _ in
            consumePendingProfileSelection()
        }
    }

    /// If a ProfileCard's gear button asked us to drill into a specific
    /// profile, switch to Profiles and select it. Cleared once consumed
    /// so a later visit doesn't jump again.
    private func consumePendingProfileSelection() {
        guard let id = navigator.pendingProfileSelection else { return }
        navigator.settingsCategory = .profiles
        profilesModel.select(id)
        navigator.pendingProfileSelection = nil
    }

    @ViewBuilder
    private func content(_ pane: SettingsCategory) -> some View {
        switch pane {
        case .general:
            GeneralSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .accounts:
            AccountsSettingsView()
        case .models:
            ModelsPane(model: providersModel)
        case .profiles:
            ProfilesPane(model: profilesModel)
        case .plugins:
            PluginsPane(model: profilesModel)
        case .servers:
            ServersPane(model: mcpServersModel)
        case .usage:
            CostSettingsView()
        case .integrations:
            IntegrationsPane(client: app.client)
        }
    }
}
