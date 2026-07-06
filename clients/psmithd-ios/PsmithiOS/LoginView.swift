import SwiftUI
import PsmithKit

/// Two-phase sign-in form, used in three contexts that look identical
/// from the user's POV:
///
///   1. **Cold start** — no account exists. Shown by `iOSAppShell` when
///      `accountManager.active == nil`. No `initialHost` → starts on
///      phase 1 (server URL entry).
///   2. **Add account** — presented as a sheet from the chats toolbar
///      account menu. Same blank start.
///   3. **Sign back in** — the active account signed itself out.
///      `RootView` renders this with `initialHost` + `initialUsername`
///      seeded from the active account, skipping phase 1.
///
/// All three route through `AccountManager.addAccount(...)` — the
/// manager dedupes on `(host, username)`, so a "sign back in" call
/// re-authenticates the existing AppModel instead of duplicating the
/// row. Previously each context had its own form; the duplication
/// drifted (different field labels, missing affordances).
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
        // Skip server-URL entry whenever the caller already knows the
        // host (sign-back-in path). Pre-fill the username so the user
        // just types their password.
        _phase = State(initialValue: initialHost != nil ? .credentials : .server)
        _pendingHost = State(initialValue: initialHost)
        _initialUsernameDraft = State(initialValue: initialUsername ?? "")
    }

    var body: some View {
        // No wrapping NavigationStack — callers add navigation chrome
        // when they need it (the sheet-presented "add account" path
        // wraps for the Cancel toolbar; cold start + sign-back-in
        // present LoginView bare).
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Group {
                    switch phase {
                    case .server:
                        ServerURLEntry(initialText: pendingHost?.absoluteString) { newURL in
                            // Persist as the current process-wide
                            // server so the legacy ServerURLStore
                            // stays in sync with whatever the user
                            // just validated. AccountManager keeps
                            // its own per-account host record so
                            // this is just a hint, not authoritative.
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
                                    // Dismiss closes a sheet
                                    // presentation; no-op when
                                    // LoginView is the root view
                                    // (cold start / signed-out
                                    // active). The active-account
                                    // swap re-renders the shell
                                    // either way.
                                    dismiss()
                                }
                            )
                        }
                    }
                }

                let others = accountManager.otherSignedInAccounts
                if !others.isEmpty {
                    otherAccountsSection(others)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    /// Tap-to-switch list of other signed-in accounts. Shown beneath the
    /// sign-in form so the user has a path back to a working session
    /// after signing out of the active account — without this they're
    /// stuck re-entering credentials.
    @ViewBuilder
    private func otherAccountsSection(_ others: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            .padding(.vertical, 4)

            ForEach(others) { account in
                Button {
                    accountManager.switchAccount(to: account.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 30, weight: .light))
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
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
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://psmith.example.com", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await test() } }
            }

            statusBanner

            HStack(spacing: 10) {
                Button {
                    Task { await test() }
                } label: {
                    Text("Test connection")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(inFlight || urlText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    if let url = parsedURL { onValidated(url) }
                } label: {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isReady)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 32)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect to psmithd")
                .font(.title2.weight(.semibold))
            Text("Enter the URL where your Psmith server is running. We'll probe it to confirm before asking for your credentials.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Probing…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            switch status {
            case .idle:
                EmptyView()
            case .ok(let version):
                banner(
                    tint: .green,
                    icon: "checkmark.circle.fill",
                    text: version.isEmpty
                        ? "Reachable — psmithd answered."
                        : "Reachable — psmithd \(version)."
                )
            case .wrong(let detail):
                banner(
                    tint: .orange,
                    icon: "exclamationmark.triangle.fill",
                    text: "Server answered but isn't a Psmith server: \(detail)"
                )
            case .unreachable(let detail):
                banner(
                    tint: .red,
                    icon: "xmark.octagon.fill",
                    text: "Couldn't reach this URL: \(detail)"
                )
            }
        }
    }

    private func banner(tint: Color, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
    /// Tappable "Change" link beside the server chip. Hidden when the
    /// caller doesn't want the user to alter the host — typically the
    /// sign-back-in flow where the host is fixed to the active account.
    var onChangeServer: (() -> Void)? = nil
    /// Receives (username, password). Throws on failure; the view
    /// renders the resulting message inline.
    let onSubmit: (String, String) async throws -> Void

    @State private var username: String
    @State private var password = ""
    @State private var inFlight = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    enum Field: Hashable { case username, password }

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
        VStack(alignment: .leading, spacing: 18) {
            header

            serverChip

            VStack(alignment: .leading, spacing: 10) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await submit() }
            } label: {
                if inFlight {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else {
                    Text("Sign in")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(username.isEmpty || password.isEmpty || inFlight)

            Spacer(minLength: 0)
        }
        .padding(.top, 32)
        .onAppear {
            // Skip to the password field when the username's already
            // filled in (the sign-back-in flow has the row's
            // remembered username pre-populated).
            focused = username.isEmpty ? .username : .password
        }
    }

    private var header: some View {
        Text("Sign in")
            .font(.title2.weight(.semibold))
    }

    private var serverChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            Text(serverURL.absoluteString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let onChangeServer {
                Button("Change", action: onChangeServer)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func submit() async {
        guard !inFlight else { return }
        inFlight = true
        errorMessage = nil
        do {
            try await onSubmit(username, password)
            Haptics.notify(.success)
        } catch {
            errorMessage = PsmithError.display(error)
            Haptics.notify(.error)
        }
        inFlight = false
    }
}
