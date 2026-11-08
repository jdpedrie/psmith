import SwiftUI
import UIKit
import Darwin
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Mounts a view in a real window and drives its controls through the
/// accessibility tree, the same path VoiceOver and UI tests use, so a test
/// presses the actual Button rather than calling its closure.
@MainActor
final class IKEventHost {
    let window: UIWindow

    /// SwiftUI builds its accessibility tree only once something asks for
    /// it; this is the switch VoiceOver and Accessibility Inspector flip.
    private static let enableAccessibility: Void = {
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let sym = dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") else { return }
        typealias SetEnabled = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: SetEnabled.self)(true)
    }()

    init<V: View>(_ view: V) {
        _ = Self.enableAccessibility
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.environment(\.theme, .slate))
        window.isHidden = false
        settle()
    }

    deinit { MainActor.assumeIsolated { window.isHidden = true } }

    func settle() {
        window.layoutIfNeeded()
        for _ in 0..<16 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func elements(in root: NSObject) -> [NSObject] {
        var out: [NSObject] = []
        var queue: [NSObject] = [root]
        var seen = Set<ObjectIdentifier>()
        while let node = queue.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            // Reused list cells linger hidden with their old content.
            if let view = node as? UIView, view.isHidden || view.alpha == 0 { continue }
            out.append(node)
            if let view = node as? UIView { queue.append(contentsOf: view.subviews) }
            if let els = node.accessibilityElements as? [NSObject] { queue.append(contentsOf: els) }
            let n = node.accessibilityElementCount()
            if n != NSNotFound, n > 0 {
                for i in 0..<n { if let e = node.accessibilityElement(at: i) as? NSObject { queue.append(e) } }
            }
        }
        return out
    }

    func labels() -> [String] {
        elements(in: window).compactMap { $0.isAccessibilityElement ? $0.accessibilityLabel : nil }
    }

    func has(_ label: String) -> Bool { labels().contains(label) }

    /// Activates the accessibility element with exactly this label.
    @discardableResult
    func press(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let match = elements(in: window).first { $0.isAccessibilityElement && $0.accessibilityLabel == label }
        guard let match else {
            XCTFail("No control labelled “\(label)”. Have: \(labels())", file: file, line: line)
            return false
        }
        let ok = match.accessibilityActivate()
        settle()
        return ok
    }
}

@MainActor
final class SettingsEventTests: XCTestCase {
    // MARK: Save bar

    func testPluginConfigSaveBarRevertRestoresStoredSettings() {
        let draft = PluginGlobalsDraft()
        draft.seed(stored: Data(#"{"api_key":"old"}"#.utf8), plugin: SettingsBoard.brave)
        draft.draft["api_key"] = "new"
        var saves = 0
        let host = IKEventHost(SettingsPushed {
            SettingsPluginConfigScreen(plugin: SettingsBoard.brave, draft: draft, loaded: true, saving: false,
                                       saveError: nil, onRetry: {}, onSave: { saves += 1 })
        }.settingsEnvironment(SettingsBoard.app()))

        XCTAssertTrue(host.has("1 unsaved change"))
        host.press("Revert")
        XCTAssertEqual(draft.draft["api_key"] as? String, "old")
        XCTAssertEqual(draft.changeCount, 0)
        XCTAssertFalse(host.has("Save"), "the bar leaves once nothing is unsaved")
        XCTAssertEqual(saves, 0)
    }

    func testPluginConfigSaveBarSaveCallsSaveAndKeepsDraft() {
        let draft = PluginGlobalsDraft()
        draft.seed(stored: Data(#"{"api_key":"old"}"#.utf8), plugin: SettingsBoard.brave)
        draft.draft["api_key"] = "new"
        var saves = 0
        let host = IKEventHost(SettingsPushed {
            SettingsPluginConfigScreen(plugin: SettingsBoard.brave, draft: draft, loaded: true, saving: false,
                                       saveError: nil, onRetry: {}, onSave: { saves += 1; draft.markSaved() })
        }.settingsEnvironment(SettingsBoard.app()))

        host.press("Save")
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(draft.draft["api_key"] as? String, "new")
        XCTAssertEqual(draft.changeCount, 0)
    }

    func testProfileSaveBarRevertUndoesEveryField() {
        let draft = SettingsBoard.demoDraft()
        XCTAssertEqual(draft.changeCount, 2)
        let host = IKEventHost(SettingsPushed { SettingsProfileScreen(draft: draft, onSave: {}) }
            .settingsEnvironment(SettingsBoard.app()))
        XCTAssertTrue(host.has("2 unsaved changes"))
        host.press("Revert")
        XCTAssertEqual(draft.changeCount, 0)
        XCTAssertEqual(draft.fields, ProfileFields(SettingsBoard.demo))
    }

    // MARK: Confirm in place

    func testServerDeleteConfirmsInPlace() {
        var deleted = 0
        let host = IKEventHost(SettingsPushed {
            ServerDetailHarness(onDelete: { deleted += 1 })
        }.settingsEnvironment(SettingsBoard.app()))

        host.press("Delete server")
        XCTAssertEqual(deleted, 0, "the first tap only asks")
        XCTAssertTrue(host.has("Delete Linear?"))
        host.press("Cancel")
        XCTAssertFalse(host.has("Delete Linear?"))
        host.press("Delete server")
        host.press("Delete")
        XCTAssertEqual(deleted, 1)
    }

    func testRemoveAccountConfirm() {
        var removed: [UUID] = []
        let target = SettingsBoard.accounts[1]
        let host = IKEventHost(SettingsPushed {
            AccountsHarness(confirming: target.id, onRemove: { removed.append($0) })
        }.settingsEnvironment(SettingsBoard.app()))

        XCTAssertTrue(host.has("Remove jdp · lab.psmith.dev?"))
        host.press("Cancel")
        XCTAssertTrue(removed.isEmpty)
        XCTAssertFalse(host.has("Remove jdp · lab.psmith.dev?"))
        XCTAssertTrue(host.has("Switch to jdp"), "cancel puts the row back")
    }

    func testRemoveAccountConfirmRemovesThatAccount() {
        var removed: [UUID] = []
        let target = SettingsBoard.accounts[1]
        let host = IKEventHost(SettingsPushed {
            AccountsHarness(confirming: target.id, onRemove: { removed.append($0) })
        }.settingsEnvironment(SettingsBoard.app()))

        host.press("Remove")
        XCTAssertEqual(removed, [target.id])
    }

    // MARK: Switches

    func testNotificationSwitchToggles() {
        let state = SwitchState()
        let host = IKEventHost(SettingsPushed {
            NotificationsHarness(state: state)
        }.settingsEnvironment(SettingsBoard.app()))

        host.press("Notify when a reply finishes")
        XCTAssertTrue(state.on)
        host.press("Notify when a reply finishes")
        XCTAssertFalse(state.on)
    }

    func testTurningOffAnInheritedPluginAddsADisabledRow() {
        let draft = SettingsBoard.demoDraft()
        draft.revert()
        draft.seedPlugins([])
        let host = IKEventHost(SettingsPushed {
            SettingsProfilePluginsScreen(draft: draft, configTarget: .constant(nil))
        }.settingsEnvironment(SettingsBoard.app()))

        host.press("Memory")
        XCTAssertEqual(draft.plugins.map(\.pluginName), ["memory"])
        XCTAssertEqual(draft.plugins.first?.disabled, true)
        XCTAssertEqual(draft.changeCount, 1)
        host.press("Memory")
        XCTAssertTrue(draft.plugins.isEmpty, "turning it back on drops the override")
    }
}

@Observable
@MainActor
private final class SwitchState { var on = false }

private struct NotificationsHarness: View {
    let state: SwitchState
    var body: some View {
        SettingsNotificationsScreen(isOn: Binding(get: { state.on }, set: { state.on = $0 }),
                                    permission: .allowed, openSettings: {})
    }
}

private struct ServerDetailHarness: View {
    let onDelete: () -> Void
    @State private var confirming = false
    var body: some View {
        SettingsServerDetailScreen(server: SettingsBoard.linearServer, state: nil, error: nil,
                                   confirmingDelete: $confirming, onTest: {}, onDelete: onDelete)
    }
}

private struct AccountsHarness: View {
    @State var confirming: UUID?
    let onRemove: (UUID) -> Void
    var body: some View {
        SettingsAccountsScreen(items: SettingsBoard.accounts, activeName: "John", confirmingRemove: $confirming,
                               onSwitch: { _ in }, onRemove: onRemove, onSignOut: {})
    }
}
