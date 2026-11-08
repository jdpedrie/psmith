import SwiftUI
import PsmithKit

/// The Accounts pane (boards "Accounts" and "Add account"): every account
/// this Mac remembers, one account's details, and adding one, all inline.
/// Switching day to day stays in the main window's sidebar footer.
struct AccountsSettingsView: View {
    @Environment(AccountManager.self) private var accounts
    @Environment(Navigator.self) private var navigator

    /// nil while adding an account.
    @State private var selectedID: UUID?
    @State private var adding = false
    @State private var health: [UUID: Health] = [:]

    enum Health: Equatable { case reachable(ms: Int, version: String), unreachable }

    var body: some View {
        SKSplit {
            SKListHeader(text: "On this Mac")
            ForEach(accounts.accounts) { account in
                SKListItem(
                    title: account.username,
                    subtitle: subtitle(account),
                    selected: !adding && selectedID == account.id,
                    action: { adding = false; selectedID = account.id },
                    lead: { AccountAvatar(account: account) },
                    trail: { statusDot(account) }
                )
            }
            SKAddItem(title: "Add account…", selected: adding) { adding = true }
        } detail: {
            if adding {
                AddAccountDetail(onDone: { id in
                    adding = false
                    if let id { selectedID = id }
                })
            } else if let account = accounts.accounts.first(where: { $0.id == (selectedID ?? accounts.activeAccountID) }) {
                AccountDetail(account: account, health: health[account.id])
                    .id(account.id)
            }
        }
        .task(id: accounts.accounts.map(\.id)) { await checkServers() }
        .onAppear { if selectedID == nil { selectedID = accounts.activeAccountID } }
        .onChange(of: navigator.settingsAddingAccount, initial: true) { _, on in
            if on {
                adding = true
                navigator.settingsAddingAccount = false
            }
        }
    }

    private func subtitle(_ account: Account) -> String {
        let host = account.host.host ?? account.host.absoluteString
        let port = account.host.port.map { ":\($0)" } ?? ""
        return account.id == accounts.activeAccountID ? "\(host)\(port) · active" : "\(host)\(port)"
    }

    @ViewBuilder
    private func statusDot(_ account: Account) -> some View {
        switch health[account.id] {
        case .reachable: SKDot(color: SK.green)
        case .unreachable: SKDot(color: SK.orange)
        case nil: EmptyView()
        }
    }

    /// One unauthenticated probe per server: the dot in the list, and
    /// the Status row's round trip.
    private func checkServers() async {
        await withTaskGroup(of: (UUID, Health).self) { group in
            for account in accounts.accounts {
                group.addTask {
                    let start = Date()
                    let result = await probePsmithServer(url: account.host)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    if case .ok(_, let version) = result {
                        return (account.id, .reachable(ms: ms, version: version.isEmpty ? "dev" : version))
                    }
                    return (account.id, .unreachable)
                }
            }
            for await (id, h) in group { health[id] = h }
        }
    }
}

struct AccountAvatar: View {
    let account: Account

    private static let colors: [Color] = [Color(hex: 0x2C65A0), Color(hex: 0x7A3A8C), Color(hex: 0x3EA36E), Color(hex: 0xB04A22), Color(hex: 0x1C6F8E)]

    var body: some View {
        // Stable per account: the id, not the list position.
        let index = Int(account.id.uuid.0) % Self.colors.count
        Text(String(account.username.prefix(1)).uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Self.colors[index]))
    }
}

private struct AccountDetail: View {
    let account: Account
    let health: AccountsSettingsView.Health?
    @Environment(AccountManager.self) private var accounts
    @State private var name = ""
    @State private var confirmingRemove = false
    @State private var signingIn = false

    private var signedIn: Bool { accounts.isSignedIn(account.id) }
    private var isActive: Bool { accounts.activeAccountID == account.id }
    private var host: String {
        (account.host.host ?? account.host.absoluteString) + (account.host.port.map { ":\($0)" } ?? "")
    }

    var body: some View {
        if signingIn {
            AddAccountDetail(host: account.host, username: account.username, onDone: { _ in signingIn = false })
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKPageHead(title: "\(account.username) on \(host)", subtitle: headline) {
                if !signedIn {
                    Button("Sign In…") { signingIn = true }.skButton(.primary)
                } else if !isActive {
                    Button("Switch to This Account") { accounts.switchAccount(to: account.id) }.skButton(.primary)
                }
            }
            SKGroup("Account") {
                SKRow("Name in menus", detail: "Shown in the account menu and window title. This Mac only.") {
                    SKTextField(label: "Name in menus", text: $name, placeholder: "\(account.username) · \(account.host.host ?? "")", width: 220)
                        .onSubmit { accounts.setDisplayLabel(name, for: account.id) }
                        .onDisappear { accounts.setDisplayLabel(name, for: account.id) }
                }
                SKRow("Server") { Text(account.host.absoluteString).sk(13, SK.secondary, mono: true) }
                SKRow("Status") {
                    switch health {
                    case .reachable(let ms, _):
                        HStack(spacing: 6) {
                            SKDot(color: SK.green)
                            Text("Reachable").sk(13)
                            Text("· \(ms) ms").sk(12.5, SK.tertiary)
                        }
                    case .unreachable:
                        HStack(spacing: 6) {
                            SKDot(color: SK.orange)
                            Text("Unreachable").sk(13)
                        }
                    case nil:
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            SKGroup {
                if signedIn {
                    SKRow("Sign out", detail: "Keeps the account here so you can sign back in.") {
                        Button("Sign Out") { Task { await accounts.signOut(id: account.id) } }.skButton()
                    }
                }
                if confirmingRemove {
                    SKRawRow(vertical: 8, horizontal: 8) {
                        SKConfirmStrip(
                            question: "Remove \(account.username) on \(host) from this Mac?",
                            detail: "Forgets the account and its sign-in here. Conversations on the server stay.",
                            confirmLabel: "Remove Account",
                            onCancel: { confirmingRemove = false },
                            onConfirm: { Task { await accounts.removeAccount(id: account.id) } }
                        )
                    }
                } else {
                    SKRow("Remove from this Mac", detail: "Forgets the account and its sign-in here.") {
                        Button("Remove…") { confirmingRemove = true }.skButton(.destructive)
                    }
                }
            }
        }
        .onAppear { name = account.displayLabel ?? "" }
    }

    private var headline: String {
        guard signedIn else { return "Signed out" }
        if case .reachable(_, let version) = health { return "Signed in · server \(version)" }
        return "Signed in"
    }
}

/// Adding an account, or signing back in to one: check the server, then
/// a username and password. Nothing is saved until sign-in succeeds.
struct AddAccountDetail: View {
    var host: URL?
    var username: String = ""
    let onDone: (UUID?) -> Void

    @Environment(AccountManager.self) private var accounts
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var server: ServerCheck = .idle
    @State private var signingIn = false
    @State private var error: String?

    enum ServerCheck: Equatable { case idle, checking, found(version: String, url: URL), problem(String) }

    private var foundURL: URL? {
        if case .found(_, let url) = server { return url }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKPageHead(
                host == nil ? "Add an account" : "Sign in again",
                subtitle: host == nil
                    ? "Sign in to another Psmith server. You switch between accounts from the sidebar footer in the main window."
                    : "Your sign-in on this server ended. Nothing else changed."
            )
            if let error {
                SKBanner(.error, "Couldn't sign in", message: error)
            }
            SKGroup("Server") {
                SKRow("Address") {
                    SKTextField(label: "Address", text: $address, placeholder: "https://psmith.example.com", width: 280)
                        .onSubmit { Task { await check() } }
                        .disabled(host != nil)
                }
                if server != .idle {
                    SKRawRow {
                        switch server {
                        case .checking:
                            HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("Checking…").sk(12.5, SK.secondary) }
                        case .found(let version, _):
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(SK.green)
                                Text("Psmith \(version) found. Sign in with a password.").sk(12.5, SK.green)
                            }
                        case .problem(let message):
                            HStack(spacing: 8) {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(SK.red)
                                Text(message).sk(12.5, SK.red)
                            }
                        case .idle:
                            EmptyView()
                        }
                    }
                }
            }
            SKGroup("Sign in") {
                SKRow("Username") {
                    SKTextField(label: "Username", text: $user, width: 280)
                }
                SKRow("Password") {
                    SKTextField(label: "Password", text: $password, width: 280, secure: true).onSubmit { Task { await signIn() } }
                }
            } footer: {
                Text("Psmith keeps a sign-in token for this server in your keychain, never the password.")
            }
            .disabled(foundURL == nil)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { onDone(nil) }.skButton().keyboardShortcut(.cancelAction)
                Button(signingIn ? "Signing In…" : "Sign In") { Task { await signIn() } }
                    .skButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(foundURL == nil || user.isEmpty || password.isEmpty || signingIn)
            }
        }
        .onAppear {
            user = username
            if let host {
                address = host.absoluteString
                Task { await check() }
            }
        }
        .onChange(of: address) { _, _ in
            if host == nil { server = .idle }
        }
    }

    private func check() async {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else {
            server = .problem("That isn't a web address.")
            return
        }
        server = .checking
        switch await probePsmithServer(url: url) {
        case .ok(_, let version): server = .found(version: version.isEmpty ? "dev" : version, url: url)
        case .wrongServer: server = .problem("Something answered there, but it isn't Psmith.")
        case .unreachable(let detail): server = .problem("Couldn't reach it: \(detail)")
        }
    }

    private func signIn() async {
        guard let url = foundURL else { return }
        signingIn = true
        defer { signingIn = false }
        do {
            let account = try await accounts.addAccount(host: url, username: user, password: password)
            onDone(account.id)
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}
