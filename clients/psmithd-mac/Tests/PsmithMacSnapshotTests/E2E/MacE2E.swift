import Testing
import AppKit
import SwiftUI
import Vision
@testable import PsmithMac
import PsmithKit
import PsmithUI

/// What every Mac end-to-end test shares: the server `make mac-e2e`
/// started, a seeded account on it, the app's models signed in to it, and
/// the real main window (HomeView) or Settings window mounted offscreen.
/// Without the server the tests are skipped.
///
/// Controls are driven the way a person drives them where that can be done
/// headlessly: keys through the composer's own `keyDown`, clicks through
/// the accessibility tree's press action (the real Button's action runs),
/// scrolling with scroll-wheel events. Waits suspend (`Task.sleep`) so the
/// app's main-actor work keeps running between checks.
@MainActor
final class MacE2E {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["PSMITH_E2E_URL"] != nil

    struct Server {
        let url: URL
        let user: String
        let password: String
        let llm: String
    }

    /// Two models on the fake provider and two profiles that both default
    /// to the first, so picking the second is a real change. Alpha is the
    /// default profile. Names carry a per-test tag: every test shares one
    /// database.
    struct Seed {
        let tag: String
        let provider: PsmithUserModelProvider
        let alpha: PsmithProfile
        let beta: PsmithProfile
    }

    let app: AppModel
    let convos: ConversationsModel
    let seed: Seed
    let navigator = Navigator()
    let accounts = AccountManager(store: AccountStore(defaults: UserDefaults(suiteName: "psmith-mac-e2e-accounts")!))
    private(set) var window: NSWindow?
    private var extraWindows: [NSWindow] = []
    /// Every conversation view model a mounted screen built, in order.
    private(set) var built: [ConversationViewModel] = []

    static func server() -> Server {
        let env = ProcessInfo.processInfo.environment
        return Server(url: URL(string: env["PSMITH_E2E_URL"] ?? "http://127.0.0.1:9")!,
                      user: env["PSMITH_E2E_USER"] ?? "admin",
                      password: env["PSMITH_E2E_PASSWORD"] ?? "admin-password-not-secret",
                      llm: env["PSMITH_E2E_LLM"] ?? "http://127.0.0.1:9/v1")
    }

    private init(app: AppModel, convos: ConversationsModel, seed: Seed) {
        self.app = app
        self.convos = convos
        self.seed = seed
    }

    /// Signs in, seeds, runs `body`, and always cleans up what it seeded
    /// and the windows it opened.
    static func run(_ body: (MacE2E) async throws -> Void) async throws {
        let e = try await signedIn()
        do {
            try await body(e)
        } catch {
            await e.cleanUp()
            throw error
        }
        await e.cleanUp()
    }

    static func signedIn() async throws -> MacE2E {
        let s = server()
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        enableAccessibility()
        sharedThemeStore.current = .slate
        let app = AppModel(host: s.url, tokenStore: InMemoryTokenStore(), authState: AuthState(), accountID: UUID())
        _ = try await app.client.auth.login(username: s.user, password: s.password, clientLabel: "mac-e2e")
        // The account event stream, as the signed-in app runs it: the
        // server pushes "conversation changed" mid-send, and views refresh.
        await app.bootstrap()
        let seed = try await seed(app.client, llm: s.llm)
        await app.profiles.load()
        while app.profiles.hasMore { await app.profiles.loadMore() }
        await app.providers.load()
        let convos = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
        app.onConversationListChanged = { [weak convos] in convos?.refreshSoon() }
        await convos.refresh()
        return MacE2E(app: app, convos: convos, seed: seed)
    }

    static func seed(_ client: PsmithClient, llm: String) async throws -> Seed {
        let tag = String(UUID().uuidString.prefix(6))
        let config = #"{"api_key":"e2e","base_url":"\#(llm)","use_chat_completions":true}"#
        let provider = try await client.modelProviders.create(type: "openai-compatible", label: "E2E \(tag)",
                                                              config: Data(config.utf8))
        let caps = PsmithModelCapabilities(streaming: true, thinking: false, toolUse: false, vision: true, promptCaching: false)
        for (id, name) in [("model-one", "Model One"), ("model-two", "Model Two")] {
            _ = try await client.modelProviders.addManualModel(
                providerID: provider.id, modelID: id, displayName: name, contextWindow: 32_000, maxOutputTokens: nil,
                pricing: PsmithModelPricing(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: nil,
                                            cacheWritePerMillion: nil),
                modalities: ["text", "image"], capabilities: caps, knowledgeCutoff: nil, defaultSettings: nil)
        }
        let defaults = PsmithProfileDefaults(defaultProviderID: provider.id, defaultModelID: "model-one")
        let alpha = try await client.profiles.create(PsmithProfilePatch(name: "Alpha \(tag)", defaultSettings: defaults))
        let beta = try await client.profiles.create(PsmithProfilePatch(name: "Beta \(tag)", defaultSettings: defaults))
        try await client.profiles.setDefault(profileID: alpha.id)
        return Seed(tag: tag, provider: provider, alpha: alpha, beta: beta)
    }

    func cleanUp() async {
        window?.orderOut(nil)
        extraWindows.forEach { $0.orderOut(nil) }
        window = nil
        extraWindows = []
        let mine = Set([seed.alpha.id, seed.beta.id])
        for archived in [false, true] {
            var token: String?
            repeat {
                guard let page = try? await app.client.conversations.list(pageSize: 100, pageToken: token, archived: archived) else { break }
                for c in page.items where mine.contains(c.profileID) { try? await app.client.conversations.delete(id: c.id) }
                token = page.nextPageToken
            } while token != nil
        }
        for id in mine { try? await app.client.profiles.delete(id: id) }
        try? await app.client.modelProviders.delete(id: seed.provider.id)
    }

    // MARK: Data

    /// A conversation on the alpha profile, pinned to model-one.
    func makeConversation(_ title: String, profile: PsmithProfile? = nil) async throws -> PsmithConversation {
        try await app.client.conversations.create(
            profileID: (profile ?? seed.alpha).id, title: "\(title) \(seed.tag)",
            settings: PsmithConversationSettings(defaultProviderID: seed.provider.id, defaultModelID: "model-one"))
    }

    /// Sends through the API and waits for the reply, for history a test
    /// needs before it mounts anything. The fake model answers
    /// "echo <word>" with "Heard <word> …".
    @discardableResult
    func seedTurn(_ conv: PsmithConversation, _ text: String, timeout: TimeInterval = 20) async throws -> [PsmithMessage] {
        let before = try await messages(conv).filter { $0.role == .assistant }.count
        _ = try await app.client.conversations.sendMessage(conversationID: conv.id, content: text)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let msgs = try await messages(conv)
            if msgs.filter({ $0.role == .assistant }).count > before {
                try await Task.sleep(nanoseconds: 300_000_000)
                return msgs
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("the seeded turn “\(text)” never got a reply")
        return try await messages(conv)
    }

    /// The active context's chain, as the server has it now.
    func messages(_ conv: PsmithConversation) async throws -> [PsmithMessage] {
        let (_, ctx) = try await app.client.conversations.get(id: conv.id)
        return try await app.client.conversations.listMessages(contextID: ctx.id)
    }

    // MARK: Mounting

    /// The app's environment around `view`, as PsmithMacApp builds it.
    private func environment<V: View>(_ view: V) -> some View {
        let themes = sharedThemeStore
        return view
            .environment(app)
            .environment(convos)
            .environment(accounts)
            .environment(sharedWindowState)
            .environment(navigator)
            .environment(themes)
            .environment(sharedAppPreferences)
            .environment(\.theme, themes.current)
            .environment(\.clipboard, AppKitClipboard())
            .environment(\.onConversationModel) { [weak self] m in self?.built.append(m) }
            .tint(themes.current.accent)
            .background(themes.current.chrome.ignoresSafeArea())
    }

    /// An offscreen window shaped like the app's: titled, full-size
    /// content, the app's chrome pass applied. The hosting view bridges
    /// titles and toolbars to the window as a WindowGroup scene does.
    private func makeWindow<V: View>(_ view: V, size: CGSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: environment(view))
        host.sceneBridgingOptions = [.all]
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        w.orderFront(nil)
        AppDelegate.configure(w)
        // Configure snaps the window up to the app's floor; keep it offscreen.
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        w.makeKey()
        return w
    }

    /// The main window, signed in: the list and the reading pane.
    @discardableResult
    func mountHome(size: CGSize = CGSize(width: 1280, height: 800)) async -> NSWindow {
        window?.orderOut(nil)
        let w = makeWindow(HomeView(user: app.authState.currentUser!), size: size)
        window = w
        await spin(1.0)
        return w
    }

    /// Another window (Settings), kept alongside the main one.
    @discardableResult
    func mountWindow<V: View>(_ view: V, size: CGSize) async -> NSWindow {
        let w = makeWindow(view, size: size)
        extraWindows.append(w)
        window = w
        await spin(0.8)
        return w
    }

    /// The main window's reading pane on `conv`, the way a click on its
    /// row selects it.
    func open(_ conv: PsmithConversation, minMessages: Int = 0, file: StaticString = #filePath, line: UInt = #line) async {
        if window == nil { await mountHome() }
        convos.selectedID = conv.id
        await waitFor("the conversation never loaded", timeout: 10) {
            guard let m = self.model, m.conversation.id == conv.id else { return false }
            return !m.loading && m.messages.count >= minMessages
        }
        await spin(0.4)
    }

    /// The reading pane's current view model.
    var model: ConversationViewModel? { built.last }

    // MARK: Waiting

    func spin(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @discardableResult
    func waitFor(_ what: String, timeout: TimeInterval = 10, sourceLocation: SourceLocation = #_sourceLocation,
                 _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        let ok = cond()
        if !ok { Issue.record("\(what). State: \(state())", sourceLocation: sourceLocation) }
        return ok
    }

    /// Polls an async condition, for reading the server back.
    @discardableResult
    func eventually(_ what: String, timeout: TimeInterval = 10, sourceLocation: SourceLocation = #_sourceLocation,
                    _ cond: () async throws -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await cond()) == true { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let ok = (try? await cond()) == true
        if !ok { Issue.record("\(what). Screen: \(screenText())", sourceLocation: sourceLocation) }
        return ok
    }

    /// Waits for the window's text to include `needle`, read back off the
    /// rendered window with OCR.
    @discardableResult
    func waitForText(_ needle: String, timeout: TimeInterval = 8, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if screenText().contains(needle.lowercased()) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let text = screenText()
        let ok = text.contains(needle.lowercased())
        if !ok { Issue.record("“\(needle)” never showed on screen. Screen: \(text)", sourceLocation: sourceLocation) }
        return ok
    }

    /// The window's text, lowercased.
    func screenText() -> String {
        guard let image = render() else { return "" }
        return Self.recognize(image).lowercased()
    }

    func render() -> CGImage? {
        guard let window else { return nil }
        return LiveProbe.Rig.render(window)
    }

    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// What the screen's view models hold, for failure messages.
    func state() -> String {
        built.enumerated().map { i, m in
            let rows = m.messages.map { "\(String(describing: $0.role).prefix(1))\($0.content.count)" }.joined(separator: ",")
            return "#\(i) draft=\(m.isDraft) profile=\(m.draftProfile?.name ?? "-") " +
                "model=\(m.selectedModelID ?? "nil") loading=\(m.loading) streaming=\(m.isStreaming) " +
                "pending=\(m.pendingUserText.map { "\($0.count)" } ?? "nil") live=\(m.streamingText.count) " +
                "rows=[\(rows)] error=\(m.loadError ?? "nil") compactError=\(m.compactError ?? "nil")"
        }.joined(separator: "; ")
    }

    // MARK: Accessibility

    /// Turns on SwiftUI's accessibility tree, which it builds only for an
    /// assistive client. SwiftUI's nodes answer the Objective-C selectors,
    /// not a Swift protocol cast, so everything below goes through those.
    static func enableAccessibility() {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    static func ax(_ node: NSObject, _ selector: String) -> Any? {
        let sel = NSSelectorFromString(selector)
        guard node.responds(to: sel) else { return nil }
        return node.perform(sel)?.takeUnretainedValue()
    }

    static func children(_ node: NSObject) -> [NSObject] {
        (ax(node, "accessibilityChildren") as? [NSObject]) ?? []
    }

    static func role(_ node: NSObject) -> String { (ax(node, "accessibilityRole") as? String) ?? "" }

    /// The label a person (or VoiceOver) reads for an element.
    static func name(_ e: NSObject) -> String {
        if let l = ax(e, "accessibilityLabel") as? String, !l.isEmpty { return l }
        if let t = ax(e, "accessibilityTitle") as? String, !t.isEmpty { return t }
        if let v = ax(e, "accessibilityValue") as? String { return v }
        return ""
    }

    /// A control's value: "1"/"0" for a switch, the text of a field.
    static func value(_ e: NSObject) -> String? {
        switch ax(e, "accessibilityValue") {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Every accessibility element in the window, depth first.
    func elements() -> [NSObject] {
        guard let root = window?.contentView else { return [] }
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 90, seen.insert(ObjectIdentifier(node)).inserted else { return }
            if let v = node as? NSView, v.isHiddenOrHasHiddenAncestor { return }
            out.append(node)
            Self.children(node).forEach { walk($0, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    func labels() -> [String] {
        elements().map(Self.name).filter { !$0.isEmpty }
    }

    func element(_ label: String) -> NSObject? {
        elements().last { Self.name($0) == label }
    }

    func element(containing text: String) -> NSObject? {
        elements().last { Self.name($0).contains(text) }
    }

    /// The value of the control named `label`.
    func value(_ label: String) -> String? { element(label).flatMap(Self.value) }

    /// Waits for a control named `label` and presses it as VoiceOver does:
    /// the real Button's action runs.
    @discardableResult
    func press(_ label: String, timeout: TimeInterval = 6, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await press(timeout: timeout, describe: "“\(label)”", sourceLocation: sourceLocation) { self.element(label) }
    }

    @discardableResult
    func press(containing text: String, timeout: TimeInterval = 6, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await press(timeout: timeout, describe: "containing “\(text)”", sourceLocation: sourceLocation) { self.element(containing: text) }
    }

    private func press(timeout: TimeInterval, describe: String, sourceLocation: SourceLocation,
                       find: () -> NSObject?) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while find() == nil && Date() < end { await spin(0.1) }
        guard let match = find() else {
            Issue.record("No control \(describe). Have: \(labels())", sourceLocation: sourceLocation)
            return false
        }
        _ = match.perform(NSSelectorFromString("accessibilityPerformPress"))
        await spin(0.35)
        return true
    }

    /// The element's frame in window coordinates (bottom-left origin).
    func frameInWindow(_ e: NSObject) -> NSRect? {
        // A struct return; perform(_:) can't carry it, key-value coding boxes it.
        guard let window, e.responds(to: NSSelectorFromString("accessibilityFrame")),
              let screen = (e.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return nil }
        return window.convertFromScreen(screen)
    }

    /// Runs the item titled `item` from the context menu of the element
    /// named `label`. The rows offer their menus' items as accessibility
    /// actions too (a context menu isn't reachable through accessibility),
    /// so this runs the same Button a right-click would, the way VoiceOver
    /// does, without putting a menu on screen.
    @discardableResult
    func contextMenu(on label: String, containing: Bool = true, choose item: String,
                     sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        func actions(_ e: NSObject) -> [NSAccessibilityCustomAction] {
            (Self.ax(e, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
        }
        func find() -> (NSObject, NSAccessibilityCustomAction)? {
            for e in elements().reversed() {
                let n = Self.name(e)
                guard containing ? n.contains(label) : n == label else { continue }
                if let a = actions(e).first(where: { $0.name == item }) { return (e, a) }
            }
            return nil
        }
        let end = Date().addingTimeInterval(6)
        var hit = find()
        while hit == nil && Date() < end { await spin(0.15); hit = find() }
        guard let (_, action) = hit else {
            let offered = elements().filter { Self.name($0).contains(label) }.map { actions($0).map(\.name) }
            Issue.record("No “\(item)” action on \(label). Offered: \(offered)", sourceLocation: sourceLocation)
            return false
        }
        if let handler = action.handler { _ = handler() } else if let target = action.target as? NSObject, let sel = action.selector {
            _ = target.perform(sel, with: action)
        }
        await spin(0.4)
        return true
    }

    // MARK: Keys and text

    /// The composer: the editable text view in the reading pane.
    func composer() -> ComposerNSTextView? {
        guard let root = window?.contentView else { return nil }
        return LiveProbe.Rig.find(root) { $0 is ComposerNSTextView && !$0.isHiddenOrHasHiddenAncestor }.first as? ComposerNSTextView
    }

    /// Types `text` into the composer as the keyboard does, then presses
    /// Return through its own keyDown, so the key binding is what sends.
    func typeAndSend(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        let end = Date().addingTimeInterval(6)
        var view = composer()
        while (view == nil || !(view!.isEditable)) && Date() < end { await spin(0.1); view = composer() }
        guard let view, let window = view.window else {
            Issue.record("no composer on screen", sourceLocation: sourceLocation)
            return
        }
        window.makeFirstResponder(view)
        view.selectAll(nil)
        view.insertText(text, replacementRange: view.selectedRange())
        await spin(0.2)
        key(view, 36, "\r")
        await spin(0.2)
    }

    /// A key press through `view`'s own keyDown.
    func key(_ view: NSView, _ code: UInt16, _ chars: String, modifiers: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        view.keyDown(with: e)
    }

    /// A menu-style shortcut, through the window's key equivalents.
    func shortcut(_ code: UInt16, _ chars: String, modifiers: NSEvent.ModifierFlags) async {
        guard let window else { return }
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        _ = window.performKeyEquivalent(with: e)
        await spin(0.4)
    }

    /// Editable text fields in the window, top to bottom.
    func textFields() -> [NSTextField] {
        guard let root = window?.contentView else { return [] }
        let fields = LiveProbe.Rig.find(root) {
            ($0 as? NSTextField)?.isEditable == true && !$0.isHiddenOrHasHiddenAncestor
        } as! [NSTextField]
        return fields.sorted {
            let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
            return a.maxY == b.maxY ? a.minX < b.minX : a.maxY > b.maxY
        }
    }

    /// The field whose placeholder or accessibility label is `name`.
    func field(_ name: String) -> NSTextField? {
        textFields().first { $0.placeholderString == name || $0.accessibilityLabel() == name }
    }

    /// Replaces a field's text the way typing does: through its field
    /// editor, so the SwiftUI binding updates.
    func type(_ text: String, into field: NSTextField) async {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        await spin(0.1)
        if let editor = field.currentEditor() as? NSTextView {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            field.stringValue = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        }
        await spin(0.3)
    }

    /// Ends editing in the focused field, as Tab or a click elsewhere does.
    func commitEditing() async {
        window?.makeFirstResponder(nil)
        await spin(0.3)
    }

    // MARK: Scrolling

    /// The tallest scroll view under `root`, or the window.
    func scrollView(in root: NSView? = nil) -> NSScrollView? {
        guard let root = root ?? window?.contentView else { return nil }
        return (LiveProbe.Rig.find(root) { $0 is NSScrollView && !$0.isHiddenOrHasHiddenAncestor } as! [NSScrollView])
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    /// A trackpad scroll. Negative `dy` moves toward the end.
    func scroll(_ sv: NSScrollView, dy: Int32) async {
        for (phase, delta) in [(CGScrollPhase.began, dy / 4), (.changed, dy / 4), (.changed, dy / 4), (.changed, dy / 4), (.ended, 0)] {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            sv.scrollWheel(with: NSEvent(cgEvent: cg)!)
            await spin(0.05)
        }
        await spin(0.4)
    }

    // MARK: Sending, watched

    /// Sends `text` from the composer and records the window until the
    /// reply has settled for three seconds. Asserts the user's message
    /// shows within a second and never leaves, and the reply never leaves
    /// once it shows.
    func sendAndWatch(_ name: String, text: String = "Tidepool question number seven",
                      user: String = "tidepool", reply: String = "quick rundown", timeout: TimeInterval = 25,
                      sourceLocation: SourceLocation = #_sourceLocation) async {
        let tl = MacE2ETimeline(name: name)
        defer { tl.write() }
        let modelsBefore = built.count
        tl.sample(self, "before send", needles: [user, reply])
        await typeAndSend(text, sourceLocation: sourceLocation)
        let sentAt = tl.samples.last!.t
        var settledAt: Date?
        await tl.record(self, timeout: timeout, needles: [user, reply]) {
            guard let m = self.model else { return false }
            let done = !m.isStreaming && m.messages.contains { $0.role == .assistant && $0.content.lowercased().contains(reply) }
            if done && settledAt == nil { settledAt = Date() }
            return settledAt.map { Date().timeIntervalSince($0) > 3 } ?? false
        }
        if settledAt == nil {
            Issue.record("the reply never finished. \(state()). Frames: \(tl.dir.path)", sourceLocation: sourceLocation)
        }
        let missing = tl.gaps(user, from: sentAt + 1).map(\.t)
        if !missing.isEmpty {
            Issue.record("the user's message was missing at \(missing)s. Frames: \(tl.dir.path)", sourceLocation: sourceLocation)
        }
        if let first = tl.firstSeen(reply) {
            let gone = tl.gaps(reply, from: first).map(\.t)
            if !gone.isEmpty {
                Issue.record("the reply disappeared at \(gone)s. Frames: \(tl.dir.path)", sourceLocation: sourceLocation)
            }
        } else {
            Issue.record("the reply never showed on screen. \(state()). Frames: \(tl.dir.path)", sourceLocation: sourceLocation)
        }
        if built.count != modelsBefore {
            Issue.record("the screen rebuilt its view model mid-send. \(state())", sourceLocation: sourceLocation)
        }
    }
}

/// What a watched stretch of the window did over time: each sample's frame
/// (saved), its OCR text, which needles were visible, and the view models'
/// state. Lands in `$PSMITH_SNAP_OUT/mac-e2e/<name>/`.
@MainActor
final class MacE2ETimeline {
    struct Sample {
        let t: TimeInterval
        let note: String
        let visible: [String: Bool]
        let state: String
    }

    let dir: URL
    private let start = Date()
    private(set) var samples: [Sample] = []

    init(name: String) {
        let root = ProcessInfo.processInfo.environment["PSMITH_SNAP_OUT"] ?? NSTemporaryDirectory()
        dir = URL(fileURLWithPath: root).appendingPathComponent("mac-e2e").appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TranscriptTrace.reset()
    }

    @discardableResult
    func sample(_ e: MacE2E, _ note: String = "", needles: [String]) -> Sample {
        let image = e.render()
        let n = samples.count
        if let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(String(format: "f%03d.png", n)))
        }
        let text = image.map(MacE2E.recognize)?.lowercased() ?? ""
        var visible: [String: Bool] = [:]
        for needle in needles { visible[needle] = text.contains(needle.lowercased()) }
        let s = Sample(t: Date().timeIntervalSince(start), note: note, visible: visible, state: e.state())
        samples.append(s)
        return s
    }

    func record(_ e: MacE2E, every interval: TimeInterval = 0.25, timeout: TimeInterval,
                needles: [String], until: () -> Bool = { false }) async {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            sample(e, needles: needles)
            if until() { break }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } while Date() < end
    }

    func write() {
        let lines = samples.enumerated().map { i, s in
            let marks = s.visible.keys.sorted().map { "\($0)=\(s.visible[$0]! ? "yes" : "NO")" }.joined(separator: " ")
            return String(format: "f%03d t=%6.2fs ", i, s.t) + marks + (s.note.isEmpty ? "" : " [\(s.note)]") + " | " + s.state
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("timeline.txt"), atomically: true, encoding: .utf8)
        try? TranscriptTrace.lines.joined(separator: "\n").write(to: dir.appendingPathComponent("trace.txt"), atomically: true, encoding: .utf8)
    }

    func gaps(_ needle: String, from: TimeInterval) -> [Sample] {
        samples.filter { $0.t >= from && $0.visible[needle] == false }
    }

    func firstSeen(_ needle: String) -> TimeInterval? {
        samples.first { $0.visible[needle] == true }?.t
    }
}
