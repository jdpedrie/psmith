import SwiftUI
import SpaltKit

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
        VStack(spacing: 24) {
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
                            try await accountManager.addAccount(
                                host: host,
                                username: username,
                                password: password
                            )
                            dismiss()
                        }
                    )
                }
            }

            let others = accountManager.otherSignedInAccounts
            if !others.isEmpty {
                otherAccountsSection(others)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Tap-to-switch list of other signed-in accounts. Lives beneath the
    /// form so the sign-back-in flow has a path back to a working
    /// session on a different account.
    @ViewBuilder
    private func otherAccountsSection(_ others: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(height: 1)
                Text("OR CONTINUE AS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle()
                    .fill(.tertiary)
                    .frame(height: 1)
            }

            ForEach(others) { account in
                Button {
                    accountManager.switchAccount(to: account.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.resolvedDisplayLabel)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(account.host.host ?? account.host.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
            }
        }
        .frame(maxWidth: 380)
    }
}

// MARK: - Phase 1: server URL entry

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
        VStack(spacing: 16) {
            Text("Connect to spaltd")
                .font(.title2)
            Text("Enter the URL where your Spalt server is running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                TextField("https://spalt.example.com", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onSubmit { Task { await test() } }
            }
            .frame(maxWidth: 380)

            statusBanner

            HStack {
                Button("Test connection") {
                    Task { await test() }
                }
                .buttonStyle(.glass)
                .disabled(inFlight || urlText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Continue") {
                    if let url = parsedURL { onValidated(url) }
                }
                .buttonStyle(.glassProminent)
                .disabled(!isReady)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 380)
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
    private var statusBanner: some View {
        if inFlight {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Probing…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            switch status {
            case .idle:
                EmptyView()
            case .ok(let version):
                Label(version.isEmpty ? "Reachable — spaltd answered." : "Reachable — spaltd \(version).",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .wrong(let detail):
                Label("Server responded but isn't a Spalt server: \(detail)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 380)
            case .unreachable(let detail):
                Label("Couldn't reach this URL: \(detail)",
                      systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 380)
            }
        }
    }

    private func test() async {
        guard let url = parsedURL else {
            status = .unreachable("not a valid URL")
            return
        }
        inFlight = true
        status = .idle
        let result = await probeSpaltServer(url: url)
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
        VStack(spacing: 16) {
            Text("Sign in to Spalt")
                .font(.title2)

            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text(serverURL.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let onChangeServer {
                    Button("Change") { onChangeServer() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .disableAutocorrection(true)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit { Task { await submit() } }
            }
            .frame(maxWidth: 320)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button {
                Task { await submit() }
            } label: {
                if inFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign in").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glassProminent)
            .frame(maxWidth: 320)
            .disabled(username.isEmpty || password.isEmpty || inFlight)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func submit() async {
        guard !inFlight else { return }
        inFlight = true
        errorMessage = nil
        do {
            try await onSubmit(username, password)
        } catch {
            errorMessage = SpaltError.display(error)
        }
        inFlight = false
    }
}
