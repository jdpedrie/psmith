import SwiftUI
import ReeveKit

/// Root shell that decides between the regular RootView (when
/// there's an active account) and AccountSetupView (when there
/// isn't — fresh install or last account was removed).
///
/// Injects the active AppModel into the env so existing views
/// keep reading `@Environment(AppModel.self) private var app`
/// without changes. Identifying the AppModel by id forces SwiftUI
/// to rebuild the entire tree when the active account swaps —
/// which is what we want, because every per-account VM (providers,
/// profiles, streamHub) is owned by the AppModel and shouldn't
/// leak across identity boundaries.
struct AppShell: View {
    @Bindable var accountManager: AccountManager

    var body: some View {
        if let app = accountManager.active {
            RootView()
                .environment(app)
                .id(app.accountID ?? UUID())
        } else {
            AccountSetupView()
        }
    }
}

/// First-account onboarding. Shown when AccountManager has no
/// accounts yet (fresh install + legacy migration didn't find
/// anything to import). Reuses the existing two-phase
/// LoginView shape (server URL → credentials) but pipes the
/// successful credentials through `accountManager.addAccount`
/// so the new identity is persisted.
///
/// Subsequent additions (the user already has accounts and wants
/// another) go through `AddAccountSheet` from the sidebar
/// switcher in the Phase 2 UI commit.
struct AccountSetupView: View {
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
        VStack(spacing: 16) {
            Text("Welcome to Reeve")
                .font(.title2.weight(.semibold))
            switch phase {
            case .server:
                serverPhase
            case .credentials:
                credentialsPhase
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var serverPhase: some View {
        VStack(spacing: 12) {
            Text("Where's your reeved server?")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("https://reeve.example.com", text: $hostText)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .frame(maxWidth: 380)
            if let err = errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
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

    private var credentialsPhase: some View {
        VStack(spacing: 12) {
            if let host = pendingHost {
                Text("Sign in to \(host.absoluteString)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            TextField("Display label (optional)", text: $displayLabel)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("Back") { phase = .server }
                    .buttonStyle(.borderless)
                Button {
                    Task { await submit() }
                } label: {
                    if inFlight {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Signing in…")
                        }
                    } else {
                        Text("Sign in").bold()
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
            // AppShell re-renders against accountManager.active and
            // routes into RootView; nothing more to do here.
        } catch {
            errorMessage = ReeveError.display(error)
        }
    }
}
