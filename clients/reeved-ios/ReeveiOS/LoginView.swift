import SwiftUI
import ReeveKit

/// Two-phase iOS sign-in. Mirrors `ReeveMac/LoginView.swift` exactly:
///
/// Phase 1 — server URL entry — type the URL, hit Test (probes via
/// `probeReeveServer`), green → enable Continue.
/// Phase 2 — credentials — username + password, posts to
/// `AuthService.Login`. Server URL header carries a "Change" link that
/// bounces back to phase 1.
///
/// On launch with a previously-validated URL we skip straight to
/// phase 2 (the persisted URL comes back from `ServerURLStore`). The
/// user only sees phase 1 the first time, after a server-side change,
/// or after explicit "Change server".
struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var phase: Phase = .credentials
    @State private var urlStore = ServerURLStore.shared

    enum Phase: Hashable { case server, credentials }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .server:
                    ServerURLEntry(onValidated: { newURL in
                        // Persisting flips ServerURLStore.current,
                        // which the App scene watches via @State; the
                        // outer `.onChange(of: urlStore.current)` in
                        // ReeveiOSApp rebuilds AppModel against the
                        // new URL. The next render of LoginView is on
                        // top of the new client.
                        urlStore.current = newURL
                        phase = .credentials
                    })
                case .credentials:
                    CredentialsEntry(
                        serverURL: app.serverURL,
                        onChangeServer: { phase = .server }
                    )
                }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Phase 1: server URL entry

private struct ServerURLEntry: View {
    let onValidated: (URL) -> Void
    @State private var urlText: String = ServerURLStore.shared.current.absoluteString
    @State private var inFlight = false
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case ok(version: String)
        case wrong(String)
        case unreachable(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("Server URL")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://reeve.example.com", text: $urlText)
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
            Text("Connect to reeved")
                .font(.title2.weight(.semibold))
            Text("Enter the URL where your Reeve server is running. We'll probe it to confirm before asking for your credentials.")
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
                        ? "Reachable — reeved answered."
                        : "Reachable — reeved \(version)."
                )
            case .wrong(let detail):
                banner(
                    tint: .orange,
                    icon: "exclamationmark.triangle.fill",
                    text: "Server answered but isn't a Reeve server: \(detail)"
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
        let result = await probeReeveServer(url: url)
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
    @Environment(AppModel.self) private var app
    let serverURL: URL
    let onChangeServer: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var inFlight = false
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    enum Field: Hashable { case username, password }

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
        .onAppear { focused = .username }
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
            Button("Change", action: onChangeServer)
                .font(.callout)
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
            _ = try await app.client.auth.login(
                username: username,
                password: password,
                clientLabel: "iOS"
            )
            Haptics.notify(.success)
        } catch {
            errorMessage = ReeveError.display(error)
            Haptics.notify(.error)
        }
        inFlight = false
    }
}
