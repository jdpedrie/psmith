import SwiftUI
import PsmithKit

/// Two-phase Mac sign-in form, used in three contexts that look the
/// same to the user:
///
///   1. **Cold start** — no account yet. `AppShell` renders this when
///      `accountManager.active == nil`. No `initialHost` → start on
///      phase 1 (server URL entry).
///   2. **Add account** — presented as a sheet from `HomeView`'s
///      account switcher popover. Same blank start.
///   3. **Sign back in** — the active account signed itself out.
///      `RootView` renders LoginView with `initialHost` + `initialUsername`
///      seeded from the active account, skipping phase 1.
///
/// All three route through `AccountManager.addAccount(...)` — the
/// manager dedupes on `(host, username)`, so re-auth re-activates the
/// existing AppModel instead of duplicating the account row.
/// Signing in (boards AppLoginServer, AppLoginCredentials): the server
/// first, probed before anything is sent, then the credentials. Shown on
/// a cold start and when the active account is signed out; adding another
/// account happens in Settings ▸ Accounts.
struct LoginView: View {
    var initialHost: URL? = nil
    var initialUsername: String? = nil

    @Environment(AccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase
    @State private var pendingHost: URL?
    @State private var initialUsernameDraft: String
    @State private var urlStore = ServerURLStore.shared

    enum Phase: Hashable { case server, credentials }

    init(initialHost: URL? = nil, initialUsername: String? = nil) {
        self.initialHost = initialHost
        self.initialUsername = initialUsername
        _phase = State(initialValue: initialHost != nil ? .credentials : .server)
        _pendingHost = State(initialValue: initialHost)
        _initialUsernameDraft = State(initialValue: initialUsername ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .server:
                    ServerURLEntry(initialText: pendingHost?.absoluteString) { newURL in
                        urlStore.current = newURL
                        pendingHost = newURL
                        phase = .credentials
                    }
                case .credentials:
                    if let host = pendingHost {
                        CredentialsEntry(
                            serverURL: host,
                            initialUsername: initialUsernameDraft,
                            onChangeServer: initialHost == nil ? { phase = .server } : nil,
                            onSubmit: { username, password in
                                try await accountManager.addAccount(host: host, username: username, password: password)
                                dismiss()
                            }
                        )
                    }
                }
                let others = accountManager.otherSignedInAccounts
                if !others.isEmpty, phase == .server {
                    SKGroup("Or continue as") {
                        ForEach(others) { account in
                            Button {
                                accountManager.switchAccount(to: account.id)
                                dismiss()
                            } label: {
                                SKRow(account.resolvedDisplayLabel) {
                                    HStack(spacing: 8) {
                                        Text(account.host.host ?? account.host.absoluteString).sk(12, SK.tertiary).lineLimit(1)
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(SK.tertiary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 22)
                }
            }
            .frame(width: 420)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { h, _ in h }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectHidden(true, for: .top)
        .ignoresSafeArea()
    }
}

/// A screen's centered title and one line under it.
struct SoloHead: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 5) {
            Text(title).sk(20, weight: .bold)
            Text(subtitle).sk(12.5, SK.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 22)
    }
}

private struct ServerURLEntry: View {
    var initialText: String?
    let onValidated: (URL) -> Void
    @State private var urlText: String
    @State private var inFlight = false
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case ok(version: String)
        case wrong(String)
        case unreachable(String)
    }

    init(initialText: String? = nil, onValidated: @escaping (URL) -> Void) {
        self.initialText = initialText
        self.onValidated = onValidated
        _urlText = State(initialValue: initialText ?? ServerURLStore.shared.current.absoluteString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SoloHead(title: "Connect to a Psmith server",
                     subtitle: "Psmith keeps your providers, profiles and conversations on a server you run.")
            SKGroup("Server") {
                SKRow("Address") {
                    SKTextField(label: "Address", text: $urlText, placeholder: "https://psmith.example.com", width: 230)
                        .onSubmit { Task { await test() } }
                }
            } footer: {
                statusLine
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Test Connection") { Task { await test() } }
                    .skButton()
                    .disabled(inFlight || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Continue") {
                    if let url = parsedURL { onValidated(url) }
                }
                .skButton(.primary)
                .disabled(!isReady)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var parsedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private var isReady: Bool {
        if inFlight { return false }
        if case .ok = status { return true }
        return false
    }

    @ViewBuilder
    private var statusLine: some View {
        if inFlight {
            HStack(spacing: 6) { MKSpinner(size: 11); Text("Checking…").sk(12, SK.secondary) }
        } else {
            switch status {
            case .idle:
                EmptyView()
            case .ok(let version):
                statusLabel("checkmark", version.isEmpty ? "Reachable. psmithd answered." : "Reachable. psmithd \(version) answered.", SK.green)
            case .wrong(let detail):
                statusLabel("exclamationmark.triangle", "That server answered, but it isn’t Psmith: \(detail)", SK.orange)
            case .unreachable(let detail):
                statusLabel("exclamationmark.triangle", "Couldn’t reach this address: \(detail)", SK.red)
            }
        }
    }

    private func statusLabel(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
            Text(text).sk(12, color).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    private func test() async {
        guard let url = parsedURL else {
            status = .unreachable("not a valid URL")
            return
        }
        inFlight = true
        status = .idle
        let result = await probePsmithServer(url: url)
        inFlight = false
        switch result {
        case .ok(_, let version):
            status = .ok(version: version)
        case .wrongServer(let detail):
            status = .wrong(detail)
        case .unreachable(let detail):
            status = .unreachable(detail)
        }
    }
}

// MARK: - Phase 2: credentials

private struct CredentialsEntry: View {
    let serverURL: URL
    var initialUsername: String = ""
    /// "Change" link beside the server chip. Hidden in sign-back-in
    /// (the host is fixed to the active account's host).
    var onChangeServer: (() -> Void)? = nil
    /// Receives (username, password). Throws on failure; the view
    /// renders the error inline. Wires the action back to whatever
    /// auth path the caller wants (typically AccountManager.addAccount).
    let onSubmit: (String, String) async throws -> Void

    @State private var username: String
    @State private var password = ""
    @State private var inFlight = false
    @State private var errorMessage: String?

    init(
        serverURL: URL,
        initialUsername: String = "",
        onChangeServer: (() -> Void)? = nil,
        onSubmit: @escaping (String, String) async throws -> Void
    ) {
        self.serverURL = serverURL
        self.initialUsername = initialUsername
        self.onChangeServer = onChangeServer
        self.onSubmit = onSubmit
        _username = State(initialValue: initialUsername)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SoloHead(title: "Sign in", subtitle: "To \(serverURL.host ?? serverURL.absoluteString)")
            SKGroup {
                SKRow("Server") {
                    HStack(spacing: 6) {
                        Text(serverURL.host ?? serverURL.absoluteString).sk(13, SK.secondary).lineLimit(1).truncationMode(.middle)
                        if let onChangeServer {
                            Button("Change", action: onChangeServer).skButton(.plain)
                        }
                    }
                }
                SKRow("Username") {
                    SKTextField(label: "Username", text: $username, width: 230)
                        .textContentType(.username)
                }
                SKRow("Password") {
                    SKTextField(label: "Password", text: $password, width: 230, secure: true)
                        .textContentType(.password)
                        .onSubmit { Task { await submit() } }
                }
            }
            if let errorMessage {
                Text(errorMessage).sk(12, SK.red).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.top, -12)
                    .padding(.bottom, 14)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    Task { await submit() }
                } label: {
                    Text(inFlight ? "Signing In…" : "Sign In")
                }
                .skButton(.primary)
                .disabled(username.isEmpty || password.isEmpty || inFlight)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func submit() async {
        guard !inFlight else { return }
        inFlight = true
        errorMessage = nil
        do {
            try await onSubmit(username, password)
        } catch {
            errorMessage = PsmithError.display(error)
        }
        inFlight = false
    }
}
