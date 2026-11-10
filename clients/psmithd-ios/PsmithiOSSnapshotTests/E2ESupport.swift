import SwiftUI
import UIKit
import Darwin
import XCTest
@testable import PsmithiOS
import PsmithKit
import PsmithUI

/// What every end-to-end suite shares: the server `make ios-e2e` started,
/// a seeded account on it, the app's models signed in to it, and a real
/// window to mount screens in. Without the server the tests skip.
///
/// Controls are driven through the calls their buttons make, or through
/// the accessibility tree where a control's state is private to its view
/// (`press`, `type`). Waits suspend (`Task.sleep`) and never spin the run
/// loop: the test holds the main actor, and spinning it synchronously
/// starves the app's own main-actor continuations.
@MainActor
class E2ETestCase: XCTestCase {
    var window: UIWindow?
    /// Every conversation view model a mounted screen built, in order.
    var built: [(ConversationViewModel, ConversationUIState)] = []

    /// SwiftUI only builds its accessibility tree for an assistive
    /// client; automation mode stands in for one.
    override class func setUp() {
        super.setUp()
        if let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
           let sym = dlsym(lib, "_AXSSetAutomationEnabled") {
            typealias SetEnabled = @convention(c) (Int32) -> Void
            unsafeBitCast(sym, to: SetEnabled.self)(1)
        }
    }

    /// What a test seeded, removed afterwards so the account the suites
    /// share doesn't pile up rows past a page of the lists under test.
    private var seeded: [(AppModel, Seed)] = []

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        built = []
        for (app, seed) in seeded {
            let mine = Set([seed.alpha.id, seed.beta.id])
            var token: String?
            repeat {
                guard let page = try? await app.client.conversations.list(pageSize: 100, pageToken: token) else { break }
                for c in page.items where mine.contains(c.profileID) { try? await app.client.conversations.delete(id: c.id) }
                token = page.nextPageToken
            } while token != nil
            if let page = try? await app.client.conversations.list(pageSize: 100, archived: true) {
                for c in page.items where mine.contains(c.profileID) { try? await app.client.conversations.delete(id: c.id) }
            }
            for id in mine { try? await app.client.profiles.delete(id: id) }
            try? await app.client.modelProviders.delete(id: seed.provider.id)
        }
        seeded = []
        try await super.tearDown()
    }

    // MARK: Server and seed

    struct Server {
        let url: URL
        let user: String
        let password: String
        let llm: String
    }

    func server() throws -> Server {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PSMITH_E2E_URL"], let url = URL(string: raw) else {
            throw XCTSkip("PSMITH_E2E_URL not set; run `make ios-e2e`")
        }
        return Server(url: url, user: env["PSMITH_E2E_USER"] ?? "admin",
                      password: env["PSMITH_E2E_PASSWORD"] ?? "admin-password-not-secret",
                      llm: env["PSMITH_E2E_LLM"] ?? "http://127.0.0.1:9/v1")
    }

    /// Two models on the fake provider, and two profiles that both
    /// default to the first, so picking the second is a real change.
    /// Alpha is the default profile. Names carry a per-test tag: every
    /// test shares one database.
    struct Seed {
        let tag: String
        let provider: PsmithUserModelProvider
        let alpha: PsmithProfile
        let beta: PsmithProfile
    }

    func seed(_ client: PsmithClient, llm: String) async throws -> Seed {
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

    /// The app's models as the signed-in shell builds them, against the
    /// e2e server, with a fresh seed.
    func signedIn() async throws -> (AppModel, ConversationsModel, Seed) {
        let s = try server()
        let app = AppModel(host: s.url, tokenStore: InMemoryTokenStore(), connectivityState: .online)
        _ = try await app.client.auth.login(username: s.user, password: s.password)
        // The account event stream, as the signed-in app runs it: server
        // pushes "conversation changed" mid-send, and views refresh on it.
        await app.bootstrap()
        let seeded = try await seed(app.client, llm: s.llm)
        self.seeded.append((app, seeded))
        await app.profiles.load()
        while app.profiles.hasMore { await app.profiles.loadMore() }
        await app.providers.load()
        let convos = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
        app.onConversationListChanged = { [weak convos] in convos?.refreshSoon() }
        await convos.refresh()
        return (app, convos, seeded)
    }

    /// A conversation on the alpha profile, pinned to model-one.
    func makeConversation(_ app: AppModel, _ seeded: Seed, title: String) async throws -> PsmithConversation {
        try await app.client.conversations.create(
            profileID: seeded.alpha.id, title: "\(title) \(seeded.tag)",
            settings: PsmithConversationSettings(defaultProviderID: seeded.provider.id, defaultModelID: "model-one"))
    }

    /// A seeded title without its tag: what OCR can be trusted to read.
    func words(_ c: PsmithConversation) -> String {
        (c.title ?? "").split(separator: " ").dropLast().joined(separator: " ")
    }

    /// Sends through the API and waits for the reply to land, for history
    /// a test needs before it mounts anything.
    @discardableResult
    func seedTurn(_ app: AppModel, _ conv: PsmithConversation, _ text: String,
                  timeout: TimeInterval = 20) async throws -> [PsmithMessage] {
        let before = try await messages(app, conv).filter { $0.role == .assistant }.count
        _ = try await app.client.conversations.sendMessage(conversationID: conv.id, content: text)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let msgs = try await messages(app, conv)
            if msgs.filter({ $0.role == .assistant }).count > before {
                // The run's terminal lands just after the row; give the
                // server a beat so the next send isn't refused as busy.
                try await Task.sleep(nanoseconds: 300_000_000)
                return msgs
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("the seeded turn “\(text)” never got a reply")
        return try await messages(app, conv)
    }

    /// The active context's chain, as the server has it now.
    func messages(_ app: AppModel, _ conv: PsmithConversation) async throws -> [PsmithMessage] {
        let (_, ctx) = try await app.client.conversations.get(id: conv.id)
        return try await app.client.conversations.listMessages(contextID: ctx.id)
    }

    // MARK: Mounting

    /// Mounts a view in a real window with what the signed-in shell puts
    /// in the environment.
    @discardableResult
    func mount<V: View>(_ view: V, app: AppModel, convos: ConversationsModel,
                        accounts: AccountManager? = nil, navigator: iOSNavigator? = nil,
                        themes: ThemeStore? = nil) -> UIWindow {
        window?.isHidden = true
        let themes = themes ?? {
            let t = ThemeStore()
            if t.current.id != Theme.slate.id { t.current = .slate }
            return t
        }()
        let root = view
            .environment(app)
            .environment(convos)
            .environment(accounts ?? AccountManager(store: AccountStore(defaults: UserDefaults(suiteName: "psmith-e2e-accounts")!)))
            .environment(themes)
            .environment(sharedAppPreferences)
            .environment(navigator ?? iOSNavigator())
            .environment(\.theme, .slate)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        w.rootViewController = UIHostingController(rootView: root)
        w.isHidden = false
        w.makeKey()
        window = w
        return w
    }

    /// Mounts the app's chats stack as ChatsRoot builds it: a path-driven
    /// NavigationStack over the list, with `route` pushed. Mounting the
    /// screen as the stack's root instead hides bugs that only happen to
    /// a pushed destination.
    @discardableResult
    func mountStack(_ route: ChatRoute, app: AppModel, convos: ConversationsModel) -> UIWindow {
        mount(E2EChatsStack(start: route) { [weak self] m, ui in self?.built.append((m, ui)) },
              app: app, convos: convos)
    }

    // MARK: Waiting

    func spin(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @discardableResult
    func waitFor(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                 _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        let ok = cond()
        XCTAssertTrue(ok, "\(what). State: \(state())", file: file, line: line)
        return ok
    }

    /// Polls an async condition, for reading the server back.
    @discardableResult
    func eventually(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                    _ cond: () async throws -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await cond()) == true { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let ok = (try? await cond()) == true
        if !ok { XCTFail("\(what). Screen: \(screenText())", file: file, line: line) }
        return ok
    }

    /// Waits for the mounted screen's text to include `needle`, read back
    /// off the rendered window with OCR.
    @discardableResult
    func waitForText(_ needle: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if screenText().contains(needle.lowercased()) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let text = screenText()
        let ok = text.contains(needle.lowercased())
        XCTAssertTrue(ok, "“\(needle)” never showed on screen. Screen: \(text)", file: file, line: line)
        return ok
    }

    /// The rendered window's text, lowercased.
    func screenText() -> String {
        guard let w = window else { return "" }
        w.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in
            w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
        }
        return E2ETimeline.recognize(image).lowercased()
    }

    /// What the screen's conversation view models hold, for timelines
    /// and failure messages.
    func state() -> String {
        built.enumerated().map { i, b in
            let m = b.0
            let rows = m.messages.map { "\(String(describing: $0.role).prefix(1))\($0.content.count)" }.joined(separator: ",")
            return "#\(i) draft=\(m.isDraft) profile=\(m.draftProfile?.name ?? "-") " +
                "model=\(m.selectedModelID ?? "nil") loading=\(m.loading) streaming=\(m.isStreaming) " +
                "pending=\(m.pendingUserText.map { "\($0.count)" } ?? "nil") live=\(m.streamingText.count) " +
                "rows=[\(rows)] error=\(m.loadError ?? "nil") compactError=\(m.compactError ?? "nil")"
        }.joined(separator: "; ")
    }

    // MARK: Sending

    /// Sends `text` through the composer of the screen's current view
    /// model and records the screen until the reply has settled for
    /// three seconds. Asserts the user's message shows within a second
    /// and never leaves, and the reply never leaves once it shows.
    ///
    /// The fake model answers "echo <word>" with "Heard <word> …", so a
    /// test can send several turns and still tell its replies apart.
    func sendAndWatch(_ w: UIWindow, name: String, text: String = "Tidepool question number seven",
                      user: String = "tidepool", reply: String = "quick rundown",
                      models: Int = 1, timeout: TimeInterval = 25,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let tl = E2ETimeline(name: name)
        defer { tl.write() }
        tl.sample(w, "before send", needles: [user, reply], state: state())

        let (vm, ui) = built.last!
        vm.draft = text
        Composer(model: vm, ui: ui).send()
        let sentAt = tl.samples.last!.t

        // Through the stream, then three more seconds after it settles, so
        // the post-terminal reload is on the record too.
        var settledAt: Date?
        await tl.record(w, timeout: timeout, needles: [user, reply], state: state) {
            let m = built.last!.0
            let done = !m.isStreaming && m.messages.contains { $0.role == .assistant && $0.content.lowercased().contains(reply) }
            if done && settledAt == nil { settledAt = Date() }
            return settledAt.map { Date().timeIntervalSince($0) > 3 } ?? false
        }

        XCTAssertNotNil(settledAt, "the reply never finished. \(state()). Frames: \(tl.dir.path)", file: file, line: line)
        XCTAssertEqual(tl.gaps(user, from: sentAt + 1).map(\.t), [],
                       "the user's message was missing from these frames (seconds). Frames: \(tl.dir.path)",
                       file: file, line: line)
        if let first = tl.firstSeen(reply) {
            XCTAssertEqual(tl.gaps(reply, from: first).map(\.t), [],
                           "the reply disappeared in these frames (seconds). Frames: \(tl.dir.path)", file: file, line: line)
        } else {
            XCTFail("the reply never showed on screen. \(state()). Frames: \(tl.dir.path)", file: file, line: line)
        }
        XCTAssertEqual(built.count, models, "the screen rebuilt its view model mid-send. \(state())", file: file, line: line)
    }

    // MARK: Accessibility

    /// Every view and accessibility element in the window, in drawing
    /// order: a view's subviews back to front, then its elements in reading
    /// order. Later entries sit in front, so where a label appears twice
    /// (a transcript button under the long-press menu's) the last is the
    /// one a finger would reach.
    func elements() -> [NSObject] {
        guard let window else { return [] }
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, _ depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(node)).inserted else { return }
            if let view = node as? UIView, view.isHidden || view.alpha == 0 { return }
            out.append(node)
            if let view = node as? UIView { view.subviews.forEach { walk($0, depth + 1) } }
            if let els = node.accessibilityElements as? [NSObject] {
                els.forEach { walk($0, depth + 1) }
            } else {
                let n = node.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<n { if let e = node.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } }
                }
            }
        }
        walk(window, 0)
        return out
    }

    func labels() -> [String] {
        elements().compactMap { $0.isAccessibilityElement ? $0.accessibilityLabel : nil }
    }

    func element(_ label: String) -> NSObject? {
        elements().last { $0.isAccessibilityElement && $0.accessibilityLabel == label }
    }

    /// Whether the switch labelled `label` reads on.
    func isOn(_ label: String) -> Bool? {
        value(label).map { $0 == "1" || $0 == "On" }
    }

    /// The accessibility value of the control labelled `label`: "1"/"0"
    /// for a switch.
    func value(_ label: String) -> String? {
        element(label)?.accessibilityValue
    }

    /// Waits for a control labelled `label` and activates it, as
    /// VoiceOver's double-tap does: the real Button's action runs.
    @discardableResult
    func press(_ label: String, timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while element(label) == nil && Date() < end { await spin(0.1) }
        guard let match = element(label) else {
            XCTFail("No control labelled “\(label)”. Have: \(labels())", file: file, line: line)
            return false
        }
        let ok = match.accessibilityActivate()
        await spin(0.3)
        return ok
    }

    /// Activates the first control whose label contains `text`: list rows
    /// read their title, then their detail.
    @discardableResult
    func press(containing text: String, timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        func find() -> NSObject? {
            elements().last { $0.isAccessibilityElement && ($0.accessibilityLabel ?? "").contains(text) }
        }
        let end = Date().addingTimeInterval(timeout)
        while find() == nil && Date() < end { await spin(0.1) }
        guard let match = find() else {
            XCTFail("No control containing “\(text)”. Have: \(labels())", file: file, line: line)
            return false
        }
        let ok = match.accessibilityActivate()
        await spin(0.3)
        return ok
    }

    /// Types into the composer's message view the way the keyboard does,
    /// so its coordinator writes the draft.
    func typeMessage(_ text: String, file: StaticString = #filePath, line: UInt = #line) async {
        guard let window else { return }
        func find(_ v: UIView) -> UITextView? {
            if v.isHidden { return nil }
            if let t = v as? UITextView, t.isEditable { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        let end = Date().addingTimeInterval(6)
        var tv = find(window)
        while tv == nil && Date() < end { await spin(0.1); tv = find(window) }
        guard let tv else { return XCTFail("no message field on screen", file: file, line: line) }
        tv.becomeFirstResponder()
        tv.selectAll(nil)
        tv.insertText(text)
        await spin(0.2)
    }

    /// The text fields on screen, in window order top to bottom.
    func textFields() -> [UITextField] {
        guard let window else { return [] }
        var out: [UITextField] = []
        func walk(_ v: UIView) {
            if v.isHidden || v.alpha == 0 { return }
            if let f = v as? UITextField { out.append(f) }
            v.subviews.forEach(walk)
        }
        walk(window)
        return out.sorted {
            let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
            return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY
        }
    }

    /// Replaces a text field's contents the way typing does: the field's
    /// own editing calls, so its SwiftUI binding updates.
    func type(_ text: String, into field: UITextField) async {
        field.becomeFirstResponder()
        await spin(0.1)
        field.selectAll(nil)
        if let range = field.selectedTextRange { field.replace(range, withText: text) }
        // A field that couldn't take focus (or a selection that didn't
        // cover the old text) gets the value set outright.
        if field.text != text { field.text = text }
        field.sendActions(for: .editingChanged)
        NotificationCenter.default.post(name: UITextField.textDidChangeNotification, object: field)
        await spin(0.3)
    }

    /// The field whose placeholder (or accessibility label) is `name`.
    func field(_ name: String) -> UITextField? {
        textFields().first { $0.placeholder == name } ?? textFields().first { $0.accessibilityLabel == name }
    }
}

/// ChatsRoot's stack without its list: the same path-driven
/// NavigationStack and the same destinations, starting with one route
/// pushed.
struct E2EChatsStack: View {
    let onModel: (ConversationViewModel, ConversationUIState) -> Void
    @State private var path: [ChatRoute]

    init(start: ChatRoute, onModel: @escaping (ConversationViewModel, ConversationUIState) -> Void) {
        self.onModel = onModel
        _path = State(initialValue: [start])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ChatRoute.self) { route in
                    switch route {
                    case .conversation(let c): ConversationView(conversation: c, onModel: onModel)
                    case .newConversation(let id): ConversationView(newConversation: id, onModel: onModel)
                    default: EmptyView()
                    }
                }
        }
    }
}

/// A page pushed onto a stack, as Settings pages are: a back button and
/// a navigation bar, the same as on device.
struct E2EPushed<Page: View>: View {
    @State private var path = [1]
    let page: Page
    init(@ViewBuilder _ page: () -> Page) { self.page = page() }
    var body: some View {
        NavigationStack(path: $path) {
            Color.clear.navigationDestination(for: Int.self) { _ in page }
        }
    }
}
