import SwiftUI
import PsmithKit

struct HomeView: View {
    let user: PsmithUser
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager
    @Environment(ConversationsModel.self) private var convos
    @Environment(Navigator.self) private var navigator
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showingUserMenu: Bool = false
    @State private var showingAddAccount: Bool = false
    @State private var accountToRemove: Account? = nil
    /// Sidebar archive-browsing mode. Lives here (not in the list view)
    /// because the detail pane must resolve selections against the
    /// archive list while it's active.
    @State private var showingArchived: Bool = false

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
                ConversationListView(showingArchived: $showingArchived)
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
                      let conversation = convos.conversations.first(where: { $0.id == id })
                          ?? convos.archivedConversations.first(where: { $0.id == id }) {
                ConversationView(conversation: conversation, profiles: app.profiles)
                    .id(id)
            } else {
                WelcomeView()
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
            mcpServersModel: app.mcpServers,
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
                        .scaledFont(.callout)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingUserMenu, arrowEdge: .top) {
                accountSwitcherPopover
            }
            .sheet(isPresented: $showingAddAccount) {
                // Sheet-presented LoginView (no preselected host)
                // walks server probe + credentials and routes through
                // AccountManager.addAccount. AccountManager dedupes on
                // (host, username), so re-entering an existing
                // account here reactivates rather than duplicating.
                VStack(spacing: 0) {
                    HStack {
                        Text("Add account")
                            .scaledFont(.title3, weight: .semibold)
                        Spacer()
                        Button("Cancel") { showingAddAccount = false }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    LoginView()
                        .environment(accountManager)
                }
                .frame(minWidth: 460, minHeight: 420)
            }
            .confirmationDialog(
                accountToRemove.map { "Remove \($0.resolvedDisplayLabel)?" } ?? "Remove account?",
                isPresented: Binding(
                    get: { accountToRemove != nil },
                    set: { if !$0 { accountToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove account", role: .destructive) {
                    if let id = accountToRemove?.id {
                        Task { await accountManager.removeAccount(id: id) }
                    }
                    accountToRemove = nil
                }
                Button("Cancel", role: .cancel) { accountToRemove = nil }
            } message: {
                Text("Removes the saved credentials and forgets this account locally. Conversations on the server are unchanged.")
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
                        // With a default profile set, plain click starts a
                        // chat with it immediately; ⌥-click (or no default)
                        // opens the full compose pane with profile/model/
                        // settings choices. Mirrors iOS's tap vs long-press.
                        let optionHeld = NSEvent.modifierFlags.contains(.option)
                        if !optionHeld,
                           let def = convos.profiles.first(where: { $0.isDefault && !$0.parentOnly }) {
                            Task {
                                if let c = await convos.newConversation(profileID: def.id, title: nil, settings: nil) {
                                    convos.selectedID = c.id
                                }
                            }
                        } else {
                            navigator.composingNewConversation = true
                        }
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .buttonStyle(.glass)
                    .disabled(!convos.profiles.contains(where: { !$0.parentOnly }))
                    .help(newConversationHelp)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var newConversationHelp: String {
        if let def = convos.profiles.first(where: { $0.isDefault && !$0.parentOnly }) {
            return "New conversation with \(def.name) — ⌥-click to choose"
        }
        return "New conversation"
    }

    // MARK: - Account switcher popover

    /// Popover content for the user chip. Lists every account
    /// with a check next to the active one, an "Add account…"
    /// entry that opens LoginView in a sheet, and per-row
    /// remove + sign-out actions on a hover-revealed trailing
    /// menu.
    @ViewBuilder
    private var accountSwitcherPopover: some View {
        VStack(spacing: 0) {
            // Account list. Stable sort comes from AccountStore.
            ForEach(accountManager.accounts) { account in
                AccountSwitcherRow(
                    account: account,
                    isActive: account.id == accountManager.activeAccountID,
                    onSelect: {
                        showingUserMenu = false
                        accountManager.switchAccount(to: account.id)
                    },
                    onRemove: {
                        showingUserMenu = false
                        accountToRemove = account
                    }
                )
            }
            Divider().padding(.vertical, 4)
            Button {
                showingUserMenu = false
                showingAddAccount = true
            } label: {
                Label("Add account…", systemImage: "plus.circle")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Divider().padding(.vertical, 4)
            Button(role: .destructive) {
                showingUserMenu = false
                Task { await accountManager.signOutActive() }
            } label: {
                Label("Sign out of \(user.username)", systemImage: "rectangle.portrait.and.arrow.right")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 260)
    }
}

/// Single row in the account switcher popover. Click anywhere
/// activates this account; hover reveals a trailing minus-circle
/// to remove it (with a confirmation dialog at the call site).
private struct AccountSwitcherRow: View {
    let account: Account
    let isActive: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 1) {
                Text(account.username)
                    .scaledFont(.callout)
                Text(account.host.host ?? account.host.absoluteString)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if hovering, !isActive {
                // Removing the active account would tear down the
                // pane the user is interacting with — only expose
                // the affordance on inactive rows.
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove this account")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovering = $0 }
        .onTapGesture { onSelect() }
    }
}

