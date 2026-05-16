import SwiftUI
import ReeveKit

struct HomeView: View {
    let user: ReeveUser
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager
    @Environment(ConversationsModel.self) private var convos
    @Environment(Navigator.self) private var navigator
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showingUserMenu: Bool = false
    @State private var showingAddAccount: Bool = false
    @State private var accountToRemove: Account? = nil

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
                accountSwitcherPopover
            }
            .sheet(isPresented: $showingAddAccount) {
                AddAccountSheet(isPresented: $showingAddAccount)
                    .environment(accountManager)
                    .frame(minWidth: 420, minHeight: 360)
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

    // MARK: - Account switcher popover

    /// Popover content for the user chip. Lists every account
    /// with a check next to the active one, an "Add account…"
    /// entry that opens the AddAccountSheet, and per-row
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
                    .font(.callout)
                Text(account.host.host ?? account.host.absoluteString)
                    .font(.caption2)
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

/// Modal sheet hosting the same two-phase form as
/// AccountSetupView. Used when the user already has at least
/// one account and wants to add another. Dismisses on success.
struct AddAccountSheet: View {
    @Binding var isPresented: Bool
    @Environment(AccountManager.self) private var accountManager
    @State private var phase: Phase = .server
    @State private var hostText: String = ""
    @State private var pendingHost: URL?
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var displayLabel: String = ""
    @State private var inFlight = false
    @State private var errorMessage: String?

    enum Phase: Hashable { case server, credentials }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Add an account")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            switch phase {
            case .server: serverForm
            case .credentials: credentialsForm
            }
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder
    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server URL")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("https://reeve.example.com", text: $hostText)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            HStack {
                Spacer()
                Button("Continue") {
                    guard let url = URL(string: hostText.trimmingCharacters(in: .whitespaces)) else {
                        errorMessage = "Not a valid URL"
                        return
                    }
                    pendingHost = url
                    errorMessage = nil
                    phase = .credentials
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(hostText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = pendingHost {
                Text("Sign in to \(host.absoluteString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            TextField("Display label (optional)", text: $displayLabel)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Back") { phase = .server }
                    .buttonStyle(.borderless)
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    if inFlight {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Signing in…")
                        }
                    } else {
                        Text("Add").bold()
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(inFlight || username.isEmpty || password.isEmpty)
            }
        }
    }

    private func submit() async {
        guard let host = pendingHost else { return }
        inFlight = true
        errorMessage = nil
        defer { inFlight = false }
        do {
            try await accountManager.addAccount(
                host: host,
                username: username,
                password: password,
                displayLabel: displayLabel.isEmpty ? nil : displayLabel
            )
            isPresented = false
        } catch {
            errorMessage = ReeveError.display(error)
        }
    }
}
