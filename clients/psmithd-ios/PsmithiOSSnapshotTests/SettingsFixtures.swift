import Foundation
import SwiftUI
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The Settings boards' content. Profile ids are picked so ProfileColor
/// lands each on its board dot.
@MainActor
enum SettingsBoard {
    static let chief = profile("p-chief-4", "Chief of staff", favorite: true, isDefault: true)
    static let shared = profile("p-shared-1", "Shared defaults", parentOnly: true)
    static let coding = profile("p-coding-2", "Coding", parent: "p-shared-1")
    static let council = profile("p-council-3", "Council")
    static let demo = profile("p-demo-7", "Demo", parent: "p-chief-4",
                              system: "You are a senior iOS engineer reviewing architecture. Answer with the decision first, then the reason.",
                              compression: "claude-opus-4-7",
                              callSettings: PsmithCallSettings(temperature: 0.4, maxOutputTokens: 4_096))
    static let pirate = profile("p-pirate-0", "Pirate tutor", parent: "p-shared-1")
    static var profiles: [PsmithProfile] { [chief, coding, council, demo, pirate, shared] }

    static func profile(_ id: String, _ name: String, favorite: Bool = false, isDefault: Bool = false,
                        parentOnly: Bool = false, parent: String? = nil, system: String? = nil,
                        compression: String? = nil, callSettings: PsmithCallSettings? = nil) -> PsmithProfile {
        PsmithProfile(
            id: id, name: name, parentOnly: parentOnly, favorite: favorite, isDefault: isDefault,
            parentProfileID: parent, systemMessage: system,
            compressionProviderID: compression == nil ? nil : "provider-anthropic", compressionModelID: compression,
            defaultSettings: PsmithProfileDefaults(defaultProviderID: "provider-anthropic", defaultModelID: "claude-opus-4-7",
                                                   callSettings: callSettings),
            titleProviderID: "provider-anthropic", titleModelID: "claude-haiku-4-5"
        )
    }

    /// Usage's four providers, 22 models between them.
    static let providers: [PsmithUserModelProvider] = [
        SnapshotFixtures.userModelProvider(),
        SnapshotFixtures.userModelProvider(id: "provider-openai", type: "openai-compatible", label: "OpenAI"),
        SnapshotFixtures.userModelProvider(id: "provider-google", type: "google", label: "Google AI"),
        SnapshotFixtures.userModelProvider(id: "provider-lmstudio", type: "openai-compatible", label: "LM Studio"),
    ]

    static var models: [PsmithUserModel] {
        var out = [
            SnapshotFixtures.userModel(),
            SnapshotFixtures.userModel(modelID: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
        ]
        let rest: [(String, Int)] = [("provider-anthropic", 4), ("provider-openai", 7), ("provider-google", 5), ("provider-lmstudio", 4)]
        for (pid, n) in rest {
            for i in 0..<n {
                out.append(SnapshotFixtures.userModel(providerID: pid, modelID: "\(pid)-m\(i)", displayName: "Model \(i)"))
            }
        }
        return out
    }

    static func field(_ name: String, _ display: String, required: Bool = false, global: Bool = false,
                      type: PsmithConfigFieldType = .text) -> PsmithConfigField {
        PsmithConfigField(name: name, display: display, description: "", type: type, defaultJSON: "",
                          options: [], required: required, global: global)
    }

    static let grounding = PsmithPluginType(name: "basic_grounding", displayName: "Basic Grounding",
                                            description: "Date, time, and place in the system prompt",
                                            capabilities: .init(systemPrompter: true), configFields: [])
    static let memory = PsmithPluginType(name: "memory", displayName: "Memory",
                                         description: "Pulls older context back into long conversations",
                                         capabilities: .init(toolProvider: true), configFields: [])
    static let brave = PsmithPluginType(
        name: "brave_search", displayName: "Brave Search",
        description: "Gives the model a web_search tool backed by the Brave Search API.",
        capabilities: .init(configurable: true, toolProvider: true),
        configFields: [
            PsmithConfigField(name: "api_key", display: "API key",
                              description: "Brave Search subscription token. Get one at api.search.brave.com. Shared across every profile that uses this plugin.",
                              type: .text, defaultJSON: "", options: [], required: true, global: true),
            field("count", "Default result count", type: .number),
            field("safe", "Safe search"),
            field("country", "Country bias"),
        ])
    /// The config board's longer copy of the same plugin.
    static var braveFull: PsmithPluginType {
        PsmithPluginType(name: brave.name, displayName: brave.displayName,
                         description: brave.description + " Each call returns the top results for a query.",
                         capabilities: brave.capabilities, configFields: brave.configFields)
    }
    static let images = PsmithPluginType(name: "image_generation", displayName: "Image Generation",
                                         description: "Draws images from a prompt with an image model.",
                                         capabilities: .init(configurable: true, toolProvider: true),
                                         configFields: [field("model", "Image model", required: true, type: .modelPicker)])
    static let linear = PsmithPluginType(name: "mcp:linear", displayName: "Linear", description: "MCP server · 6 tools",
                                         capabilities: .init(toolProvider: true), configFields: [])
    static let builtins: [PsmithPluginType] = [
        grounding, brave,
        PsmithPluginType(name: "council", displayName: "Council", description: "", capabilities: .init(), configFields: []),
        images,
        PsmithPluginType(name: "lettered_choices", displayName: "Lettered Choices", description: "", capabilities: .init(), configFields: []),
        memory,
        PsmithPluginType(name: "text_injector", displayName: "Text Injector", description: "", capabilities: .init(), configFields: []),
    ]

    static let firecrawl = PsmithMCPServer(id: "mcp-firecrawl", name: "Firecrawl", transport: "stdio", command: "npx", hasEnv: true)
    static let linearServer = PsmithMCPServer(id: "mcp-linear", name: "Linear", transport: "http",
                                              url: "https://mcp.linear.app/mcp", toolPrefix: "linear_", hasHeaders: true)
    static let linearTools = ["linear_list_issues", "linear_get_issue", "linear_create_issue", "linear_update_issue",
                              "linear_list_projects", "linear_search_documentation"]

    static func app() -> AppModel {
        let app = SnapshotStubs.makeAppModel(
            providers: providers, models: models, profiles: profiles, connectivityState: .online)
        app.profiles.pluginTypes = builtins + [linear]
        app.profiles.profilePlugins = [
            chief.id: [PsmithProfilePlugin(pluginName: "basic_grounding", ordinal: 0, config: Data("{}".utf8)),
                       PsmithProfilePlugin(pluginName: "memory", ordinal: 1, config: Data("{}".utf8))],
        ]
        app.mcpServers.servers = [firecrawl, linearServer]
        app.mcpServers.testStates = [
            firecrawl.id: .result(PsmithMCPServerTestResult(ok: false, errorMessage: "exit status 1", toolNames: [])),
            linearServer.id: .result(PsmithMCPServerTestResult(ok: true, errorMessage: "", toolNames: linearTools)),
        ]
        return app
    }

    /// Demo's draft as the boards show it: two fields changed, three
    /// plugins of its own, Memory turned off.
    static func demoDraft() -> ProfileDraft {
        let d = ProfileDraft(profile: demo)
        d.fields.systemMessage = "You are a senior iOS engineer reviewing architecture. Answer with the decision first, then the reason. Cite file names when you have them."
        d.fields.compressionModelID = "claude-haiku-4-5"
        d.seedPlugins([
            PsmithProfilePlugin(pluginName: "memory", ordinal: 0, config: Data("{}".utf8), disabled: true),
            PsmithProfilePlugin(pluginName: "brave_search", ordinal: 1, config: Data("{}".utf8)),
            PsmithProfilePlugin(pluginName: "image_generation", ordinal: 2, config: Data("{}".utf8)),
            PsmithProfilePlugin(pluginName: "mcp:linear", ordinal: 3, config: Data("{}".utf8)),
        ])
        return d
    }

    static var rootSummary: SettingsRootSummary {
        var s = SettingsRootSummary()
        s.accountName = "John"
        s.accountHost = "psmith.home.arpa"
        s.accountCount = 3
        s.theme = "Slate Pro"
        s.notifications = "On"
        s.privacy = "Location off"
        s.fillCounts(from: app())
        s.usage = "$41.20 in Nov"
        s.langfuse = "On"
        s.langfuseDot = IK.green
        s.embedder = "On"
        s.speech = "OpenAI · alloy"
        s.files = "Vault"
        s.version = "Psmith fc76aa6 · Server 0.14.2"
        return s
    }

    static let accounts: [SettingsAccountItem] = [
        SettingsAccountItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "John",
                            host: "https://psmith.home.arpa", shortHost: "psmith.home.arpa", isActive: true, signedIn: true),
        SettingsAccountItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "jdp",
                            host: "https://lab.psmith.dev", shortHost: "lab.psmith.dev", isActive: false, signedIn: true),
        SettingsAccountItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, name: "demo",
                            host: "https://lab.local", shortHost: "lab.local", isActive: false, signedIn: true),
    ]

    static let costs: [PsmithProviderCost] = [
        PsmithProviderCost(providerID: "a", providerLabel: "Anthropic", providerType: "anthropic", totalCostUsd: 28.64, eventCount: 312),
        PsmithProviderCost(providerID: "o", providerLabel: "OpenAI", providerType: "openai-compatible", totalCostUsd: 9.85, eventCount: 96),
        PsmithProviderCost(providerID: "g", providerLabel: "Google AI", providerType: "google", totalCostUsd: 2.71, eventCount: 41),
        PsmithProviderCost(providerID: "l", providerLabel: "LM Studio", providerType: "openai-compatible", totalCostUsd: 0, eventCount: 0),
    ]

    static var now: Date { Board.now }
    static func today(_ h: Int, _ m: Int) -> Date { Board.today(h, m) }

    static var activity: [DeviceToolActivity] {
        let t = now
        return [
            DeviceToolActivity(id: "1", toolName: "calendar_list_events", status: "ok", input: Data("{}".utf8),
                               invokedAt: t.addingTimeInterval(-240), completedAt: t.addingTimeInterval(-239.82)),
            DeviceToolActivity(id: "2", toolName: "files_read_note", status: "error", errorMessage: "No note at Projects/Q4 plan.md",
                               input: Data(#"{"path": "Projects/Q4 plan.md"}"#.utf8),
                               invokedAt: t.addingTimeInterval(-720), completedAt: t.addingTimeInterval(-719.958)),
            DeviceToolActivity(id: "3", toolName: "reminders_create", status: "ok", input: Data("{}".utf8),
                               invokedAt: t.addingTimeInterval(-3600), completedAt: t.addingTimeInterval(-3599.69)),
            DeviceToolActivity(id: "4", toolName: "calendar_create_event", status: "timeout", input: Data("{}".utf8),
                               invokedAt: t.addingTimeInterval(-86_400), completedAt: t.addingTimeInterval(-86_370)),
        ]
    }
}

/// A page pushed onto a stack, so the system bar draws its back button.
struct SettingsPushed<Page: View>: View {
    @State private var path = [1]
    let page: Page
    init(@ViewBuilder _ page: () -> Page) { self.page = page() }
    var body: some View {
        NavigationStack(path: $path) {
            Color.clear.navigationDestination(for: Int.self) { _ in page }
        }
    }
}

extension View {
    /// Everything the Settings pages read from the environment.
    @MainActor
    func settingsEnvironment(_ app: AppModel) -> some View {
        let themes = ThemeStore()
        themes.current = .slate
        let accounts = AccountManager(store: AccountStore(defaults: UserDefaults(suiteName: "psmith-snap-settings")!))
        return self
            .environment(app)
            .environment(accounts)
            .environment(themes)
            .environment(AppPreferences())
            .environment(iOSNavigator())
    }
}
