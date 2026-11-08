import SwiftUI
import PsmithKit
import PsmithUI

/// The main window once signed in: the conversation list, then the
/// reading pane (which owns the inspector). Drawn to the main-window
/// boards: each column draws its own 52pt header, the traffic lights sit
/// in the list's, and nothing is a system split view, so every column
/// measures what the board says.
struct HomeView: View {
    let user: PsmithUser
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    /// Sidebar archive-browsing mode. Lives here (not in the list view)
    /// because the detail pane must resolve selections against the
    /// archive list while it's active.
    @State private var showingArchived = false
    @AppStorage("mainListWidth") private var listWidth: Double = MK.listWidth

    var body: some View {
        HStack(spacing: 0) {
            if navigator.listShown {
                MainListColumn(user: user, showingArchived: $showingArchived, width: $listWidth)
                    .frame(width: CGFloat(listWidth))
                    .transition(.move(edge: .leading))
            }
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .background(theme.chrome.ignoresSafeArea())
        .onAppear { navigator.openSettingsWindow = { openSettings() } }
        .task {
            await convos.refresh()
            await app.providers.load()
            await app.profiles.load()
        }
        // Picking another conversation abandons the draft; the draft's own
        // creation selects its new id, which keeps it.
        .onChange(of: convos.selectedID, initial: false) { _, newID in
            if let newID, let draft = navigator.draft, draft.createdID != newID {
                navigator.draft = nil
            }
        }
        // A fresh draft takes the reading pane from whatever was open.
        .onChange(of: navigator.draft?.key) { _, key in
            if key != nil, navigator.draft?.createdID == nil {
                convos.selectedID = nil
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let draft = navigator.draft, convos.selectedID == nil || convos.selectedID == draft.createdID {
            ConversationView(newConversation: draft.key) { created in
                navigator.draft?.createdID = created.id
            }
            .id(draft.key)
        } else if let id = convos.selectedID,
                  let conversation = convos.conversations.first(where: { $0.id == id })
                      ?? convos.archivedConversations.first(where: { $0.id == id }) {
            ConversationView(conversation: conversation)
                .id(id)
        } else {
            WelcomeView()
        }
    }
}

/// The list column (board AppConversation): its header with the traffic
/// lights and the hide and new buttons, the list, the account row, and a
/// resizable right edge.
struct MainListColumn: View {
    let user: PsmithUser
    @Binding var showingArchived: Bool
    @Binding var width: Double
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(spacing: 0) {
            MKHeaderBand(divider: false, ground: .well) {
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    MKIconButton(systemImage: "sidebar.leading", label: "Hide the conversation list (⌃⌘S)") {
                        withAnimation(.easeInOut(duration: 0.25)) { navigator.listShown = false }
                    }
                    MKIconButton(systemImage: "square.and.pencil", label: "New conversation (⌘N)") {
                        navigator.startNewConversation()
                    }
                }
            }
            .padding(.horizontal, 10)
            ConversationListView(showingArchived: $showingArchived)
                .frame(maxHeight: .infinity)
            AccountFooter(user: user)
        }
        .background(MKWell())
        .overlay(alignment: .trailing) {
            Rectangle().fill(SK.line).frame(width: 1)
                .overlay(ColumnResizeHandle(width: $width, range: MK.listRange))
        }
    }
}

/// The list's bottom row: who you are, on which server, whether it's
/// reachable. A native menu holds the rest; accounts are managed in
/// Settings ▸ Accounts rather than in sheets from here.
struct AccountFooter: View {
    let user: PsmithUser
    @Environment(AppModel.self) private var app
    @Environment(AccountManager.self) private var accountManager
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Menu {
            Section("Accounts") {
                ForEach(accountManager.accounts) { account in
                    Button {
                        accountManager.switchAccount(to: account.id)
                    } label: {
                        let label = "\(account.username) · \(account.host.host ?? account.host.absoluteString)"
                        if account.id == accountManager.activeAccountID {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            }
            Divider()
            Button("Add Account…") { navigator.showAddAccount() }
            Button("Manage Accounts…") { navigator.showSettings(.accounts) }
            Divider()
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Sign Out of \(user.username)") {
                Task { await accountManager.signOutActive() }
            }
        } label: {
            HStack(spacing: 8) {
                MKAvatar(name: user.username)
                VStack(alignment: .leading, spacing: 0) {
                    Text(user.username).sk(13).lineLimit(1).frame(height: 15.6)
                    Text(app.serverURL.host ?? app.serverURL.absoluteString).sk(11, SK.secondary).lineLimit(1).frame(height: 13.2)
                }
                Spacer(minLength: 4)
                let offline = app.connectivity.state == .offline
                SKDot(color: offline ? SK.orange : SK.green)
                    .help(offline ? "Server unreachable" : "Connected")
            }
            .padding(.horizontal, 14)
            .frame(height: 47)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .overlay(alignment: .top) { Rectangle().fill(SK.line).frame(height: 1) }
        .padding(.top, 1)
    }
}

/// Drag a column's edge to resize it, with the resize cursor over it.
struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<CGFloat>
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        let base = start ?? width
                        if start == nil { start = width }
                        width = Double(min(max(CGFloat(base) + g.translation.width, range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

/// The conversation list's ground. Kept for the list's snapshots.
struct SidebarWell: View {
    var body: some View { MKWell() }
}
