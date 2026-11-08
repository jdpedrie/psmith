import SwiftUI
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Settings › Models boards' content.
@MainActor
enum ModelsBoard {
    static func provider(_ id: String, _ type: String, _ label: String, defaults: PsmithCallSettings? = nil,
                         preset: String? = nil) -> PsmithUserModelProvider {
        PsmithUserModelProvider(id: id, type: type, label: label, createdAt: Board.now, updatedAt: Board.now,
                                defaultSettings: defaults, presetID: preset)
    }

    static var anthropic: PsmithUserModelProvider {
        provider("provider-anthropic", "anthropic", "Anthropic",
                 defaults: PsmithCallSettings(maxOutputTokens: 8_192, thinking: PsmithThinkingSettings(effort: .medium),
                                              anthropic: PsmithAnthropicExtras(cacheEnabled: true)))
    }

    static var providers: [PsmithUserModelProvider] {
        [anthropic, provider("provider-openai", "openai-compatible", "OpenAI", preset: "openai"),
         provider("provider-google", "google", "Google AI"),
         provider("provider-lmstudio", "openai-compatible", "LM Studio")]
    }

    static func model(_ id: String, _ name: String, window: Int32, input: Double, output: Double, thinks: Bool,
                      manual: Bool = false, caching: Bool = true, defaults: PsmithCallSettings? = nil,
                      cacheRead: Double? = nil, cacheWrite: Double? = nil, maxOutput: Int32? = nil) -> PsmithUserModel {
        PsmithUserModel(
            providerID: "provider-anthropic", modelID: id, displayName: name, contextWindow: window, maxOutputTokens: maxOutput,
            pricing: PsmithModelPricing(inputPerMillion: input, outputPerMillion: output,
                                        cacheReadPerMillion: cacheRead, cacheWritePerMillion: cacheWrite),
            knowledgeCutoff: nil, modalities: ["text", "image"],
            capabilities: PsmithModelCapabilities(streaming: true, thinking: thinks, toolUse: true, vision: true,
                                                  promptCaching: caching),
            favorite: false, defaultSettings: defaults, metadataSource: manual ? "manual" : "catalog")
    }

    static var enabled: [PsmithUserModel] {
        [model("claude-opus-4-7", "Claude Opus 4.7", window: 200_000, input: 15, output: 75, thinks: true),
         model("claude-sonnet-4-5", "Claude Sonnet 4.5", window: 1_000_000, input: 3, output: 15, thinks: true),
         model("claude-haiku-4-5", "Claude Haiku 4.5", window: 200_000, input: 1, output: 5, thinks: false)]
    }

    static func discovered(_ id: String, _ name: String, window: Int32, input: Double, output: Double, thinks: Bool,
                           on: Bool, caching: Bool = true) -> PsmithDiscoveredModel {
        PsmithDiscoveredModel(modelID: id, displayName: name, contextWindow: window,
                              pricing: PsmithModelPricing(inputPerMillion: input, outputPerMillion: output,
                                                          cacheReadPerMillion: nil, cacheWritePerMillion: nil),
                              capabilities: PsmithModelCapabilities(streaming: true, thinking: thinks, toolUse: true,
                                                                    vision: true, promptCaching: caching),
                              alreadyEnabled: on)
    }

    static var catalog: [PsmithDiscoveredModel] {
        [discovered("claude-opus-4-7", "Claude Opus 4.7", window: 200_000, input: 15, output: 75, thinks: true, on: true),
         discovered("claude-sonnet-4-5", "Claude Sonnet 4.5", window: 1_000_000, input: 3, output: 15, thinks: true, on: true),
         discovered("claude-haiku-4-5", "Claude Haiku 4.5", window: 200_000, input: 1, output: 5, thinks: false, on: true),
         discovered("claude-opus-4-1", "Claude Opus 4.1", window: 200_000, input: 15, output: 75, thinks: true, on: false),
         discovered("claude-sonnet-4-0", "Claude Sonnet 4", window: 200_000, input: 3, output: 15, thinks: true, on: false),
         discovered("claude-3-7-sonnet-latest", "Claude 3.7 Sonnet", window: 200_000, input: 3, output: 15, thinks: true,
                    on: false, caching: false)]
    }

    /// Everything the provider lists, for the provider page's "3 of 9".
    static var fullCatalog: [PsmithDiscoveredModel] {
        catalog + [
            discovered("claude-3-5-haiku-latest", "Claude 3.5 Haiku", window: 200_000, input: 0.8, output: 4, thinks: false, on: false),
            discovered("claude-3-opus-latest", "Claude 3 Opus", window: 200_000, input: 15, output: 75, thinks: false, on: false),
            discovered("claude-3-haiku-20240307", "Claude 3 Haiku", window: 200_000, input: 0.25, output: 1.25, thinks: false, on: false),
        ]
    }

    static var templates: [PsmithProviderTemplate] {
        [("groq", "Groq", "https://api.groq.com/openai/v1", "GROQ_API_KEY"),
         ("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "OPENROUTER_API_KEY"),
         ("deepseek", "DeepSeek", "https://api.deepseek.com", "DEEPSEEK_API_KEY"),
         ("xai", "xAI Grok", "https://api.x.ai/v1", "XAI_API_KEY"),
         ("mistral", "Mistral", "https://api.mistral.ai/v1", "MISTRAL_API_KEY"),
         ("together", "Together AI", "https://api.together.xyz/v1", "TOGETHER_API_KEY"),
         ("cerebras", "Cerebras", "https://api.cerebras.ai/v1", "CEREBRAS_API_KEY"),
         ("perplexity", "Perplexity", "https://api.perplexity.ai", "PERPLEXITY_API_KEY"),
         ("qwen", "Qwen", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "DASHSCOPE_API_KEY"),
         ("ollama", "Ollama (local)", "http://localhost:11434/v1", nil)]
            .map { PsmithProviderTemplate(catalogProviderID: $0.0, name: $0.1, driverType: "openai-compatible",
                                          apiBase: $0.2, envKey: $0.3, presetID: $0.0) }
            + [PsmithProviderTemplate(catalogProviderID: "anthropic", name: "Anthropic", driverType: "anthropic"),
               PsmithProviderTemplate(catalogProviderID: "google", name: "Google AI", driverType: "google")]
    }

    static func app() -> AppModel {
        let app = SnapshotStubs.makeAppModel(providers: providers, models: enabled, profiles: [PagesBoard.demo])
        app.providers.templates = templates
        app.providers.templatesLoaded = true
        app.providers.selectedID = "provider-anthropic"
        app.providers.enabledModels = enabled
        let ok = PsmithProviderTestResult(ok: true, errorMessage: "", modelCount: 9, latencyMs: 210)
        for id in ["provider-anthropic", "provider-openai", "provider-google"] { app.providers.providerTestStatus[id] = .success(ok) }
        app.providers.providerTestStatus["provider-lmstudio"] =
            .success(PsmithProviderTestResult(ok: false, errorMessage: "connection refused", modelCount: 0, latencyMs: 0))
        return app
    }

    static var counts: [String: Int] {
        ["provider-anthropic": 3, "provider-openai": 9, "provider-google": 6, "provider-lmstudio": 4]
    }
}

@MainActor
final class ModelsSettingsProbeTests: XCTestCase {
    private func host<V: View>(_ app: AppModel = ModelsBoard.app(), _ page: @escaping () -> V) -> some View {
        PushedHost(page: page).environment(app)
    }

    func testModelsList() {
        IKRender.shoot("SettingsModelsList") { host { ModelsSettingsScreen(counts: ModelsBoard.counts, autoload: false) } }
    }

    func testProvider() {
        IKRender.shoot("SettingsModels") {
            host {
                ModelsProviderScreen(provider: ModelsBoard.anthropic, discovered: ModelsBoard.fullCatalog,
                                     turnedOff: [ModelsBoard.model("claude-opus-4-1", "Claude Opus 4.1", window: 200_000,
                                                                   input: 15, output: 75, thinks: false)],
                                     confirmingRemove: true, autoload: false)
            }
        }
    }

    func testAddProvider() {
        IKRender.shoot("SettingsAddProvider") { host { ModelsAddProviderScreen() } }
    }

    func testProviderKey() {
        IKRender.shoot("SettingsProviderKey") {
            host {
                ModelsProviderKeyScreen(mode: .add(ModelsBoard.templates[0]), apiKey: "gsk_example_key_value_0000")
            }
        }
    }

    func testDiscover() {
        IKRender.shoot("SettingsDiscover") {
            host {
                ModelsDiscoverScreen(provider: ModelsBoard.anthropic, discovered: ModelsBoard.catalog,
                                     selected: ["claude-opus-4-1", "claude-sonnet-4-0"], autoload: false)
            }
        }
    }

    func testModelDetail() {
        let m = ModelsBoard.model("claude-opus-4-7-20251101", "Opus 4.7 (Nov snapshot)", window: 200_000, input: 15,
                                  output: 75, thinks: true, manual: true, caching: false,
                                  defaults: PsmithCallSettings(temperature: 0.7), cacheRead: 1.5, cacheWrite: 18.75,
                                  maxOutput: 32_000)
        IKRender.shoot("SettingsModelDetail") {
            host { ModelDetailScreen(provider: ModelsBoard.anthropic, mode: .edit(m), confirmingDelete: true) }
        }
    }

    func testProviderDefaults() {
        let saved = PsmithCallSettings(maxOutputTokens: 8_192, thinking: PsmithThinkingSettings(effort: .medium))
        let p = ModelsBoard.provider("provider-anthropic", "anthropic", "Anthropic", defaults: saved)
        var draft = saved
        draft.temperature = 0.7
        draft.anthropic = PsmithAnthropicExtras(cacheTTL: .oneHour)
        let app = ModelsBoard.app()
        app.providers.providers[0] = p
        IKRender.shoot("SettingsProviderDefaults") {
            host(app) { ProviderDefaultsScreen(provider: p, draft: draft) }
        }
    }

    func testProfileCallSettings() {
        IKRender.shoot("ProfileCallSettings") {
            let app = ModelsBoard.app()
            app.profiles.profiles = [PagesBoard.demo]
            app.profiles.availableModels = [ModelsBoard.model("claude-opus-4-7", "Claude Opus 4.7", window: 200_000,
                                                              input: 15, output: 75, thinks: true,
                                                              defaults: PsmithCallSettings(temperature: 1.0))]
            app.profiles.providerTypes = ["provider-anthropic": "anthropic"]
            return host(app) { ProfileCallSettingsScreen(profileID: PagesBoard.demo.id) }
        }
    }
}
