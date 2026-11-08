import SwiftUI
import PsmithKit
import PsmithUI

/// Sign in, in two steps (boards SignInServer, SignInCredentials): the
/// server URL, tested before anything else, then username and password.
/// Three entrances look the same:
///
///   1. Cold start, no account: the app's root, from the server step.
///   2. Adding an account: pushed from the avatar menu. The system bar
///      gives it a back button, and the app header gives way to a title.
///   3. Signing back in after the active account signed out: the root,
///      seeded with that account's host and username, from credentials.
///
/// All three go through `AccountManager.addAccount`, which dedupes on
/// (host, username): signing back in re-authenticates the existing account
/// rather than adding a row.
struct LoginView: View {
    @Environment(AccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @State private var phase: Phase
    @State private var pendingHost: URL?
    @State private var serverVersion: String?
    @State private var urlStore = ServerURLStore.shared
    private let initialHost: URL?
    private let initialUsername: String
    private let seed: Seed

    enum Phase: Hashable { case server, credentials }

    /// Snapshot seams: a probe result, a typed password, a sign-in error.
    struct Seed {
        var urlText: String?
        var status: ServerProbeStatus = .idle
        var password = ""
        var error: String?
        /// Opens on credentials for this host, keeping "Change".
        var credentialsHost: URL?
    }

    init(initialHost: URL? = nil, initialUsername: String? = nil, serverVersion: String? = nil, seed: Seed = Seed()) {
        self.initialHost = initialHost
        self.initialUsername = initialUsername ?? ""
        self.seed = seed
        // A known host (signing back in) skips the server step.
        let host = initialHost ?? seed.credentialsHost
        _phase = State(initialValue: host != nil ? .credentials : .server)
        _pendingHost = State(initialValue: host)
        _serverVersion = State(initialValue: serverVersion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .server:
                    ServerURLEntry(initialText: seed.urlText ?? pendingHost?.absoluteString,
                                   initialStatus: seed.status, showsAppHeader: !isPresented) { url, version in
                        // The process-wide hint follows whatever was just
                        // validated; AccountManager keeps the per-account host.
                        urlStore.current = url
                        pendingHost = url
                        serverVersion = version
                        phase = .credentials
                    }
                case .credentials:
                    if let host = pendingHost {
                        CredentialsEntry(
                            serverURL: host,
                            serverVersion: $serverVersion,
                            initialUsername: initialUsername,
                            initialPassword: seed.password,
                            initialError: seed.error,
                            onChangeServer: initialHost == nil ? { phase = .server } : nil,
                            onSubmit: { username, password in
                                try await accountManager.addAccount(host: host, username: username, password: password)
                                // Pops the pushed add-account page; a no-op at
                                // the root, where the account swap re-renders
                                // the shell anyway.
                                dismiss()
                            }
                        )
                    }
                }
                let others = accountManager.otherSignedInAccounts
                if !others.isEmpty {
                    otherAccounts(others)
                }
            }
            .padding(.horizontal, 16)
            // Pushed, the system bar holds the space above the title; its
            // scroll inset runs 10pt past the board's 103.
            .padding(.top, isPresented ? -10 : 44)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(IK.settingsGround.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The other signed-in accounts, so signing out of one never strands
    /// the user at a password prompt.
    private func otherAccounts(_ others: [Account]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle().fill(IK.wash(0.1)).frame(height: 1)
                Text("Or continue as").font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
                    .fixedSize()
                Rectangle().fill(IK.wash(0.1)).frame(height: 1)
            }
            IKGroup(separatorInset: 60) {
                ForEach(others) { account in
                    Button {
                        accountManager.switchAccount(to: account.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            IKAvatar(name: Self.name(account), size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.name(account)).font(.system(size: 16, weight: .semibold)).foregroundStyle(IK.text)
                                Text(account.host.host ?? account.host.absoluteString)
                                    .font(.system(size: 13)).foregroundStyle(IK.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            IKChevron()
                        }
                        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14))
                        .frame(minHeight: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)
        }
        .padding(.top, 34)
    }

    static func name(_ a: Account) -> String {
        if let l = a.displayLabel, !l.isEmpty { return l }
        return a.username
    }
}

/// What testing a server URL found.
enum ServerProbeStatus: Equatable {
    case idle
    case checking
    case ok(version: String)
    case wrong(String)
    case unreachable(String)
}

// MARK: - Server step

private struct ServerURLEntry: View {
    let showsAppHeader: Bool
    let onValidated: (URL, String?) -> Void
    @State private var urlText: String
    @State private var status: ServerProbeStatus
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    init(initialText: String?, initialStatus: ServerProbeStatus, showsAppHeader: Bool,
         onValidated: @escaping (URL, String?) -> Void) {
        self.showsAppHeader = showsAppHeader
        self.onValidated = onValidated
        _urlText = State(initialValue: initialText ?? ServerURLStore.shared.current.absoluteString)
        _status = State(initialValue: initialStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsAppHeader {
                appHeader
            } else {
                IKLargeTitle(text: "Add account").padding(.horizontal, -16).frame(height: 36)
                    .padding(.bottom, 16)
            }
            IKCard {
                VStack(alignment: .leading, spacing: 0) {
                    IKField(label: "Server URL", ring: ring) {
                        TextField("https://psmith.example.com", text: $urlText)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit { Task { await test() } }
                            // A result belongs to the URL it tested: editing
                            // the text has to earn Continue again.
                            .onChange(of: urlText) { _, _ in
                                if status != .checking { status = .idle }
                            }
                    }
                    statusLine.padding(.top, 8)
                }
            }
            Text("We check the server answers before asking for your username and password.")
                .font(.system(size: 13)).ikLineHeight(18, size: 13).foregroundStyle(IK.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 6, leading: 4, bottom: 0, trailing: 4))
            HStack(spacing: 10) {
                Button("Test connection") { Task { await test() } }
                    .ikWideButton(primary: false)
                    .disabled(status == .checking || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Continue") {
                    if let url = parsedURL, case .ok(let v) = status { onValidated(url, v) }
                }
                .ikWideButton()
                .disabled(!isReady)
            }
            .padding(.top, 22)
        }
    }

    private var appHeader: some View {
        VStack(spacing: 0) {
            IKAppIcon()
            Text("Psmith").font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(IK.text)
                .frame(height: 36)
                .padding(.top, 18)
            Text("Chat with your models through your own server. Tell us where it runs.")
                .font(.system(size: 15)).ikLineHeight(21, size: 15).foregroundStyle(IK.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        // Board: the icon sits 72 under the safe area, the card at 332.
        .padding(.top, 28)
        .frame(height: 229, alignment: .top)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking…").font(.system(size: 13))
            }
            .foregroundStyle(IK.secondary)
        case .ok(let version):
            IKStatusLine(systemImage: "checkmark.circle", text: Self.reachable(version), color: IK.green)
        case .wrong(let detail):
            IKStatusLine(systemImage: "exclamationmark.triangle",
                         text: "Server answered but isn't a Psmith server: \(detail)", color: IK.orange)
        case .unreachable(let detail):
            IKStatusLine(systemImage: "xmark.circle", text: "Couldn't reach this URL: \(detail)", color: IK.red)
        }
    }

    static func reachable(_ version: String) -> String {
        version.isEmpty ? "Reachable" : "Reachable · psmithd \(version)"
    }

    private var ring: Color? {
        switch status {
        case .unreachable: IK.red.opacity(0.7)
        case .wrong: IK.orange.opacity(0.7)
        default: focused ? theme.accent : nil
        }
    }

    private var parsedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    private var isReady: Bool {
        if case .ok = status { return true }
        return false
    }

    private func test() async {
        guard let url = parsedURL else {
            status = .unreachable("not a valid URL.")
            return
        }
        status = .checking
        status = ServerProbeStatus(await probePsmithServer(url: url))
        if case .ok = status { Haptics.notify(.success) } else { Haptics.notify(.error) }
    }
}

extension ServerProbeStatus {
    init(_ result: PsmithProbeResult) {
        switch result {
        case .ok(_, let version): self = .ok(version: version)
        case .wrongServer(let detail): self = .wrong(detail)
        case .unreachable(let detail): self = .unreachable(detail)
        }
    }
}

// MARK: - Credentials step

private struct CredentialsEntry: View {
    let serverURL: URL
    @Binding var serverVersion: String?
    /// "Change" beside the server: hidden when signing back in, where the
    /// host is the account's own.
    var onChangeServer: (() -> Void)?
    /// Throws on failure; the message shows under the fields.
    let onSubmit: (String, String) async throws -> Void

    @State private var username: String
    @State private var password: String
    @State private var inFlight = false
    @State private var errorMessage: String?
    @State private var reach: ServerProbeStatus
    @FocusState private var focused: Field?
    @Environment(\.theme) private var theme

    enum Field: Hashable { case username, password }

    init(serverURL: URL, serverVersion: Binding<String?>, initialUsername: String, initialPassword: String,
         initialError: String?, onChangeServer: (() -> Void)?, onSubmit: @escaping (String, String) async throws -> Void) {
        self.serverURL = serverURL
        _serverVersion = serverVersion
        self.onChangeServer = onChangeServer
        self.onSubmit = onSubmit
        _username = State(initialValue: initialUsername)
        _password = State(initialValue: initialPassword)
        _errorMessage = State(initialValue: initialError)
        _reach = State(initialValue: serverVersion.wrappedValue.map { .ok(version: $0) } ?? .checking)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IKLargeTitle(text: "Sign in").padding(.horizontal, -16).frame(height: 36)
            serverRow.padding(.top, 16)
            IKCard {
                VStack(alignment: .leading, spacing: 14) {
                    IKField(label: "Username", ring: focused == .username ? theme.accent : nil) {
                        TextField("", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focused = .password }
                    }
                    IKField(label: "Password", ring: focused == .password ? theme.accent : nil) {
                        SecureField("", text: $password)
                            .textContentType(.password)
                            .focused($focused, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { Task { await submit() } }
                    }
                }
            }
            .padding(.top, 14)
            if let errorMessage {
                IKStatusLine(systemImage: "xmark.circle", text: errorMessage, color: IK.red)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
            }
            Button {
                Task { await submit() }
            } label: {
                if inFlight { ProgressView().tint(.white) } else { Text("Sign in") }
            }
            .ikWideButton()
            .disabled(username.isEmpty || password.isEmpty || inFlight)
            .padding(.top, 18)
        }
        .onAppear {
            // Signing back in has the username already: go to the password.
            focused = username.isEmpty ? .username : .password
        }
        .task {
            // Signing back in skipped the server step; check it here so the
            // row says whether the password is worth typing.
            guard serverVersion == nil, reach == .checking else { return }
            reach = ServerProbeStatus(await probePsmithServer(url: serverURL))
            if case .ok(let v) = reach { serverVersion = v }
        }
    }

    private var serverRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 14))
                .foregroundStyle(IK.strong)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(IK.wash(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(serverURL.absoluteString)
                    .font(.system(size: 15)).foregroundStyle(IK.text)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    switch reach {
                    case .ok(let v):
                        IKDot(color: IK.green, size: 7)
                        Text(ServerURLEntry.reachable(v))
                    case .checking, .idle:
                        Text("Checking…")
                    case .wrong, .unreachable:
                        IKDot(color: IK.red, size: 7)
                        Text("Not answering")
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(IK.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onChangeServer {
                Button(action: onChangeServer) {
                    Text("Change").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accentInk)
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.settingsGroup))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.05), lineWidth: 1))
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
