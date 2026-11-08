import SwiftUI
import CoreLocation
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Renders every Settings board with its own content, for comparison with
/// the Settings* boards and their Light twins.
@MainActor
final class SettingsProbeTests: XCTestCase {
    private func shoot<V: View>(_ name: String, app: AppModel = SettingsBoard.app(), _ page: @escaping () -> V) {
        IKRender.shoot(name) { SettingsPushed { page() }.settingsEnvironment(app) }
    }

    func testRoot() {
        shoot("SettingsRoot") { SettingsRootScreen(summary: SettingsBoard.rootSummary, search: .constant("")) }
    }

    func testAccounts() {
        shoot("SettingsAccounts") {
            SettingsAccountsScreen(items: SettingsBoard.accounts, activeName: "John",
                                   confirmingRemove: .constant(SettingsBoard.accounts[2].id),
                                   onSwitch: { _ in }, onRemove: { _ in }, onSignOut: {})
        }
    }

    func testGeneral() {
        shoot("SettingsGeneral") {
            SettingsGeneralScreen(warnTokens: 100_000, warnError: nil, onSetWarn: { _ in },
                                  usedBytes: Int(38.4 * 1_048_576), capMB: .constant(100), clearing: false,
                                  confirmingClear: .constant(true), onClear: {})
        }
    }

    func testAppearance() {
        shoot("SettingsAppearance") {
            SettingsAppearanceScreen(current: .slate, select: { _ in }, showTurnDetails: .constant(false))
        }
    }

    func testNotifications() {
        shoot("SettingsNotifications") {
            SettingsNotificationsScreen(isOn: .constant(true), permission: .denied, openSettings: {})
        }
    }

    func testPrivacy() {
        shoot("SettingsPrivacy") {
            SettingsPrivacyScreen(enabled: .constant(true), authorization: .authorizedWhenInUse, city: "Brooklyn, NY",
                                  coordinates: "40.68, −73.94", lastFix: SettingsBoard.now.addingTimeInterval(-120),
                                  openSettings: {}, now: SettingsBoard.now)
        }
    }

    func testUsage() {
        shoot("SettingsUsage") {
            SettingsUsageScreen(rows: SettingsBoard.costs, grandTotal: 41.20, loading: false, errorText: nil,
                                range: .constant(.month), customSince: .constant(.now), customUntil: .constant(.now))
        }
    }

    func testProfilesList() {
        let app = SettingsBoard.app()
        shoot("SettingsProfilesList", app: app) {
            SettingsProfilesListScreen(profiles: app.profiles, confirmingDelete: .constant(nil), onImport: {}, onDelete: { _ in })
        }
    }

    func testProfile() {
        let draft = SettingsBoard.demoDraft()
        shoot("SettingsProfile") { SettingsProfileScreen(draft: draft, onSave: {}) }
    }

    func testProfilePlugins() {
        let draft = SettingsBoard.demoDraft()
        shoot("SettingsProfilePlugins") { SettingsProfilePluginsScreen(draft: draft, configTarget: .constant(nil)) }
    }

    func testProfileShare() {
        let result = PsmithImportResult(profiles: [], warnings: [
            PsmithImportWarning(kind: .renamed, message: "Renamed. A profile called Pirate tutor already exists.", subject: "Pirate tutor"),
            PsmithImportWarning(kind: .providerMissing, message: "Needs a provider: OpenRouter.", subject: "openrouter"),
            PsmithImportWarning(kind: .mcpServerMissing, message: "Needs an MCP server: Firecrawl.", subject: "Firecrawl"),
        ], renamed: ["Pirate tutor 2"])
        let export = PsmithProfileExport(payload: Data("{}".utf8), suggestedFilename: "demo.psmithprofile",
                                         notices: ["The Brave Search API key and Linear's headers. Secrets stay on this server."])
        shoot("SettingsProfileShare") {
            SettingsProfileShareScreen(profile: SettingsBoard.demo, export: export, exporting: false, pendingImport: result,
                                       importFilename: "pirate-tutor.psmithprofile", importError: nil, hasChildren: false,
                                       confirmingDelete: .constant(true), onExport: {}, onPickImport: {},
                                       onCancelImport: {}, onConfirmImport: {}, onDelete: {})
        }
    }

    func testPlugins() {
        shoot("SettingsPlugins") {
            SettingsPluginsScreen(loaded: true, pluginTypes: SettingsBoard.builtins,
                                  servers: SettingsBoard.app().mcpServers.servers, error: nil,
                                  globals: { _ in Data() }, onRetry: {})
        }
    }

    func testPluginConfig() {
        let draft = PluginGlobalsDraft()
        draft.seed(stored: Data(), plugin: SettingsBoard.braveFull)
        draft.draft["api_key"] = "BSAk7Qx2mPq9Lr4TwZ8nVd"
        shoot("SettingsPluginConfig") {
            SettingsPluginConfigScreen(plugin: SettingsBoard.braveFull, draft: draft, loaded: true, saving: false,
                                       saveError: nil, onRetry: {}, onSave: {})
        }
    }

    func testServers() {
        let app = SettingsBoard.app()
        shoot("SettingsServers", app: app) {
            SettingsServersScreen(servers: app.mcpServers.servers, states: app.mcpServers.testStates, error: nil,
                                  confirmingDelete: .constant(nil), onDelete: { _ in }, onRetry: {})
        }
    }

    func testServerDetail() {
        let app = SettingsBoard.app()
        shoot("SettingsServerDetail", app: app) {
            SettingsServerDetailScreen(server: SettingsBoard.linearServer,
                                       state: app.mcpServers.testStates[SettingsBoard.linearServer.id],
                                       error: nil, confirmingDelete: .constant(true), onTest: {}, onDelete: {})
        }
    }

    func testAddServer() {
        var d = MCPServerDraft()
        d.name = "GitHub"
        d.url = "https://api.githubcopilot.com/mcp/"
        d.headers = "Authorization: Bearer ghp_••••••••••••"
        d.toolPrefix = "gh_"
        shoot("SettingsAddServer") {
            SettingsAddServerScreen(draft: .constant(d), editing: nil, saving: false, error: nil, onCancel: {}, onSave: {})
        }
    }

    func testLangfuse() {
        let saved = PsmithLangfuseConfig(host: "https://us.cloud.langfuse.com", publicKey: "pk-lf-7c2e41d9-0b3a",
                                         secretKeySet: true, enabled: true,
                                         lastEmittedAt: SettingsBoard.today(10, 42))
        shoot("SettingsLangfuse") {
            SettingsLangfuseScreen(host: .constant(saved.host), publicKey: .constant(saved.publicKey), secretKey: .constant(""),
                                   enabled: .constant(true), saved: saved, isDirty: false, saving: false, testing: false,
                                   deleting: false, saveError: nil,
                                   testResult: PsmithLangfuseTestResult(ok: true, errorMessage: "", latencyMs: 312),
                                   confirmingDelete: .constant(true), onSave: {}, onRevert: {}, onTest: {}, onDelete: {},
                                   now: SettingsBoard.today(10, 46))
        }
    }

    func testEmbedder() {
        let saved = PsmithEmbedderConfig(type: "openai", baseURL: "http://nas.local:11434/v1", model: "nomic-embed-text",
                                         dimensions: 1536, apiKeySet: false, enabled: true)
        shoot("SettingsEmbedder") {
            SettingsEmbedderScreen(type: .constant("openai"), baseURL: .constant(saved.baseURL), modelName: .constant(saved.model),
                                   dimensions: .constant(768), apiKey: .constant(""), enabled: .constant(true),
                                   availableTypes: ["openai"], saved: saved,
                                   stats: PsmithEmbedderStats(unembeddedCount: 1_204, workerActive: false),
                                   isDirty: true, saving: false, testing: false, deleting: false, saveError: nil,
                                   testResult: nil, confirmingDelete: .constant(false),
                                   onSave: {}, onRevert: {}, onTest: {}, onDelete: {})
        }
    }

    func testSpeech() {
        let saved = PsmithSpeechConfig(kind: "openai-compatible", voice: "alloy", model: "gpt-4o-mini-tts", speed: 1.0,
                                       apiKeySet: true)
        shoot("SettingsSpeech") {
            SettingsSpeechScreen(kind: .constant(saved.kind), voice: .constant("alloy"), modelName: .constant("gpt-4o-mini-tts"),
                                 speed: .constant(1.0), baseURL: .constant(""), apiKey: .constant(""), providerRef: .constant(""),
                                 autoSpeak: .constant(false), availableKinds: ["apple_local", "openai-compatible", "grok"],
                                 availableProviders: [SpeechProviderOption(id: "p1", label: "OpenAI")], saved: saved,
                                 isDirty: false, saving: false, testing: false, deleting: false, saveError: nil,
                                 testResult: SpeechTestOutcome(ok: true, errorMessage: "", latencyMs: 640, audioBytes: 18_432),
                                 confirmingReset: .constant(false), onSave: {}, onRevert: {}, onRemoveKey: {}, onTest: {}, onReset: {})
        }
    }

    func testFiles() {
        shoot("SettingsFiles") {
            SettingsFilesScreen(isBookmarked: true, displayPath: "Vault/Psmith", pickerError: nil,
                                confirmingForget: .constant(true), calls: SettingsBoard.activity, loading: false,
                                loadError: "Couldn’t load more: the request timed out.", atEnd: true,
                                onPick: {}, onForget: {}, onRetry: {}, onReachEnd: {}, now: SettingsBoard.now,
                                initiallyExpanded: ["2"])
        }
    }
}
