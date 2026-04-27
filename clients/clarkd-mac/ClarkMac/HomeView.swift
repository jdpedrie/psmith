import SwiftUI
import ClarkKit

struct HomeView: View {
    let user: ClarkUser
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @State private var mode: AppMode = .chats
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showingNewConversation = false

    var body: some View {
        Group {
            switch mode {
            case .chats:    chatsShell
            case .settings: settingsShell
            }
        }
        .task {
            await convos.refresh()
            await app.providers.load()
            await app.profiles.load()
        }
    }

    // MARK: - Chats

    private var chatsShell: some View {
        @Bindable var convos = convos
        return NavigationSplitView(columnVisibility: $sidebarVisibility) {
            VStack(spacing: 0) {
                ConversationListView()
                    .frame(maxHeight: .infinity)
                Divider()
                sidebarTray
            }
            .frame(minWidth: 240)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let id = convos.selectedID,
               let conversation = convos.conversations.first(where: { $0.id == id }) {
                ConversationView(conversation: conversation, profiles: app.profiles)
                    .id(id)
            } else {
                EmptyStateView(
                    "No conversation selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: "Pick one from the sidebar or start a new one."
                )
            }
        }
    }

    // MARK: - Settings

    private var settingsShell: some View {
        SettingsView(
            providersModel: app.providers,
            profilesModel: app.profiles,
            onBack: { mode = .chats }
        )
    }

    /// Bottom sidebar row: user menu (sign out) on the left, gear (settings)
    /// and `+` (new conversation) on the right. The trailing buttons share
    /// a `GlassEffectContainer` so they read as floating glass chrome.
    private var sidebarTray: some View {
        HStack(spacing: 8) {
            Menu {
                Button(role: .destructive) {
                    Task { try? await app.client.auth.logout() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(user.username)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        mode = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.glass)
                    .help("Settings")

                    Button {
                        showingNewConversation = true
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .buttonStyle(.glass)
                    .disabled(convos.profiles.isEmpty)
                    .help("New conversation")
                    .popover(isPresented: $showingNewConversation, arrowEdge: .top) {
                        NewConversationPopover(profiles: app.profiles) { profileID, title in
                            showingNewConversation = false
                            if let profileID {
                                Task { _ = await convos.newConversation(profileID: profileID) }
                            }
                            _ = title
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

}
