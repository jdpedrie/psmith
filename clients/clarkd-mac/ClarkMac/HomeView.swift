import SwiftUI
import ClarkKit

struct HomeView: View {
    let user: ClarkUser
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(Navigator.self) private var navigator
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showingUserMenu: Bool = false

    private var mode: AppMode { navigator.mode }

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
            if navigator.composingNewConversation {
                NewConversationView()
            } else if let id = convos.selectedID,
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
        // If the user picks a conversation from the sidebar while the
        // new-conversation pane is up, dismiss the form and show the
        // chosen conversation instead. Initial load is suppressed via
        // `initial: false` so this only fires on user-driven changes.
        .onChange(of: convos.selectedID, initial: false) { _, newID in
            if newID != nil, navigator.composingNewConversation {
                navigator.composingNewConversation = false
            }
        }
    }

    // MARK: - Settings

    private var settingsShell: some View {
        SettingsView(
            providersModel: app.providers,
            profilesModel: app.profiles,
            onBack: { navigator.mode = .chats }
        )
    }

    /// Bottom sidebar row: user menu (sign out) on the left, gear (settings)
    /// and `+` (new conversation) on the right. The trailing buttons share
    /// a `GlassEffectContainer` so they read as floating glass chrome.
    private var sidebarTray: some View {
        HStack(spacing: 8) {
            // Plain Button + popover instead of SwiftUI Menu — single-item
            // macOS Menus render as zero-height rows on macOS 26 (the user
            // saw the menu pop empty). Popover is reliable and gives us the
            // same affordance.
            Button {
                showingUserMenu = true
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
            .buttonStyle(.plain)
            .popover(isPresented: $showingUserMenu, arrowEdge: .top) {
                Button(role: .destructive) {
                    showingUserMenu = false
                    Task { try? await app.client.auth.logout() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 160)
            }

            Spacer()

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        navigator.mode = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.glass)
                    .help("Settings (⌘,)")

                    Button {
                        navigator.composingNewConversation = true
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .buttonStyle(.glass)
                    .disabled(!convos.profiles.contains(where: { !$0.parentOnly }))
                    .help("New conversation")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

}
