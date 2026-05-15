import SwiftUI
import ReeveKit

/// First-account onboarding for iOS. Two-phase form (host →
/// credentials) that calls `accountManager.addAccount` on
/// success — the Account is persisted, its AppModel becomes
/// active, and `iOSAppShell` re-renders into RootView.
///
/// Subsequent additions go through the AddAccountSheet from the
/// switcher chip in the Phase 2 UI commit.
struct iOSAccountSetupView: View {
    @Environment(AccountManager.self) private var accountManager
    @State private var phase: Phase = .server
    @State private var hostText: String = ServerURLStore.shared.current.absoluteString
    @State private var pendingHost: URL?
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var displayLabel: String = ""
    @State private var inFlight = false
    @State private var errorMessage: String?

    enum Phase: Hashable { case server, credentials }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .server:
                    serverSection
                case .credentials:
                    credentialsSection
                }
                if let err = errorMessage {
                    Section { Text(err).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Welcome to Reeve")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section {
            TextField("https://reeve.example.com", text: $hostText)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("Server URL")
        } footer: {
            Text("The base URL of your reeved instance.")
        }
        Section {
            Button("Continue") {
                guard let url = URL(string: hostText.trimmingCharacters(in: .whitespaces)) else {
                    errorMessage = "Not a valid URL"
                    return
                }
                pendingHost = url
                errorMessage = nil
                phase = .credentials
            }
            .disabled(hostText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        Section {
            if let host = pendingHost {
                LabeledContent("Server", value: host.absoluteString)
                    .foregroundStyle(.secondary)
            }
            TextField("Username", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Password", text: $password)
            TextField("Display label (optional)", text: $displayLabel)
                .autocorrectionDisabled()
        } header: {
            Text("Credentials")
        }
        Section {
            Button {
                Task { await submit() }
            } label: {
                if inFlight {
                    HStack { ProgressView(); Text("Signing in…") }
                } else {
                    Text("Sign in").bold()
                }
            }
            .disabled(inFlight || username.isEmpty || password.isEmpty)
            Button("Back", role: .cancel) {
                phase = .server
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
        } catch {
            errorMessage = ReeveError.display(error)
        }
    }
}
