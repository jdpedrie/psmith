import SwiftUI
import ReeveKit
import ReeveUI

/// iOS Settings tab root — list of categories grouped into "Data"
/// (the user's configured providers / profiles / plugins) and
/// "Settings" (app-level preferences). Each row pushes its detail
/// screen onto the NavigationStack. Per `docs/ios-screens.md` §2.14.
struct SettingsRoot: View {
    var body: some View {
        List {
            Section("Data") {
                NavigationLink {
                    ProvidersListView()
                } label: {
                    categoryRow("Providers", systemImage: "cpu")
                }
                NavigationLink {
                    ProfilesListView()
                } label: {
                    categoryRow("Profiles", systemImage: "person.crop.rectangle")
                }
                NavigationLink {
                    PluginsListView()
                } label: {
                    categoryRow("Plugins", systemImage: "puzzlepiece.extension")
                }
            }

            Section("Settings") {
                NavigationLink {
                    GeneralDetailView()
                } label: {
                    categoryRow("General", systemImage: "gearshape")
                }
                NavigationLink {
                    AppearanceDetailView()
                } label: {
                    categoryRow("Appearance", systemImage: "paintpalette")
                }
                NavigationLink {
                    NotificationsDetailView()
                } label: {
                    categoryRow("Notifications", systemImage: "bell")
                }
                NavigationLink {
                    PrivacyDetailView()
                } label: {
                    categoryRow("Privacy", systemImage: "hand.raised")
                }
                NavigationLink {
                    CostDetailView()
                } label: {
                    categoryRow("Cost", systemImage: "dollarsign.circle")
                }
                NavigationLink {
                    LangfuseDetailView()
                } label: {
                    categoryRow("Langfuse", systemImage: "chart.line.uptrend.xyaxis")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
    }
}
