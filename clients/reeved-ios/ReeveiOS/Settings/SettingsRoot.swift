import SwiftUI
import ReeveKit
import ReeveUI

/// iOS Settings tab root — list of categories grouped into "Data"
/// (the user's configured providers / profiles / plugins) and
/// "Settings" (app-level preferences). Each row pushes its detail
/// screen onto the NavigationStack. Per `docs/ios-screens.md` §2.14.
///
/// Account switching (add / switch / sign out) lives on the chats
/// toolbar's account menu, not here — the menu surfaces the active
/// identity at the top of every chats session, which makes a
/// dedicated Settings section redundant.
struct SettingsRoot: View {
    var body: some View {
        List {
            Section("Data") {
                NavigationLink {
                    ProvidersListView()
                } label: {
                    categoryRow("Providers", systemImage: "cpu")
                }
                NavigationLink {
                    ProfilesListView()
                } label: {
                    categoryRow("Profiles", systemImage: "person.crop.rectangle")
                }
                NavigationLink {
                    PluginsListView()
                } label: {
                    categoryRow("Plugins", systemImage: "puzzlepiece.extension")
                }
            }

            Section("Settings") {
                NavigationLink {
                    GeneralDetailView()
                } label: {
                    categoryRow("General", systemImage: "gearshape")
                }
                NavigationLink {
                    AppearanceDetailView()
                } label: {
                    categoryRow("Appearance", systemImage: "paintpalette")
                }
                NavigationLink {
                    NotificationsDetailView()
                } label: {
                    categoryRow("Notifications", systemImage: "bell")
                }
                NavigationLink {
                    PrivacyDetailView()
                } label: {
                    categoryRow("Privacy", systemImage: "hand.raised")
                }
                NavigationLink {
                    CostDetailView()
                } label: {
                    categoryRow("Cost", systemImage: "dollarsign.circle")
                }
                NavigationLink {
                    LangfuseDetailView()
                } label: {
                    categoryRow("Langfuse", systemImage: "chart.line.uptrend.xyaxis")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func categoryRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
    }
}

/// iOS Add-account form. Pushed on the Settings NavigationStack
/// (not modal) so it shares the same shell. Two-phase form
/// (server URL → credentials), same shape as the first-run
/// iOSAccountSetupView; on success pops back to SettingsRoot
/// and AccountManager activates the new account.
struct iOSAddAccountForm: View {
    @Environment(AccountManager.self) private var accountManager
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .server
    @State private var hostText: String = ""
    @State private var pendingHost: URL?
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var displayLabel: String = ""
    @State private var inFlight = false
    @State private var errorMessage: String?

    enum Phase: Hashable { case server, credentials }

    var body: some View {
        Form {
            switch phase {
            case .server:
                Section {
                    TextField("https://reeve.example.com", text: $hostText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: { Text("Server URL") }
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
            case .credentials:
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
                } header: { Text("Credentials") }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if inFlight {
                            HStack { ProgressView(); Text("Signing in…") }
                        } else {
                            Text("Add account").bold()
                        }
                    }
                    .disabled(inFlight || username.isEmpty || password.isEmpty)
                    Button("Back", role: .cancel) {
                        phase = .server
                    }
                }
            }
            if let err = errorMessage {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add account")
        .navigationBarTitleDisplayMode(.inline)
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
            dismiss()
        } catch {
            errorMessage = ReeveError.display(error)
        }
    }
}
