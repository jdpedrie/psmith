import Testing
import AppKit
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI

/// A user made through the admin API for one test, deleted after it.
@MainActor
struct E2EUser {
    let id: String
    let username: String
    let password: String

    /// Creates a non-admin user with the bootstrap admin's session,
    /// over the Connect JSON protocol, the way TestSession does with
    /// the generated client.
    static func create() async throws -> E2EUser {
        let username = "e2e-\(UUID().uuidString.prefix(8))".lowercased()
        let password = "e2e-password-\(UUID().uuidString.prefix(8))"
        let token = try await adminToken()
        let body = try await call("CreateUser", token: token, ["username": username, "password": password, "isAdmin": false])
        guard let user = body["user"] as? [String: Any], let id = user["id"] as? String else {
            throw E2EError("CreateUser answered without a user: \(body)")
        }
        return E2EUser(id: id, username: username, password: password)
    }

    func delete() async {
        guard let token = try? await Self.adminToken() else { return }
        _ = try? await Self.call("DeleteUser", token: token, ["id": id])
    }

    private static func adminToken() async throws -> String {
        let s = MacE2E.server()
        let body = try await call("Login", token: nil, ["username": s.user, "password": s.password])
        guard let token = body["sessionToken"] as? String else { throw E2EError("Login answered without a token: \(body)") }
        return token
    }

    private static func call(_ method: String, token: String?, _ json: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: MacE2E.server().url.appendingPathComponent("psmith.v1.AuthService/\(method)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw E2EError("\(method) failed: \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// An AccountManager of its own: a fresh defaults suite, so these tests
/// never see or touch the accounts another suite (or the real app)
/// keeps. Accounts it adds are removed, and their tokens cleared, after.
@MainActor
final class E2EAccounts {
    let suite = "psmith-mac-e2e-accounts-\(UUID().uuidString)"
    let manager: AccountManager

    init() {
        manager = AccountManager(store: AccountStore(defaults: UserDefaults(suiteName: suite)!))
    }

    func tearDown() async {
        for a in manager.accounts { await manager.removeAccount(id: a.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@Suite(.serialized, .enabled(if: MacE2E.enabled))
@MainActor
struct AccountsE2ETests {
    private var host: String { MacE2E.server().url.absoluteString }
    private var hostPort: String {
        let u = MacE2E.server().url
        return "\(u.host ?? ""):\(u.port ?? 0)"
    }

    // MARK: Sign-in

    @Test func signInChecksTheServerThenRejectsAWrongPassword() async throws {
        try await MacE2E.run { e in
            let accounts = E2EAccounts()
            try await e.withCleanup({ await accounts.tearDown() }) {
                await e.mountWindow(LoginView().environment(accounts.manager), size: CGSize(width: 760, height: 620))
                await e.waitForLabel("Connect to a Psmith server")
                #expect(!MacE2E.isEnabledNode(e.element("Continue")), "Continue is enabled before the server is checked")

                await e.fill("Address", "http://127.0.0.1:9")
                await e.press("Test Connection")
                await e.waitForLabel(containing: "Couldn’t reach this address", timeout: 15)
                #expect(!MacE2E.isEnabledNode(e.element("Continue")))

                await e.fill("Address", host)
                await e.press("Test Connection")
                await e.waitForLabel(containing: "Reachable.", timeout: 10)
                await e.press("Continue")
                await e.waitForLabel("Sign in")

                await e.fill("Username", MacE2E.server().user)
                await e.fill("Password", "not-the-password")
                await e.press("Sign In")
                await e.waitFor("no error for a wrong password. Have: \(e.labels())", timeout: 10) {
                    e.labels().contains { $0.localizedCaseInsensitiveContains("invalid") || $0.localizedCaseInsensitiveContains("password") && $0 != "Password" }
                }
                #expect(accounts.manager.accounts.isEmpty, "a failed sign-in saved an account")

                await e.fill("Password", MacE2E.server().password)
                await e.press("Sign In")
                await e.waitFor("the right password didn't sign in", timeout: 10) {
                    accounts.manager.active?.authState.phase == .signedIn
                }
                #expect(accounts.manager.accounts.map(\.username) == [MacE2E.server().user])
            }
        }
    }

    @Test func signInChangeGoesBackToTheServer() async throws {
        try await MacE2E.run { e in
            let accounts = E2EAccounts()
            try await e.withCleanup({ await accounts.tearDown() }) {
                await e.mountWindow(LoginView().environment(accounts.manager), size: CGSize(width: 760, height: 620))
                await e.fill("Address", host)
                await e.submitField("Address")
                await e.waitForLabel(containing: "Reachable.", timeout: 10)
                await e.press("Continue")
                await e.waitForLabel("Sign in")
                await e.press("Change")
                await e.waitForLabel("Connect to a Psmith server")
                #expect(e.labeledField("Address")?.stringValue == host)
            }
        }
    }

    // MARK: Accounts pane

    @Test func accountsPaneRenamesSignsOutBackInAndRemoves() async throws {
        try await MacE2E.run { e in
            let accounts = E2EAccounts()
            let user = try await E2EUser.create()
            try await e.withCleanup({
                await accounts.tearDown()
                await user.delete()
            }) {
                let admin = try await accounts.manager.addAccount(host: MacE2E.server().url, username: MacE2E.server().user,
                                                                   password: MacE2E.server().password)
                await e.mountWindow(SettingsView(providersModel: e.app.providers, profilesModel: e.app.profiles, mcpServersModel: e.app.mcpServers)
                    .environment(accounts.manager), size: CGSize(width: 1052, height: 720))
                await e.settingsPane(.accounts)
                await e.waitForLabel("\(admin.username) on \(hostPort)")
                await e.waitForLabel("Reachable", timeout: 10)
                await e.waitForLabel(containing: "· active")

                await e.fill("Name in menus", "Work")
                await e.submitField("Name in menus")
                await e.waitFor("the name never saved") { accounts.manager.accounts.first?.displayLabel == "Work" }

                // Adding a second account, inline.
                await e.press("Add account…")
                await e.waitForLabel("Add an account")
                #expect(!MacE2E.isEnabledNode(e.element("Sign In")))
                await e.fill("Address", host)
                await e.submitField("Address")
                await e.waitForLabel(containing: "found. Sign in with a password.", timeout: 10)
                await e.fill("Username", user.username)
                await e.fill("Password", "wrong-\(user.password)")
                await e.press("Sign In")
                await e.waitForLabel("Couldn't sign in", timeout: 10)
                #expect(accounts.manager.accounts.count == 1)
                await e.fill("Password", user.password)
                await e.press("Sign In")
                await e.waitFor("the second account never signed in", timeout: 10) { accounts.manager.accounts.count == 2 }
                await e.waitForLabel("\(user.username) on \(hostPort)")
                let second = accounts.manager.accounts.first { $0.username == user.username }!

                // Sign out keeps it; sign in again restores it.
                await e.press("Sign Out")
                await e.waitFor("Sign Out didn't sign out") { !accounts.manager.isSignedIn(second.id) }
                await e.waitForLabel("Sign In…")
                await e.press("Sign In…")
                await e.waitForLabel("Sign in again")
                #expect(e.labeledField("Username")?.stringValue == user.username)
                await e.waitForLabel(containing: "found. Sign in with a password.", timeout: 10)
                await e.fill("Password", user.password)
                await e.press("Sign In")
                await e.waitFor("signing back in didn't", timeout: 10) { accounts.manager.isSignedIn(second.id) }
                await e.waitForLabel("Sign Out")

                // Switching to the first account, then removing the second.
                await e.press(containing: ", \(admin.username), ")
                await e.waitForLabel("Switch to This Account")
                await e.press("Switch to This Account")
                await e.waitFor("the switch didn't take") { accounts.manager.activeAccountID == admin.id }

                await e.press(containing: ", \(user.username), ")
                await e.press("Remove…")
                await e.waitForLabel("Remove \(user.username) on \(hostPort) from this Mac?")
                await e.press("Cancel")
                await e.waitForNoLabel("Remove \(user.username) on \(hostPort) from this Mac?")
                await e.press("Remove…")
                await e.press("Remove Account")
                await e.waitFor("the account is still here") { accounts.manager.accounts.map(\.username) == [admin.username] }
            }
        }
    }

    // MARK: Onboarding

    @Test func firstRunOnboardingAddsAProviderAndEnablesAModel() async throws {
        try await MacE2E.run { e in
            let user = try await E2EUser.create()
            try await e.withCleanup({ await user.delete() }) {
                let fresh = AppModel(host: MacE2E.server().url, tokenStore: InMemoryTokenStore(), authState: AuthState(), accountID: UUID())
                _ = try await fresh.client.auth.login(username: user.username, password: user.password, clientLabel: "mac-e2e")
                await e.mountWindow(RootView().environment(fresh), size: CGSize(width: 1100, height: 760))
                await e.waitForLabel("Welcome to Psmith", timeout: 12)
                await e.waitForLabel(containing: "OpenAI", timeout: 10)
                await e.press(containing: "OpenAI")
                await e.waitForLabel("Add Provider")
                #expect(!MacE2E.isEnabledNode(e.element("Add Provider")), "Add Provider is enabled without a key")
                await e.fill("Label", "Onboarded")
                await e.fill("API key", "e2e")
                await e.fill("API base URL", MacE2E.server().llm)
                await e.press("Add Provider")
                await e.waitForLabel(containing: "fake-alpha", timeout: 15)
                await e.waitForLabel("Finish Setup")

                let boxes = e.elements().filter { MacE2E.role($0) == "AXCheckBox" }
                #expect(boxes.count == 2, "expected one checkbox per discovered model")
                if MacE2E.value(boxes[0]) != "1" { await e.pressNode(boxes[0]) }
                await e.waitFor("Finish Setup never enabled") { MacE2E.isEnabledNode(e.element("Finish Setup")) }
                await e.press("Finish Setup")
                await e.eventually("no model was enabled on the server") {
                    guard let p = try await fresh.client.modelProviders.listFromServer().first(where: { $0.label == "Onboarded" }) else { return false }
                    return try await fresh.client.modelProviders.get(id: p.id).1.contains { $0.modelID == "fake-alpha" }
                }
                await e.waitForNoLabel("Welcome to Psmith", timeout: 10)
                #expect(!fresh.providers.needsOnboarding)
            }
        }
    }
}
