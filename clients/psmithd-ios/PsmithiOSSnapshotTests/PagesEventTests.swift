import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// A view mounted in a live offscreen window, driven through its
/// accessibility elements: activating one runs the real control's action.
@MainActor
final class LiveHost {
    let window: UIWindow

    /// SwiftUI only builds its accessibility tree for an assistive client;
    /// automation mode is the one UI-testing tools turn on.
    private static let automation: Void = {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let f = dlsym(h, "_AXSSetAutomationEnabled") else { return }
        typealias Fn = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: Fn.self)(1)
    }()

    init<V: View>(_ view: V) {
        _ = Self.automation
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.environment(\.theme, .slate))
        window.isHidden = false
        settle()
    }

    deinit { MainActor.assumeIsolated { window.isHidden = true } }

    func settle(_ turns: Int = 8) {
        for _ in 0..<turns { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        window.layoutIfNeeded()
    }

    /// Spins until `cond` holds or a second passes.
    func wait(_ cond: () -> Bool) {
        for _ in 0..<40 where !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
    }

    /// The control with this label, over any plain text that shares it
    /// (a switch is labelled with its row's title).
    func element(_ label: String) -> NSObject? {
        var hits: [NSObject] = []
        Self.collect(window, label, &hits)
        return hits.first { !$0.accessibilityTraits.contains(.staticText) } ?? hits.first
    }

    func exists(_ label: String) -> Bool { element(label) != nil }

    @discardableResult
    func activate(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let e = element(label) else {
            XCTFail("No element labelled \(label)", file: file, line: line)
            return false
        }
        let ok = e.accessibilityActivate()
        settle()
        return ok
    }

    private static func collect(_ node: NSObject, _ label: String, _ hits: inout [NSObject], depth: Int = 0) {
        guard depth < 60 else { return }
        if node.isAccessibilityElement, node.accessibilityLabel == label { hits.append(node) }
        var children: [NSObject] = []
        if let elems = node.accessibilityElements as? [NSObject] {
            children = elems
        } else {
            let n = node.accessibilityElementCount()
            if n != NSNotFound && n > 0 {
                children = (0..<n).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if let v = node as? UIView { children += v.subviews }
        for c in children { collect(c, label, &hits, depth: depth + 1) }
    }
}

@MainActor
@Observable
final class SettingsBox {
    var settings: PsmithCallSettings
    init(_ s: PsmithCallSettings) { settings = s }
}

private struct FormHost: View {
    @Bindable var box: SettingsBox
    var body: some View {
        ScrollView {
            IKCallSettingsForm(settings: $box.settings, inherited: PsmithCallSettings(temperature: 1.0),
                               driverType: "anthropic", style: .page)
                .padding(.horizontal, 16)
        }
    }
}

@MainActor
final class PagesEventTests: XCTestCase {
    private func env<V: View>(_ v: V) -> some View {
        let app = PagesBoard.app()
        let convos = SnapshotStubs.makeConversationsModel(client: app.client, conversations: [PagesBoard.conversation],
                                                         profiles: Board.profiles)
        return NavigationStack { v }.environment(app).environment(convos)
    }

    /// Call settings: Revert drops the staged edit; Save hands it to the
    /// conversation and the bar goes away.
    func testCallSettingsSaveBarRevertAndSave() {
        let saved = PsmithCallSettings(thinking: PsmithThinkingSettings(effort: .high))
        var staged = saved
        staged.temperature = 0.7

        let vm = PagesBoard.viewModel(draft: saved)
        let live = LiveHost(env(CallSettingsScreen(model: vm, autoload: false, draft: staged)))
        XCTAssertTrue(live.exists("Revert"))
        live.activate("Revert")
        XCTAssertFalse(live.exists("Revert"), "Revert should clear the staged change and hide the bar")
        XCTAssertNil(vm.conversationCallSettingsDraft.temperature)

        let vm2 = PagesBoard.viewModel(draft: saved)
        let live2 = LiveHost(env(CallSettingsScreen(model: vm2, autoload: false, draft: staged)))
        live2.activate("Save")
        live2.wait { vm2.conversationCallSettingsDraft.temperature != nil }
        XCTAssertEqual(vm2.conversationCallSettingsDraft.temperature, 0.7)
        XCTAssertFalse(live2.exists("Revert"))
    }

    /// The reset beside an overridden field returns it to inherited.
    func testOverrideReset() {
        let box = SettingsBox(PsmithCallSettings(temperature: 0.7, topP: 0.5))
        let live = LiveHost(FormHost(box: box))
        live.activate("Reset to inherited (1.00)")
        XCTAssertNil(box.settings.temperature)
        XCTAssertEqual(box.settings.topP, 0.5, "Only the field reset should change")
    }

    /// Picking a model selects it for the conversation.
    func testModelSelection() {
        let vm = PagesBoard.viewModel()
        let live = LiveHost(env(ModelPickerScreen(model: vm)))
        live.activate("Gemini 3 Flash")
        live.wait { vm.selectedModelID == "gemini-3-flash" }
        XCTAssertEqual(vm.selectedModelID, "gemini-3-flash")
        XCTAssertEqual(vm.selectedProviderID, PagesBoard.google)
    }

    /// Deleting a past context confirms in place; Cancel backs out, Delete
    /// asks the server.
    func testContextDeleteConfirm() {
        let vm = PagesBoard.viewModel()
        let live = LiveHost(env(ScrollView { InfoContextTab(model: vm, confirmingContextDelete: "ctx-c-scroll-1") }))
        XCTAssertTrue(live.exists("Delete context 1?"))
        live.activate("Cancel")
        XCTAssertFalse(live.exists("Delete context 1?"))
        XCTAssertNil(vm.loadError)

        let vm2 = PagesBoard.viewModel()
        let live2 = LiveHost(env(ScrollView { InfoContextTab(model: vm2, confirmingContextDelete: "ctx-c-scroll-1") }))
        live2.activate("Delete")
        XCTAssertFalse(live2.exists("Delete context 1?"))
        // The stub server can't be reached, so a delete that went out comes
        // back as an error.
        live2.wait { vm2.loadError != nil }
        XCTAssertNotNil(vm2.loadError, "Delete should have called the server")
    }

    /// Plugins: a switch stages a change behind the save bar; Revert drops
    /// it, Save applies it.
    func testPluginSaveBar() {
        let vm = PagesBoard.viewModel()
        let staging = PluginStaging()
        let live = LiveHost(env(ConversationInfoScreen(model: vm, tab: .plugins, autoload: false, staging: staging)))
        XCTAssertFalse(live.exists("Revert"))
        live.activate("Memory")
        XCTAssertEqual(staging.pending(vm), ["memory"])
        XCTAssertTrue(live.exists("1 unsaved change"))
        live.activate("Revert")
        XCTAssertTrue(staging.pending(vm).isEmpty)
        XCTAssertFalse(live.exists("Revert"))

        live.activate("Memory")
        live.activate("Save")
        live.wait { !staging.saving && staging.staged.isEmpty }
        XCTAssertTrue(staging.staged.isEmpty)
        // The stub never loaded overrides, so the write is refused with this
        // message rather than sent: proof the save reached the model.
        XCTAssertNotNil(vm.settingsError)
    }

    /// Provider defaults: Revert puts the saved layer back.
    func testProviderDefaultsRevert() {
        let saved = PsmithCallSettings(maxOutputTokens: 8_192)
        let p = ModelsBoard.provider("provider-anthropic", "anthropic", "Anthropic", defaults: saved)
        let app = ModelsBoard.app()
        app.providers.providers[0] = p
        var staged = saved
        staged.temperature = 0.4
        let live = LiveHost(NavigationStack { ProviderDefaultsScreen(provider: p, draft: staged) }.environment(app))
        XCTAssertTrue(live.exists("1 unsaved change"))
        live.activate("Revert")
        XCTAssertFalse(live.exists("1 unsaved change"))
    }
}
