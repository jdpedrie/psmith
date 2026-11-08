import Foundation
import SwiftUI
import UIKit
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// The conversation pages' board content (ConversationInfo, InfoSettings,
/// InfoPlugins, CallSettingsPage, ModelPicker, FullTextPage, ImageViewer).
@MainActor
enum PagesBoard {
    static let anthropic = "provider-anthropic"
    static let openai = "provider-openai"
    static let google = "provider-google"
    static let lmstudio = "provider-lmstudio"

    static func profile(_ base: PsmithProfile, callSettings: PsmithCallSettings?) -> PsmithProfile {
        PsmithProfile(
            id: base.id, name: base.name, description: base.description, parentOnly: false, favorite: false,
            isDefault: false, parentProfileID: nil, systemMessage: nil, defaultUserMessage: nil,
            compressionGuide: nil, compressionMode: nil, compressionProviderID: nil, compressionModelID: nil,
            defaultSettings: PsmithProfileDefaults(defaultProviderID: anthropic, defaultModelID: "claude-opus-4-7",
                                                   callSettings: callSettings),
            titleProviderID: nil, titleModelID: nil, titleGuide: nil, titleProviderKind: nil,
            createdAt: Board.now, updatedAt: Board.now
        )
    }

    /// Demo, carrying the profile layer the InfoSettings board reads out.
    static var demo: PsmithProfile {
        profile(Board.demo, callSettings: PsmithCallSettings(topP: 0.95, maxOutputTokens: 16_384,
                                                             stopSequences: ["###", "END"]))
    }

    static func model(_ provider: String, _ id: String, _ name: String, window: Int32, input: Double, output: Double,
                      modalities: [String] = ["text"], thinking: Bool = false,
                      defaults: PsmithCallSettings? = nil) -> PsmithUserModel {
        PsmithUserModel(
            providerID: provider, modelID: id, displayName: name, contextWindow: window, maxOutputTokens: 8_192,
            pricing: PsmithModelPricing(inputPerMillion: input, outputPerMillion: output,
                                        cacheReadPerMillion: nil, cacheWritePerMillion: nil),
            knowledgeCutoff: nil, modalities: modalities,
            capabilities: PsmithModelCapabilities(streaming: true, thinking: thinking, toolUse: true, vision: true,
                                                  promptCaching: true),
            favorite: false, defaultSettings: defaults
        )
    }

    static var models: [PsmithUserModel] {
        [
            model(anthropic, "claude-opus-4-7", "Claude Opus 4.7", window: 200_000, input: 15, output: 75,
                  thinking: true, defaults: PsmithCallSettings(explicitCache: false)),
            model(anthropic, "claude-haiku-4-5", "Claude Haiku 4.5", window: 200_000, input: 1, output: 5),
            model(openai, "gpt-5.1", "GPT-5.1", window: 400_000, input: 1.25, output: 10),
            model(google, "gemini-3-pro", "Gemini 3 Pro", window: 1_000_000, input: 2, output: 12,
                  modalities: ["text", "image", "audio"], thinking: true),
            model(google, "gemini-3-flash", "Gemini 3 Flash", window: 1_000_000, input: 0.30, output: 2.50,
                  modalities: ["text", "image"]),
            model(lmstudio, "qwen3-coder-30b", "qwen3-coder-30b", window: 128_000, input: 0, output: 0),
        ]
    }

    static let labels = [anthropic: "Anthropic", openai: "OpenAI", google: "Google", lmstudio: "LM Studio"]
    static let types = [anthropic: "anthropic", openai: "openai-compatible", google: "google", lmstudio: "openai-compatible"]

    static var conversation: PsmithConversation {
        Board.conversation("c-scroll", "Scroll architecture review", Board.demo, at: Board.today(10, 42))
    }

    static var contexts: [PsmithContext] {
        [
            SnapshotFixtures.context(id: "ctx-c-scroll", conversationID: "c-scroll", parentContextID: "ctx-c-scroll-1",
                                     createdAt: Board.today(9, 0), messageCount: 36, lastMessageTotalTokens: 82_140,
                                     cumulativeCostUsd: 0.42),
            SnapshotFixtures.context(id: "ctx-c-scroll-1", conversationID: "c-scroll", createdAt: Board.daysAgo(1),
                                     messageCount: 92, lastMessageTotalTokens: 151_000, cumulativeCostUsd: 1.92),
        ]
    }

    /// Fourteen messages on the current path, replies 91% cache hits, and
    /// three versions of message 14.
    static var path: [PsmithMessage] {
        (1...14).map { i in
            let id = String(format: "m%02d", i)
            let parent = i == 1 ? nil : String(format: "m%02d", i - 1)
            if i % 2 == 1 {
                return PsmithMessage(id: id, contextID: "ctx-c-scroll", parentID: parent, role: .user, content: "Question \(i)")
            }
            let model = i == 12 ? "gpt-5.1" : (i == 10 ? "claude-haiku-4-5" : "claude-opus-4-7")
            let provider = i == 12 ? openai : anthropic
            return PsmithMessage(id: id, contextID: "ctx-c-scroll", parentID: parent, role: .assistant,
                                 content: "Answer \(i)", providerID: provider, modelID: model,
                                 usage: PsmithMessageUsage(inputTokens: 100, outputTokens: 40, cacheReadTokens: 1_010))
        }
    }

    static var tree: [PsmithMessage] {
        path + ["m14a", "m14b"].map {
            PsmithMessage(id: $0, contextID: "ctx-c-scroll", parentID: "m13", role: .assistant, content: "Alt")
        }
    }

    static func pluginType(_ name: String, _ display: String) -> PsmithPluginType {
        PsmithPluginType(name: name, displayName: display, description: "",
                         capabilities: PsmithPluginCapabilities(configurable: false, systemPrompter: true,
                                                                outgoingUserTransformer: false, historyTransformer: false,
                                                                chunkTransformer: false, displayTransformer: false,
                                                                toolProvider: false),
                         configFields: [])
    }

    static func viewModel(draft: PsmithCallSettings = PsmithCallSettings(temperature: 0.7,
                                                                         thinking: PsmithThinkingSettings(effort: .high)))
        -> ConversationViewModel {
        let vm = SnapshotStubs.makeConversationViewModel(
            conversation: conversation, messages: path, contexts: contexts, availableModels: models,
            providerLabels: labels, providerTypes: types, selectedProviderID: anthropic,
            selectedModelID: "claude-opus-4-7", tokenCount: 82_140, contextWindow: 200_000,
            conversationCallSettingsDraft: draft,
            resolvedCallSettings: PsmithCallSettings(temperature: 1.0, topP: 0.95, maxOutputTokens: 16_384,
                                                     stopSequences: ["###", "END"],
                                                     thinking: PsmithThinkingSettings(effort: .medium),
                                                     explicitCache: false),
            settingsResolvedProfile: demo
        )
        vm.activeContext = contexts[0]
        vm.treeMessages = tree
        vm.resolvedPluginPipeline = [
            PsmithResolvedPipelineEntry(pluginName: "basic_grounding", ordinal: 0, config: Data(), source: .profile),
            PsmithResolvedPipelineEntry(pluginName: "memory", ordinal: 1, config: Data(), source: .profile),
            PsmithResolvedPipelineEntry(pluginName: "brave_search", ordinal: 2, config: Data(), source: .conversation),
            PsmithResolvedPipelineEntry(pluginName: "mcp", ordinal: 3, config: Data(), source: .profile),
        ]
        vm.conversationPluginOverrides = [
            PsmithConversationPlugin(pluginName: "brave_search", ordinal: 0, config: Data(), disabled: false),
            PsmithConversationPlugin(pluginName: "lettered_choices", ordinal: 1, config: Data(), disabled: true),
        ]
        vm.registeredPluginTypes = [
            pluginType("basic_grounding", "Basic grounding"), pluginType("memory", "Memory"),
            pluginType("brave_search", "Brave search"), pluginType("mcp", "MCP tools"),
            pluginType("lettered_choices", "Lettered choices"),
        ]
        return vm
    }

    static func app() -> AppModel {
        let app = SnapshotStubs.makeAppModel(models: models, profiles: [demo] + [Board.chief, Board.pirate])
        return app
    }

    static let fullText = """
    # Scroll trace, 400-message run

    One line per layout pass, captured on an iPhone 16 Pro with the eager stack. Times are wall clock; dy is the change in content offset.

    ## Stream start

    The streaming row clips at one viewport. Content stops growing once the reply fills it, so dy stays at zero.

    ```
    09:41:01.902 send id=u_8f20
    09:41:01.950 stream start id=m_8f21
    09:41:02.114 layout pass rows=412 dy=0
    09:41:02.131 stream chunk len=184
    09:41:02.148 layout pass rows=412 dy=0
    ```

    ## Stream end

    The clip releases and nothing re-pins. 120 ms later the reply's top scrolls into view; 250 ms after that, following resumes because the gap is under 32 points.

    - No layout pass touched rows above the viewport.
    - Largest single dy was 0 across 1,904 passes.
    """

    /// A stand-in screenshot: 390 by 330, the board's slate gradient (or
    /// the light twin's pale one).
    static func image(dark: Bool) -> UIImage {
        let size = CGSize(width: 390, height: 330)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let hex: [UInt32] = dark ? [0x2A3A4E, 0x1C2836] : [0xC9D5E3, 0xDCE5EF]
            let colors = hex.map { UIColor(red: CGFloat($0 >> 16) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255,
                                           blue: CGFloat($0 & 0xFF) / 255, alpha: 1).cgColor }
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }
}

/// Mounts a page pushed one level deep, so the system bar draws its back
/// button the way it does in the app.
struct PushedHost<Page: View>: View {
    @ViewBuilder let page: () -> Page
    var body: some View {
        NavigationStack(path: .constant([0])) {
            Color.clear.navigationDestination(for: Int.self) { _ in page() }
        }
    }
}
