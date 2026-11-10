import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Getting in, end to end: signing in through the login screens, a new
/// user's onboarding through to the chats list, and Settings › Accounts
/// with two real accounts. Each test keeps its accounts in its own
/// UserDefaults suite so nothing leaks into the app's real account list.
@MainActor
final class AccountsE2ETests: E2ETestCase {
    private var suites: [String] = []
    private var managers: [AccountManager] = []
    /// The login screens write the process-wide server hint; the app on
    /// this simulator keeps its own.
    private var savedServerURL: URL?

    override func setUp() async throws {
        try await super.setUp()
        savedServerURL = ServerURLStore.shared.current
    }

    override func tearDown() async throws {
        // Removing drops each account's stored token too.
        for m in managers { for a in m.accounts { await m.removeAccount(id: a.id) } }
        managers = []
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
        if let savedServerURL { ServerURLStore.shared.current = savedServerURL }
        try await super.tearDown()
    }

    private func isolatedAccounts() -> AccountManager {
        let name = "psmith-e2e-accounts-\(UUID().uuidString.prefix(8))"
        suites.append(name)
        let m = AccountManager(store: AccountStore(defaults: UserDefaults(suiteName: name)!))
        managers.append(m)
        return m
    }

    /// A second, empty user on the e2e server, made through the admin's
    /// CreateUser RPC (Connect's JSON encoding over plain HTTP: PsmithKit
    /// has no admin surface).
    private func createUser(_ s: Server) async throws -> (username: String, password: String) {
        func call(_ method: String, _ body: [String: Any], token: String? = nil) async throws -> [String: Any] {
            var req = URLRequest(url: s.url.appendingPathComponent("psmith.v1.AuthService/\(method)"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                throw NSError(domain: "e2e", code: code, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
            }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        let login = try await call("Login", ["username": s.user, "password": s.password])
        let token = try XCTUnwrap(login["sessionToken"] as? String)
        let username = "e2e-\(UUID().uuidString.prefix(6).lowercased())"
        let password = "e2e-password-\(UUID().uuidString.prefix(6))"
        _ = try await call("CreateUser", ["username": username, "password": password], token: token)
        return (username, password)
    }

    // MARK: Login

    /// Cold start: the server step checks the URL, then the credentials
    /// sign in and the account lands in the manager, signed in.
    func testSignInThroughTheLoginScreens() async throws {
        let (app, convos, _) = try await signedIn()
        let s = try server()
        let accounts = isolatedAccounts()
        mount(LoginView(), app: app, convos: convos, accounts: accounts)
        await waitFor("the server field never showed") { !self.textFields().isEmpty }
        let urlField = try XCTUnwrap(textFields().first, "no server field")
        await type(s.url.absoluteString, into: urlField)
        await press("Test connection")
        await waitForText("reachable", timeout: 10)
        await press("Continue")
        await waitForText("sign in")
        let fields = textFields()
        XCTAssertEqual(fields.count, 2, "expected username and password fields")
        await type(s.user, into: fields[0])
        await type(s.password, into: fields[1])
        await press("Sign in")
        await waitFor("signing in never added the account", timeout: 15) { accounts.accounts.count == 1 }
        let active = try XCTUnwrap(accounts.active)
        await waitFor("the new account isn't signed in", timeout: 10) { active.authState.phase == .signedIn }
        XCTAssertEqual(active.authState.currentUser?.username, s.user)
        XCTAssertEqual(accounts.accounts.first?.host, s.url)
    }

    /// A wrong password says so and adds nothing.
    func testAWrongPasswordIsRefused() async throws {
        let (app, convos, _) = try await signedIn()
        let s = try server()
        let accounts = isolatedAccounts()
        mount(LoginView(), app: app, convos: convos, accounts: accounts)
        await waitFor("the server field never showed") { !self.textFields().isEmpty }
        await type(s.url.absoluteString, into: try XCTUnwrap(textFields().first))
        await press("Test connection")
        await waitForText("reachable", timeout: 10)
        await press("Continue")
        await waitForText("sign in")
        let fields = textFields()
        await type(s.user, into: fields[0])
        await type("not-the-password", into: fields[1])
        await press("Sign in")
        await spin(2)
        XCTAssertTrue(accounts.accounts.isEmpty, "a refused sign-in still added an account")
        await waitForText("sign in")
    }

    // MARK: Onboarding

    /// A user with no providers lands on onboarding; adding the fake
    /// provider, discovering its models and turning one on lands them in
    /// the chats list.
    func testOnboardingAddsAProviderAndOpensTheApp() async throws {
        let s = try server()
        let user = try await createUser(s)
        let app = AppModel(host: s.url, tokenStore: InMemoryTokenStore(), connectivityState: .online)
        _ = try await app.client.auth.login(username: user.username, password: user.password)
        await app.bootstrap()
        let convos = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
        mount(RootView(), app: app, convos: convos)
        await waitForText("choose a provider", timeout: 15)
        await press(containing: "Together AI")
        await waitFor("the key step never showed") { self.field("sk-…") != nil }
        await type("Fake \(user.username)", into: try XCTUnwrap(field("e.g. Anthropic")))
        await type("e2e-key", into: try XCTUnwrap(field("sk-…")))
        await type(s.llm, into: try XCTUnwrap(field("https://api.example.com/v1")))
        await press("Add Provider")
        await waitForText("fake-alpha", timeout: 15)
        await press("fake-alpha")
        await press("Finish Setup")
        await waitFor("onboarding never handed over to the app", timeout: 15) { !app.providers.needsOnboarding }
        await waitForText("chats", timeout: 10)
        let providers = try await app.client.modelProviders.list()
        let provider = try XCTUnwrap(providers.first { $0.label == "Fake \(user.username)" }, "the provider wasn't created")
        let models = try await app.client.modelProviders.get(id: provider.id).1
        XCTAssertTrue(models.contains { $0.modelID == "fake-alpha" }, "the chosen model wasn't enabled")
    }

    // MARK: Accounts

    /// Two accounts: switching makes the other active, signing out ends
    /// the session on the server, and removing takes it off the list.
    func testAccountsSwitchSignOutAndRemove() async throws {
        let (app, convos, _) = try await signedIn()
        let s = try server()
        let other = try await createUser(s)
        let accounts = isolatedAccounts()
        try await accounts.addAccount(host: s.url, username: s.user, password: s.password)
        let adminID = try XCTUnwrap(accounts.activeAccountID)
        try await accounts.addAccount(host: s.url, username: other.username, password: other.password)
        let otherID = try XCTUnwrap(accounts.activeAccountID)
        XCTAssertNotEqual(adminID, otherID)
        let activeApp = try XCTUnwrap(accounts.active)
        mount(E2EPushed { SettingsAccounts() }, app: activeApp, convos: convos, accounts: accounts)
        await waitForText(other.username)

        await press(containing: "Switch to")
        await waitFor("Switch never changed the active account") { accounts.activeAccountID == adminID }

        // Sign out of the admin account, from a rebuilt page.
        let admin = try XCTUnwrap(accounts.active)
        mount(E2EPushed { SettingsAccounts() }, app: admin, convos: convos, accounts: accounts)
        await press(containing: "Sign Out of")
        await waitFor("the account still reads signed in", timeout: 10) { !accounts.isSignedIn(adminID) }
        await eventually("the server still honors the signed-out session") {
            do { _ = try await admin.client.auth.whoAmI(); return false } catch { return true }
        }

        // Remove the other account.
        let otherApp = try XCTUnwrap(accounts.appModel(for: otherID))
        accounts.switchAccount(to: otherID)
        mount(E2EPushed { SettingsAccounts() }, app: otherApp, convos: convos, accounts: accounts)
        await waitForText(s.user)
        // Remove sits behind the row's swipe and context menu, which UIKit
        // won't open headless; this is the confirm card's call.
        await accounts.removeAccount(id: adminID)
        mount(E2EPushed { SettingsAccounts() }, app: otherApp, convos: convos, accounts: accounts)
        await waitFor("Remove never took the account off the list", timeout: 10) {
            !accounts.accounts.contains { $0.id == adminID }
        }
        _ = app
    }
}
