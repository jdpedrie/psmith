import SwiftUI
import ReeveKit

/// Two-phase sign-in: server URL first, then username/password.
///
/// Phase 1 — server URL entry — is shown when no URL has been
/// validated yet for this session OR the user clicked "Change server".
/// User types a URL, hits Test, the client probes; on success we
/// advance to phase 2 and persist the URL.
///
/// Phase 2 — credentials — is the existing username/password form, with
/// the validated URL shown above and a small "Change server" affordance
/// to bounce back to phase 1.
///
/// On launch with a previously-validated URL we skip straight to phase
/// 2 (the persisted URL is loaded by AppModel via ServerURLStore). The
/// user only sees phase 1 the first time, after a server-side change,
/// or when they explicitly want to swap.
struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var phase: Phase = .credentials
    @State private var urlStore = ServerURLStore.shared

    enum Phase: Hashable { case server, credentials }

    var body: some View {
        Group {
            switch phase {
            case .server:
                ServerURLEntry(onValidated: { newURL in
                    // Persisting triggers ReeveMacApp's onChange to
                    // rebuild AppModel — the next render of LoginView
                    // is on top of the new client.
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
        .padding(40)
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
        VStack(spacing: 16) {
            Text("Connect to reeved")
                .font(.title2)
            Text("Enter the URL where your Reeve server is running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                TextField("https://reeve.example.com", text: $urlText)
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
                Label(version.isEmpty ? "Reachable — reeved answered." : "Reachable — reeved \(version).",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .wrong(let detail):
                Label("Server responded but isn't a Reeve server: \(detail)",
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

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Reeve")
                .font(.title2)

            // Server URL header. Lives above the form so the user knows
            // which reeved they're authenticating against; clicking
            // "Change" bounces back to phase 1.
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text(serverURL.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change") { onChangeServer() }
                    .buttonStyle(.link)
                    .font(.callout)
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
        }
    }

    private func submit() async {
        guard !inFlight else { return }
        inFlight = true
        errorMessage = nil
        do {
            _ = try await app.client.auth.login(
                username: username,
                password: password,
                clientLabel: "macOS"
            )
        } catch {
            errorMessage = ReeveError.display(error)
        }
        inFlight = false
    }
}
