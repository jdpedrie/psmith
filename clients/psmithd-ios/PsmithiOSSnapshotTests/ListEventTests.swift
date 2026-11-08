import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// Drives the list's in-place flows: a row's swipe action, then the real
/// confirm card buttons, rename field and selection bar, tapped through
/// accessibility activation.
/// The models point at an unroutable host, so a call into them surfaces as
/// `loadError`: that is how these tests see the model was called.
@MainActor
final class ListEventTests: XCTestCase {
    private var window: UIWindow?

    /// SwiftUI only builds its accessibility tree for an assistive client;
    /// turning on automation mode stands in for one.
    override class func setUp() {
        super.setUp()
        if let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
           let sym = dlsym(lib, "_AXSSetAutomationEnabled") {
            typealias SetEnabled = @convention(c) (Int32) -> Void
            unsafeBitCast(sym, to: SetEnabled.self)(1)
        }
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
    }

    private func mount(_ state: ListState, _ conversations: [PsmithConversation] = Shell.swipeList) -> ConversationsModel {
        let (app, convos) = ListFixture.models(conversations)
        let root = ListHost(state: state)
            .environment(app)
            .environment(convos)
            .environment(Shell.accounts(other: false))
            .environment(\.theme, .slate)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        w.rootViewController = UIHostingController(rootView: root)
        w.isHidden = false
        w.makeKey()
        window = w
        settle()
        return convos
    }

    // MARK: Delete confirm in place

    func testSwipeDeleteShowsConfirmAndCancelRestoresRow() throws {
        let state = ListState()
        let convos = mount(state)

        try swipeAction(.delete, on: "c-vacuum", state, convos)
        XCTAssertEqual(state.confirmingDelete, "c-vacuum")
        XCTAssertNotNil(element(labeled: "Cancel"), "the row turns into the confirm card")

        try tap("Cancel")
        XCTAssertNil(state.confirmingDelete)
        XCTAssertTrue(wait(timeout: 3) {
            elements().contains {
                $0.isAccessibilityElement && ($0.accessibilityLabel ?? "").hasPrefix("Postgres vacuum tuning")
            }
        }, "the row is back")
        XCTAssertNil(convos.loadError, "cancel touches nothing")
    }

    func testConfirmDeleteCallsModel() throws {
        let state = ListState()
        let convos = mount(state)

        try swipeAction(.delete, on: "c-vacuum", state, convos)
        try tap("Delete")
        XCTAssertNil(state.confirmingDelete)
        XCTAssertTrue(wait { convos.loadError != nil }, "Delete reached the model")
    }

    // MARK: Rename in place

    func testRenameInPlaceSubmitsTitle() throws {
        let state = ListState()
        let convos = mount(state)

        try swipeAction(.rename, on: "c-council", state, convos)
        XCTAssertEqual(state.renaming, "c-council")
        XCTAssertEqual(state.renameDraft, "Council: pricing debate", "the field starts with the title")

        let field = try XCTUnwrap(textField(showing: "Council: pricing debate"), "the row became a field")
        field.text = "Council: pricing for launch"
        field.sendActions(for: .editingChanged)
        settle()
        XCTAssertEqual(state.renameDraft, "Council: pricing for launch")

        // The return key: UIKit asks the delegate, then fires the
        // did-end-on-exit action SwiftUI's onSubmit listens to.
        if field.delegate?.textFieldShouldReturn?(field) ?? true {
            field.sendActions(for: .editingDidEndOnExit)
        }
        settle()
        XCTAssertNil(state.renaming, "Done closes the field")
        XCTAssertTrue(wait { convos.loadError != nil }, "Done saved through the model")
    }

    // MARK: Select mode

    func testSelectModeBulkArchiveAndDelete() throws {
        let state = ListState()
        state.selecting = true
        state.selection = ["c-scroll", "c-pirate"]
        let convos = mount(state)

        try tap("Archive")
        XCTAssertTrue(state.selection.isEmpty, "archiving clears the selection")
        XCTAssertTrue(wait { convos.loadError != nil }, "Archive reached the model")

        // Both archive calls fail on their own schedule; let the second land
        // before clearing, so a late one can't pass for the delete below.
        settle(3)
        convos.loadError = nil
        state.selection = ["c-scroll", "c-swift"]
        settle()
        try tap("Delete 2")
        XCTAssertTrue(state.confirmingBulkDelete, "bulk delete asks in place first")
        XCTAssertNil(convos.loadError)

        try tap("Delete")
        XCTAssertFalse(state.selecting, "deleting leaves select mode")
        XCTAssertTrue(wait { convos.loadError != nil }, "Delete reached the model")
    }

    func testSelectModeTapTogglesRow() throws {
        let state = ListState()
        state.selecting = true
        _ = mount(state)
        try tap(containing: "Scroll architecture review")
        XCTAssertEqual(state.selection, ["c-scroll"])
        try tap(containing: "Scroll architecture review")
        XCTAssertTrue(state.selection.isEmpty)
        XCTAssertTrue(state.opened.isEmpty, "select mode never opens a conversation")
    }

    // MARK: Driving

    private func settle(_ seconds: TimeInterval = 0.4) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        window?.layoutIfNeeded()
    }

    private func wait(timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func elements() -> [NSObject] {
        guard let window else { return [] }
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ o: NSObject, _ depth: Int) {
            guard depth < 60, seen.insert(ObjectIdentifier(o)).inserted else { return }
            out.append(o)
            if let v = o as? UIView { v.subviews.forEach { walk($0, depth + 1) } }
            if let els = o.accessibilityElements as? [NSObject] {
                els.forEach { walk($0, depth + 1) }
            } else {
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } }
                }
            }
        }
        walk(window, 0)
        return out
    }

    private func labels() -> [String] {
        elements().compactMap { $0.isAccessibilityElement ? $0.accessibilityLabel : nil }
    }

    private func element(labeled label: String) -> NSObject? {
        elements().first { $0.isAccessibilityElement && $0.accessibilityLabel == label }
    }

    private func element(containing text: String) -> NSObject? {
        elements().first { $0.isAccessibilityElement && ($0.accessibilityLabel ?? "").contains(text) }
    }

    private func tap(_ label: String) throws {
        let e = try XCTUnwrap(element(labeled: label), "no element labeled \(label) in \(labels())")
        XCTAssertTrue(e.accessibilityActivate(), "\(label) didn't activate")
        settle()
    }

    private func tap(containing text: String) throws {
        let e = try XCTUnwrap(element(containing: text), "no element containing \(text)")
        XCTAssertTrue(e.accessibilityActivate(), "\(text) didn't activate")
        settle()
    }

    /// A swipe button runs `ChatRowActions.perform` for one of the row's
    /// trailing actions. UIKit won't hold a swipe open in a test or expose it
    /// to accessibility, so this runs the same call the button makes.
    private func swipeAction(_ action: ChatRowAction, on id: String, _ state: ListState,
                             _ convos: ConversationsModel) throws {
        let c = try XCTUnwrap(convos.conversations.first { $0.id == id })
        XCTAssertTrue(ChatRowAction.swipeTrailing(c).contains(action), "\(action) isn't on the row's swipe")
        let s = Bindable(state)
        ChatRowActions(convos: convos, confirmingDelete: s.confirmingDelete, renaming: s.renaming,
                       renameDraft: s.renameDraft).perform(action, on: c)
        settle()
    }

    private func textField(showing text: String) -> UITextField? {
        func find(_ v: UIView) -> UITextField? {
            if let t = v as? UITextField, t.text == text { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return window.flatMap(find)
    }
}
