import SwiftUI
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Renders the conversation pages with their boards' content.
@MainActor
final class PagesProbeTests: XCTestCase {
    private func host<V: View>(_ vm: ConversationViewModel, _ page: @escaping () -> V) -> some View {
        let app = PagesBoard.app()
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: [PagesBoard.conversation],
                                                         profiles: Board.profiles)
        return PushedHost(page: page).environment(app).environment(convos)
    }

    func testConversationInfo() {
        IKRender.shoot("ConversationInfo") {
            let vm = PagesBoard.viewModel()
            return host(vm) { ConversationInfoScreen(model: vm, autoload: false) }
        }
    }

    func testInfoContextDelete() {
        IKRender.shoot("InfoContextDelete") {
            let vm = PagesBoard.viewModel()
            return host(vm) { InfoContextDeleteHost(model: vm) }
        }
    }

    func testInfoSettings() {
        IKRender.shoot("InfoSettings") {
            let vm = PagesBoard.viewModel()
            return host(vm) { ConversationInfoScreen(model: vm, tab: .settings, autoload: false) }
        }
    }

    func testInfoPlugins() {
        IKRender.shoot("InfoPlugins") {
            let vm = PagesBoard.viewModel()
            return host(vm) { ConversationInfoScreen(model: vm, tab: .plugins, autoload: false) }
        }
    }

    func testCallSettingsPage() {
        IKRender.shoot("CallSettingsPage") {
            let vm = PagesBoard.viewModel(draft: PsmithCallSettings(thinking: PsmithThinkingSettings(effort: .high)))
            return host(vm) {
                CallSettingsScreen(model: vm, autoload: false,
                                   draft: PsmithCallSettings(temperature: 0.7, thinking: PsmithThinkingSettings(effort: .high)))
            }
        }
    }

    func testModelPicker() {
        IKRender.shoot("ModelPicker") {
            let vm = PagesBoard.viewModel()
            return host(vm) { ModelPickerScreen(model: vm) }
        }
    }

    func testFullTextPage() {
        IKRender.shoot("FullTextPage") {
            let vm = PagesBoard.viewModel()
            return host(vm) { FullTextScreen(title: "Full text", markdown: PagesBoard.fullText) }
        }
    }

    func testImageViewer() {
        IKRender.shoot("ImageViewer") {
            let vm = PagesBoard.viewModel()
            return host(vm) {
                ImageViewerHost(model: vm)
            }
        }
    }
}

/// The Info page with context 1's delete confirm open.
private struct InfoContextDeleteHost: View {
    let model: ConversationViewModel
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                IKSegmented(options: [(ConversationInfoScreen.Tab.context, "Context"), (.settings, "Settings"), (.plugins, "Plugins")],
                            selection: .constant(.context))
                InfoContextTab(model: model, confirmingContextDelete: "ctx-c-scroll-1")
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
        }
        .ikConversationPage("Info")
    }
}

/// The viewer with the stand-in image for the current appearance.
private struct ImageViewerHost: View {
    let model: ConversationViewModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ImageViewerScreen(model: model, messageID: "m13", fileID: "f1", filename: "scroll-jump-before.png",
                          preloaded: PagesBoard.image(dark: scheme == .dark))
            .id(scheme)
    }
}
