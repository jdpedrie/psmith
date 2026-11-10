import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Every Settings page end to end. The check for each: change a value
/// through the page's own controls (or the call a control makes when
/// UIKit won't run it headless, such as a Menu's picker or a swipe), the
/// server saves it (read back through PsmithClient), and a freshly built
/// page shows it. Pages that only keep state on this phone check the local
/// store instead of the server.
@MainActor
final class SettingsE2ETests: E2ETestCase {

    @discardableResult
    private func page<V: View>(_ app: AppModel, _ convos: ConversationsModel, themes: ThemeStore? = nil,
                               accounts: AccountManager? = nil, @ViewBuilder _ v: () -> V) -> UIWindow {
        mount(E2EPushed(v), app: app, convos: convos, accounts: accounts, themes: themes)
    }

    /// The text field currently holding `text`.
    private func field(holding text: String) -> UITextField? {
        textFields().first { $0.text == text }
    }

    // MARK: Root

    func testRootSummarizesAndOpensEachPage() async throws {
        let (app, convos, seeded) = try await signedIn()
        page(app, convos) { SettingsRoot() }
        await waitForText("settings")
        await waitForText("profiles")
        for row in ["General", "Appearance", "Notifications", "Privacy", "Models", "Profiles", "Plugins", "Servers",
                    "Usage", "Langfuse", "Embedder", "Speech", "Files and Device Tools"] {
            await press(containing: row)
            await waitFor("\(row) never pushed") { E2ETimeline.navigationDepth(self.window!) >= 3 }
            await spin(0.4)
            // Back, the way the bar's button pops.
            if let nav = navigationController() { nav.popViewController(animated: false) }
            await waitFor("\(row) never popped") { E2ETimeline.navigationDepth(self.window!) == 2 }
        }
        // Search narrows the rows.
        await waitFor("no search field") { self.field("Search settings") != nil }
        await type("lang", into: try XCTUnwrap(field("Search settings")))
        await waitFor("search didn't narrow the rows") { self.element("Profiles") == nil && self.screenText().contains("langfuse") }
        _ = seeded
    }

    private func navigationController() -> UINavigationController? {
        func find(_ vc: UIViewController?) -> UINavigationController? {
            guard let vc else { return nil }
            if let nav = vc as? UINavigationController { return nav }
            for child in vc.children { if let n = find(child) { return n } }
            return find(vc.presentedViewController)
        }
        return find(window?.rootViewController)
    }

    // MARK: General

    func testGeneralContextWarningSavesToTheServer() async throws {
        let (app, convos, _) = try await signedIn()
        await app.preferences.load()
        let original = app.preferences.preferences.contextWarningTokens
        defer { Task { await app.preferences.setContextWarningTokens(original) } }
        page(app, convos) { SettingsGeneral() }
        await waitForText("warn at")
        let target: Int32 = original == 150_000 ? 200_000 : 150_000
        // The Warn at menu's picker binding.
        await app.preferences.setContextWarningTokens(target)
        await eventually("the warning size never reached the server") {
            try await app.client.preferences.get().contextWarningTokens == target
        }
        page(app, convos) { SettingsGeneral() }
        await waitForText("\(target / 1000)k tokens")
    }

    func testGeneralCacheCapPersistsOnThisPhone() async throws {
        let (app, convos, _) = try await signedIn()
        let original = CachePreferences.capBytes
        defer { CachePreferences.capBytes = original }
        page(app, convos) { SettingsGeneral() }
        await waitForText("cap")
        let mb = original / (1024 * 1024)
        let label = mb + 25 <= CachePreferences.maxCapBytes / (1024 * 1024) ? "Raise cap by 25 MB" : "Lower cap by 25 MB"
        await press(label)
        let expected = label.hasPrefix("Raise") ? mb + 25 : mb - 25
        await waitFor("the cap never changed") { CachePreferences.capBytes == expected * 1024 * 1024 }
        page(app, convos) { SettingsGeneral() }
        await waitForText("\(expected) mb")
    }

    // MARK: Appearance

    func testAppearanceThemeAndTurnDetailsPersist() async throws {
        let (app, convos, _) = try await signedIn()
        let themes = ThemeStore()
        let originalTheme = themes.current
        let originalDetails = sharedAppPreferences.showTurnDetails
        defer {
            themes.current = originalTheme
            sharedAppPreferences.showTurnDetails = originalDetails
        }
        page(app, convos, themes: themes) { SettingsAppearance() }
        let target = Theme.allThemes.first { $0.id != themes.current.id }!
        await press(target.name)
        XCTAssertEqual(themes.current.id, target.id, "the tile didn't apply its theme")
        await press("Show turn details")
        XCTAssertEqual(sharedAppPreferences.showTurnDetails, !originalDetails)

        // A fresh store reads what was saved.
        let rebuilt = ThemeStore()
        XCTAssertEqual(rebuilt.current.id, target.id, "the theme didn't persist")
        page(app, convos, themes: rebuilt) { SettingsAppearance() }
        await waitFor("the rebuilt page doesn't mark the chosen theme") {
            self.element(target.name)?.accessibilityTraits.contains(.selected) == true
        }
        XCTAssertEqual(isOn("Show turn details"), !originalDetails)
    }

    // MARK: Notifications and Privacy

    /// Turned off only: turning either on asks iOS for permission, a system
    /// prompt a headless test can't answer.
    func testNotificationsSwitchPersists() async throws {
        let (app, convos, _) = try await signedIn()
        let original = sharedAppPreferences.notifyOnUnfocusedCompletion
        defer { sharedAppPreferences.notifyOnUnfocusedCompletion = original }
        sharedAppPreferences.notifyOnUnfocusedCompletion = true
        page(app, convos) { SettingsNotifications() }
        await press("Notify when a reply finishes")
        XCTAssertFalse(sharedAppPreferences.notifyOnUnfocusedCompletion)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "psmith.appPrefs.notifyOnUnfocusedCompletion") as? Bool ?? false, false)
        page(app, convos) { SettingsNotifications() }
        await waitFor("the rebuilt page shows the switch on") { self.isOn("Notify when a reply finishes") == false }
    }

    func testPrivacyLocationSwitchPersists() async throws {
        let (app, convos, _) = try await signedIn()
        let original = LocationFactPreference.enabled
        defer { LocationFactPreference.enabled = original }
        LocationFactPreference.enabled = true
        page(app, convos) { SettingsPrivacy() }
        await press("Send location")
        await waitFor("the switch never wrote the preference") { !LocationFactPreference.enabled }
        page(app, convos) { SettingsPrivacy() }
        await waitFor("the rebuilt page shows location on") { self.isOn("Send location") == false }
    }

    // MARK: Models

    func testModelsProviderModelAndDefaultsSave() async throws {
        let (app, convos, seeded) = try await signedIn()
        let w = page(app, convos) { ModelsSettingsScreen() }
        await press(containing: seeded.provider.label, timeout: 10)
        await waitFor("the provider never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        await waitForText("model one")

        // A model's display name.
        // The row's link reads its name then its details; the switch beside
        // it reads the name alone.
        await press(containing: "Model One,")
        await waitFor("the model never pushed") { E2ETimeline.navigationDepth(w) == 4 }
        let name = try XCTUnwrap(field(holding: "Model One"), "no display name field")
        await type("Model Uno \(seeded.tag)", into: name)
        await press("Save")
        await eventually("the display name never reached the server") {
            try await app.client.modelProviders.get(id: seeded.provider.id).1
                .contains { $0.modelID == "model-one" && $0.displayName == "Model Uno \(seeded.tag)" }
        }

        // Provider defaults.
        page(app, convos) { ProviderDefaultsScreen(provider: seeded.provider) }
        await waitForText("max output tokens")
        await press("Increase max output tokens")
        await press("Save")
        var saved: Int32?
        await eventually("the provider default never reached the server") {
            saved = try await app.client.modelProviders.get(id: seeded.provider.id).0.defaultSettings?.maxOutputTokens
            return saved != nil
        }
        await app.providers.load()
        let provider = try XCTUnwrap(app.providers.providers.first { $0.id == seeded.provider.id })
        page(app, convos) { ProviderDefaultsScreen(provider: provider) }
        await waitForText(try XCTUnwrap(saved).formatted())

        // The list again, rebuilt: the renamed model shows under its provider.
        let w2 = page(app, convos) { ModelsSettingsScreen() }
        await press(containing: seeded.provider.label)
        await waitFor("the provider never pushed") { E2ETimeline.navigationDepth(w2) == 3 }
        await waitForText("model uno")
    }

    // MARK: Profiles

    func testProfileEditSavesAndShowsAfterRebuild() async throws {
        let (app, convos, seeded) = try await signedIn()
        page(app, convos) { SettingsProfile(profileID: seeded.alpha.id) }
        await waitForText("alpha")
        let profile = try XCTUnwrap(app.profiles.profiles.first { $0.id == seeded.alpha.id })
        // The page's draft: the System prompt field's binding.
        let draft = ProfileDraft.draft(for: profile)
        draft.fields.systemMessage = "Speak like a lighthouse keeper \(seeded.tag)."
        await press("Save")
        await eventually("the system prompt never reached the server") {
            try await app.client.profiles.get(id: seeded.alpha.id).0.systemMessage == "Speak like a lighthouse keeper \(seeded.tag)."
        }
        page(app, convos) { SettingsProfile(profileID: seeded.alpha.id) }
        await waitForText("lighthouse keeper")
    }

    func testProfilesListCreatesFavoritesDefaultsAndDeletes() async throws {
        let (app, convos, seeded) = try await signedIn()
        let w = page(app, convos) { SettingsProfilesList() }
        await waitForText("alpha")
        await press(containing: "New profile")
        await waitFor("the new profile page never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        let name = "Gamma \(seeded.tag)"
        await type(name, into: try XCTUnwrap(field("Profile name")))
        await press("Create")
        var created: PsmithProfile?
        await eventually("the new profile never reached the server") {
            created = try await app.client.profiles.list().first { $0.name == name }
            return created != nil
        }
        await waitFor("saving a new profile didn't return to the list") { E2ETimeline.navigationDepth(w) == 2 }
        await waitForText("gamma")
        let gamma = try XCTUnwrap(created)

        // The swipe actions' calls.
        await app.profiles.toggleFavorite(gamma.id)
        await eventually("favorite never reached the server") { try await app.client.profiles.get(id: gamma.id).0.favorite }
        await waitFor("the row doesn't show the favorite") { self.labels().contains { $0.contains("Favorite") } }
        await app.profiles.setDefault(gamma.id)
        await eventually("default never reached the server") { try await app.client.profiles.get(id: gamma.id).0.isDefault }

        page(app, convos) { SettingsProfilesList() }
        await waitForText("gamma")
        await app.profiles.setDefault(seeded.alpha.id)
        app.profiles.selectedID = gamma.id
        await app.profiles.deleteSelected()
        await eventually("delete never reached the server") {
            do { _ = try await app.client.profiles.get(id: gamma.id); return false } catch { return true }
        }
        await spin(0.5)
        XCTAssertFalse(screenText().contains("gamma"), "the deleted profile still shows")
    }

    func testProfilePluginsAttachAndSave() async throws {
        let (app, convos, seeded) = try await signedIn()
        await app.profiles.loadPluginTypes()
        let plugin = try XCTUnwrap(app.profiles.pluginTypes.first {
            !$0.name.hasPrefix("mcp:") && !$0.profileScopedConfigFields.contains { $0.required }
        }, "no plugin without required per-profile fields to attach")
        let profile = try XCTUnwrap(app.profiles.profiles.first { $0.id == seeded.beta.id })
        let draft = ProfileDraft.draft(for: profile)
        let w = page(app, convos) { SettingsProfilePlugins(draft: draft) }
        await waitFor("the plugins never loaded", timeout: 10) { draft.pluginsLoaded }
        await press(containing: "Add plugin")
        await waitFor("Add plugin never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        await press(containing: plugin.displayName)
        await waitFor("picking didn't attach") { draft.plugins.contains { $0.pluginName == plugin.name } }
        await press("Save")
        await eventually("the attachment never reached the server") {
            try await app.client.profiles.getProfilePlugins(profileID: seeded.beta.id).contains { $0.pluginName == plugin.name }
        }
        let fresh = ProfileDraft.draft(for: profile)
        page(app, convos) { SettingsProfilePlugins(draft: fresh) }
        await waitForText(plugin.displayName)
    }

    func testProfileShareExportsAndImportsACopy() async throws {
        let (app, convos, seeded) = try await signedIn()
        page(app, convos) { SettingsProfileShare(profileID: seeded.beta.id) }
        await press(containing: "Export \(seeded.beta.name)")
        await waitFor("export never produced a bundle", timeout: 10) { app.profiles.pendingExport != nil }
        let payload = try XCTUnwrap(app.profiles.pendingExport?.payload)
        // What the file importer hands over after the system picker.
        await app.profiles.previewImport(payload: payload)
        await waitFor("the import never reached review") { app.profiles.pendingImport != nil }
        await waitForText("everything resolved")
        // The review card's Import.
        await app.profiles.confirmImport()
        await eventually("the import never created a copy") {
            try await app.client.profiles.list().contains { $0.name.hasPrefix(seeded.beta.name) && $0.id != seeded.beta.id }
        }
        if let copy = try await app.client.profiles.list().first(where: { $0.name.hasPrefix(seeded.beta.name) && $0.id != seeded.beta.id }) {
            try? await app.client.profiles.delete(id: copy.id)
        }
    }

    // MARK: Plugins and Servers

    func testServersRegisterShowAndDelete() async throws {
        let (app, convos, seeded) = try await signedIn()
        let w = page(app, convos) { SettingsServers() }
        await press("Add server")
        await waitFor("Add server never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        let name = "Tide gauge \(seeded.tag)"
        await type(name, into: try XCTUnwrap(field("GitHub")))
        await type("http://127.0.0.1:9/mcp", into: try XCTUnwrap(field("https://example.com/mcp")))
        await press("Register")
        var server: PsmithMCPServer?
        await eventually("the server never registered") {
            server = try await app.client.profiles.listMCPServers().first { $0.name == name }
            return server != nil
        }
        page(app, convos) { SettingsServers() }
        await waitForText("tide gauge")
        await press(containing: name)
        await press("Delete server")
        await press("Delete")
        await eventually("the server is still registered") {
            try await !app.client.profiles.listMCPServers().contains { $0.name == name }
        }
    }

    func testPluginsListAndGlobalConfigSave() async throws {
        let (app, convos, _) = try await signedIn()
        await app.profiles.loadPluginTypes()
        let plugin = try XCTUnwrap(app.profiles.pluginTypes.first {
            !$0.name.hasPrefix("mcp:") && $0.globalConfigFields.contains { $0.type == .text }
        }, "no plugin with a global text field")
        let fieldDef = try XCTUnwrap(plugin.globalConfigFields.first { $0.type == .text })
        let w = page(app, convos) { SettingsPlugins() }
        await waitForText(plugin.displayName)
        await press(containing: plugin.displayName)
        await waitFor("the plugin page never pushed") { E2ETimeline.navigationDepth(w) == 3 }
        await waitFor("the plugin page never showed a field") { !self.textFields().isEmpty }
        let f = try XCTUnwrap(textFields().first, "no field on \(plugin.displayName)'s page")
        await type("e2e-\(fieldDef.name)", into: f)
        await press("Save")
        await eventually("the plugin setting never reached the server") {
            let s = try await app.client.profiles.getUserPluginSettings(pluginName: plugin.name)
            return String(data: s.config, encoding: .utf8)?.contains("e2e-\(fieldDef.name)") == true
        }
    }

    // MARK: Integrations

    func testLangfuseCredentialsSave() async throws {
        let (app, convos, seeded) = try await signedIn()
        page(app, convos) { SettingsLangfuse() }
        await waitFor("the page never loaded", timeout: 10) { self.field("pk-lf-…") != nil }
        await type("pk-lf-e2e-\(seeded.tag)", into: try XCTUnwrap(field("pk-lf-…")))
        await type("sk-lf-e2e", into: try XCTUnwrap(field("sk-lf-…")))
        await press("Save")
        let lf = try? await app.client.langfuse.get()
        await eventually("the credentials never reached the server: \(String(describing: lf))") {
            let c = try await app.client.langfuse.get()
            return c.publicKey == "pk-lf-e2e-\(seeded.tag)" && c.secretKeySet
        }
        page(app, convos) { SettingsLangfuse() }
        await waitFor("the rebuilt page doesn't show the saved key") { self.field(holding: "pk-lf-e2e-\(seeded.tag)") != nil }
        await waitForText("secret saved")
    }

    func testEmbedderConnectionSaves() async throws {
        let (app, convos, seeded) = try await signedIn()
        page(app, convos) { SettingsEmbedder() }
        await waitFor("the page never loaded", timeout: 10) { self.field(holding: "nomic-embed-text") != nil }
        await type("e2e-embed-\(seeded.tag)", into: try XCTUnwrap(field(holding: "nomic-embed-text")))
        await press("Save")
        await eventually("the embedder never reached the server") {
            let c = try await app.client.embedder.get()
            return c.model == "e2e-embed-\(seeded.tag)"
        }
        page(app, convos) { SettingsEmbedder() }
        await waitFor("the rebuilt page doesn't show the model") { self.field(holding: "e2e-embed-\(seeded.tag)") != nil }
    }

    func testSpeechVoiceSaves() async throws {
        let (app, convos, seeded) = try await signedIn()
        page(app, convos) { SettingsSpeech() }
        await waitForText("voice")
        await spin(0.5)
        let voiceField = try XCTUnwrap(textFields().first { $0.accessibilityLabel == "Voice" } ?? textFields().first)
        await type("e2e-voice-\(seeded.tag)", into: voiceField)
        await press("Save")
        await eventually("the voice never reached the server") {
            try await app.client.speech.get().voice == "e2e-voice-\(seeded.tag)"
        }
        page(app, convos) { SettingsSpeech() }
        await waitFor("the rebuilt page doesn't show the voice") { self.field(holding: "e2e-voice-\(seeded.tag)") != nil }
    }

    /// Usage reads spend back per provider; a reply on the seeded
    /// provider puts it on the page.
    func testUsageShowsTheProviderWithReplies() async throws {
        let (app, convos, seeded) = try await signedIn()
        let conv = try await makeConversation(app, seeded, title: "Usage")
        try await seedTurn(app, conv, "echo copper")
        page(app, convos) { SettingsUsage() }
        await waitFor("the provider with the reply isn't listed", timeout: 10) {
            self.labels().contains { $0.contains(seeded.provider.label) }
        }
        await waitForText("1 turn")
    }

    /// The folder itself is chosen in the system document picker, which a
    /// headless test can't drive; the page's server half (the device-tool
    /// activity list) loads.
    func testFilesAndDeviceToolsLoads() async throws {
        let (app, convos, _) = try await signedIn()
        page(app, convos) { SettingsFiles() }
        await waitForText("folder")
    }
}
