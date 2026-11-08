import Testing
import AppKit
import ScreenCaptureKit
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI

/// Scratch harness: the real Mac view tree against a live test server,
/// in an offscreen titled window, written out as PNGs. Runs only when
/// PSMITH_LIVE_PROBE names the shots directory.
@MainActor
struct LiveProbe {
    nonisolated static let shots = ProcessInfo.processInfo.environment["PSMITH_LIVE_PROBE"] ?? ""
    nonisolated static let host = URL(string: ProcessInfo.processInfo.environment["PSMITH_LIVE_HOST"] ?? "http://127.0.0.1:18080")!

    @MainActor final class Rig {
        let window: NSWindow
        let app: AppModel
        let navigator = Navigator()
        let accounts = AccountManager(store: AccountStore(defaults: UserDefaults(suiteName: "psmith.liveprobe")!))
        let prefs = sharedAppPreferences

        init(app: AppModel, size: CGSize = CGSize(width: 1280, height: 820)) {
            self.app = app
            window = KeyedWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        func mount<V: View>(_ v: V) {
            let themeStore = sharedThemeStore
            let root = v
                .environment(app)
                .environment(accounts)
                .environment(sharedWindowState)
                .environment(navigator)
                .environment(themeStore)
                .environment(prefs)
                .environment(\.theme, themeStore.current)
                .environment(\.clipboard, AppKitClipboard())
                .tint(themeStore.current.accent)
                .background(themeStore.current.chrome.ignoresSafeArea())
            window.contentView = NSHostingView(rootView: root)
            AppDelegate.configure(window)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFront(nil)
        }

        func pump(_ seconds: Double) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                spin()
                await Task.yield()
            }
        }

        nonisolated func spin() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        /// The window as the window server draws it: glass, materials and
        /// vibrancy included. Needs Screen Recording.
        func real(_ name: String) async {
            let path = "\(LiveProbe.shots)/real-\(name).png"
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    print("REAL", name, "window not listed; on screen:", window.isOnActiveSpace, "count", content.windows.count)
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let config = SCStreamConfiguration()
                config.width = Int(w.frame.width * 2)
                config.height = Int(w.frame.height * 2)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("REAL", name, "ok", image.width, image.height)
            } catch {
                print("REAL", name, "failed", error)
            }
        }

        /// The window's attached sheet, captured on its own.
        func realSheet(_ name: String) async {
            guard let sheet = window.attachedSheet else { print("REAL", name, "no sheet"); return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let w = content.windows.first(where: { $0.windowID == CGWindowID(sheet.windowNumber) }) else { print("REAL", name, "sheet not listed"); return }
                let config = SCStreamConfiguration()
                config.width = Int(w.frame.width * 2)
                config.height = Int(w.frame.height * 2)
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(LiveProbe.shots)/real-\(name).png"))
                print("REAL", name, "ok")
            } catch { print("REAL", name, "failed", error) }
        }

        static func find(_ v: NSView, where pred: (NSView) -> Bool) -> [NSView] {
            var out: [NSView] = []
            if pred(v) { out.append(v) }
            for s in v.subviews { out += find(s, where: pred) }
            return out
        }

        func both(_ name: String) async {
            snap(name)
            await real(name)
        }

        func snap(_ name: String) {
            guard let view = window.contentView?.superview ?? window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            CATransaction.flush()
            guard let layer = view.layer else { return }
            let scale = window.backingScaleFactor
            let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
            guard let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            // Window chrome color underneath: material layers render
            // transparent here, so this is what they sit on.
            ctx.setFillColor(NSColor(sharedThemeStore.current.chrome).usingColorSpace(.sRGB)?.cgColor ?? .black)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            // Backdrop layers (scroll-edge pockets, blur) render as an
            // opaque white plate outside the window server; hide them.
            var hidden: [CALayer] = []
            var faint: [NSView] = []
            defer { faint.forEach { $0.isHidden = false } }
            func hideBackdrops(_ l: CALayer) {
                let name = String(describing: type(of: l))
                if name.contains("Backdrop"), !l.isHidden { l.isHidden = true; hidden.append(l) }
                l.sublayers?.forEach(hideBackdrops)
            }
            hideBackdrops(layer)
            // Near-transparent views (scroll-pocket dimming at 1%) draw solid
            // through cacheDisplay, which ignores alpha.
            for v in Self.find(view, where: { $0.alphaValue < 0.05 && !$0.isHidden }) {
                v.isHidden = true
                hidden.append(v.layer ?? CALayer())
                faint.append(v)
            }
            for v in Self.find(view, where: {
                let n = String(describing: type(of: $0))
                return n.contains("Pocket") || n.contains("PortalView")
            }) where !(v.layer?.isHidden ?? true) {
                v.layer?.isHidden = true
                hidden.append(v.layer!)
            }
            layer.render(in: ctx)
            hidden.forEach { $0.isHidden = false }
            // Glass containers render as an opaque white plate here;
            // repaint chrome over each and draw its content on top.
            // Each split column's hosting view, drawn directly: the
            // glass plates and scroll-edge portals over them render
            // white outside the window server.
            for host in Self.find(view, where: { { let n = String(describing: type(of: $0)); return (n.contains("SidebarStyleContext") || n.contains("InspectorStyleContext")) && !$0.isHiddenOrHasHiddenAncestor }($0) }) {
                let r = host.convert(host.bounds, to: nil)
                ctx.fill(r)
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                guard let cg = rep.cgImage else { continue }
                ctx.draw(cg, in: r)
            }
            // Plain split-view columns (Settings' HSplitView) also come out
            // white through layer rendering; drawing them directly works
            // where no scroll-edge portal is involved.
            for col in Self.find(view, where: { String(describing: type(of: $0)) == "_NSSplitViewItemViewWrapper" })
            where Self.find(col, where: { let n = String(describing: type(of: $0)); return n.contains("PortalView") || n.contains("ConcentricGlass") }).isEmpty {
                let r = col.convert(col.bounds, to: nil)
                // NavigationSplitView's detail wrapper spans the whole
                // window, under the sidebar; drawing it would cover it.
                guard r.width < view.bounds.width - 1, !col.isHiddenOrHasHiddenAncestor else { continue }
                let effects = Self.find(col, where: { $0 is NSVisualEffectView }) as! [NSVisualEffectView]
                let saved = effects.map { ($0.state, $0.material) }
                effects.forEach { $0.state = .inactive; $0.material = .underWindowBackground }
                defer { zip(effects, saved).forEach { $0.state = $1.0; $0.material = $1.1 } }
                guard r.width > 0, let rep = col.bitmapImageRepForCachingDisplay(in: col.bounds) else { continue }
                col.cacheDisplay(in: col.bounds, to: rep)
                guard let cg = rep.cgImage else { continue }
                ctx.fill(r)
                ctx.draw(cg, in: r)
            }
            // The title bar on top again, so titles and toolbar show.
            if let bar = Self.find(view, where: { String(describing: type(of: $0)) == "NSTitlebarContainerView" }).first,
               let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                bar.cacheDisplay(in: bar.bounds, to: rep)
                if let cg = rep.cgImage { ctx.draw(cg, in: bar.convert(bar.bounds, to: nil)) }
            }
            guard let image = ctx.makeImage() else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            let png = rep.representation(using: .png, properties: [:])
            try? png?.write(to: URL(fileURLWithPath: "\(LiveProbe.shots)/mac-\(name).png"))
        }
    }

    static func signedIn() async throws -> AppModel {
        let app = AppModel(host: host, tokenStore: InMemoryTokenStore(), authState: AuthState(), accountID: UUID())
        _ = try await app.client.auth.login(username: "admin", password: "admin-password-not-secret", clientLabel: "live-probe")
        await app.bootstrap()
        return app
    }

    @Test(.enabled(if: !shots.isEmpty))
    func tour() async throws {
        let app = try await Self.signedIn()
        let rig = Rig(app: app)
        await app.providers.load()
        await app.profiles.load()
        let convos = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
        await convos.refresh()
        let user = app.authState.currentUser!
        rig.mount(HomeView(user: user).environment(convos))
        await rig.pump(3)
        await rig.both("01-home")
        if let list = Rig.find(rig.window.contentView!, where: { String(describing: type(of: $0)).contains("ListCoreScrollView") }).first as? NSScrollView {
            list.contentView.scroll(to: NSPoint(x: 0, y: 360))
            list.reflectScrolledClipView(list.contentView)
            await rig.pump(0.6)
            await rig.both("01b-list-scrolled")
            list.contentView.scroll(to: .zero)
            list.reflectScrolledClipView(list.contentView)
        }
        for v in Rig.find(rig.window.contentView!.superview!, where: { let n = String(describing: type(of: $0)); return n == "_NSSplitViewItemViewWrapper" || n.contains("ConcentricGlass") || n.contains("StyleContext") }) {
            print("COL", String(describing: type(of: v)).prefix(110), v.convert(v.bounds, to: nil).integral, "hidden:", v.isHiddenOrHasHiddenAncestor, "alpha:", v.alphaValue, "window:", v.window != nil)
        }

        func open(_ title: String, _ shot: String) async {
            guard let c = convos.conversations.first(where: { $0.title == title }) else { print("PROBE missing \(title)"); return }
            convos.selectedID = c.id
            await rig.pump(4)
            await rig.both(shot)
        }
        await open("Markdown showcase", "02-markdown")

        for v in Rig.find(rig.window.contentView!.superview!, where: { let n = String(describing: type(of: $0)); return n.contains("ToolbarItemViewer") || n.contains("TitleField") || n.contains("TrackingSeparator") || n.contains("ToolbarTitle") || n.contains("TextField") }) {
            print("TBI", String(describing: type(of: v)).prefix(60), v.convert(v.bounds, to: nil).integral, (v as? NSTextField)?.stringValue ?? "", "hidden:", v.isHiddenOrHasHiddenAncestor)
        }
        print("TBI title:", rig.window.title, "subtitle:", rig.window.subtitle, "items:", rig.window.toolbar?.items.map { "\($0.itemIdentifier.rawValue)" } ?? [])
        await open("Branching demo", "03-branching")

        rig.navigator.inspectorShown = true
        await open("Scroll XL — 110 turns", "03b-inspector")
        rig.navigator.inspectorTab = .settings
        await rig.pump(2)
        await rig.both("03c-inspector-settings")
        rig.navigator.inspectorTab = .plugins
        await rig.pump(2)
        await rig.both("03d-inspector-plugins")
        rig.navigator.inspectorTab = .context
        rig.navigator.inspectorShown = false
        await open("Scroll Heavy — 60 × 800w", "04-heavy")
        await open("Scroll XL — 110 turns", "05-xl")

        // Send a turn and catch it mid-stream and after.
        let xl = convos.selectedID!
        func send(_ text: String) async {
            guard let tv = Rig.find(rig.window.contentView!, where: { $0 is ComposerNSTextView }).first as? ComposerNSTextView else {
                print("PROBE no composer"); return
            }
            rig.window.makeFirstResponder(tv)
            tv.insertText(text, replacementRange: NSRange(location: 0, length: 0))
            await rig.pump(0.3)
            tv.onSubmit?()
        }
        func waitStreamEnd() async {
            let end = Date().addingTimeInterval(40)
            await rig.pump(1)
            while app.streamHub.activeConversationIDs.contains(xl), Date() < end { await rig.pump(0.2) }
            await rig.pump(1.5)
        }
        await send("count 120")
        await rig.pump(1.5)
        await rig.both("06-streaming")
        await rig.pump(6)
        await rig.both("07-parked")
        await waitStreamEnd()
        await rig.both("07b-terminal")

        // Scroll up mid-stream: the viewport must stay where the user put it.
        await send("count again")
        await rig.pump(2)
        if let sv = Rig.find(rig.window.contentView!, where: { $0 is NSScrollView && $0.frame.width > 600 }).first {
            let p = sv.convert(NSPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: nil)
            for phase in [CGScrollPhase.began, .changed, .changed, .changed, .ended] {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: phase == .ended ? 0 : 120, wheel2: 0, wheel3: 0)!
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                cg.location = CGPoint(x: 0, y: 0)
                if let ev = NSEvent(cgEvent: cg) {
                    let located = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                    _ = located
                    sv.scrollWheel(with: ev)
                }
                await rig.pump(0.05)
            }
        } else { print("PROBE no scroll view") }
        await rig.pump(0.5)
        await rig.both("07c-scrolled-up")
        await rig.pump(3)
        await rig.both("07d-still-up")
        await waitStreamEnd()
        await rig.both("07e-terminal-up")

        rig.navigator.startNewConversation()
        await rig.pump(2.5)
        await rig.both("08-new")
        let before = convos.conversations.count
        if let tv = Rig.find(rig.window.contentView!, where: { $0 is ComposerNSTextView }).first as? ComposerNSTextView {
            rig.window.makeFirstResponder(tv)
            tv.insertText("bullet points please", replacementRange: NSRange(location: 0, length: 0))
            await rig.pump(0.3)
            tv.onSubmit?()
        }
        await rig.pump(5)
        await rig.both("08b-new-sent")
        print("PROBE draft created:", convos.conversations.count == before + 1, "selected:", convos.selectedID ?? "nil", "draft:", rig.navigator.draft?.createdID ?? "nil")
    }

    @Test(.enabled(if: !shots.isEmpty))
    func settingsTour() async throws {
        let app = try await Self.signedIn()
        let sz = (ProcessInfo.processInfo.environment["PSMITH_PROBE_SIZE"] ?? "1052x672").split(separator: "x").compactMap { Double($0) }
        let rig = Rig(app: app, size: CGSize(width: sz[0], height: sz[1]))
        await app.providers.load()
        await app.profiles.load()
        await app.mcpServers.load()
        let convos = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
        await convos.refresh()
        rig.mount(SettingsView(providersModel: app.providers, profilesModel: app.profiles, mcpServersModel: app.mcpServers).environment(convos))
        await rig.pump(2)
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let v = rig.window.standardWindowButton(b), let sv = rig.window.contentView?.superview {
                print("LIGHT", b.rawValue, v.convert(v.bounds, to: sv), "content height", sv.bounds.height)
            }
        }
        if rig.accounts.accounts.isEmpty {
            _ = try? await rig.accounts.addAccount(host: Self.host, username: "admin", password: "admin-password-not-secret")
        }
        if app.mcpServers.servers.isEmpty {
            _ = await app.mcpServers.upsert(id: nil, name: "GitHub", transport: "http", url: "https://api.githubcopilot.com/mcp/", headers: "Authorization: Bearer probe", toolPrefix: "gh_")
        }
        // The boards' states, where the server holds them.
        await app.preferences.setContextWarningTokens(120_000)
        let only = ProcessInfo.processInfo.environment["PSMITH_PROBE_ONLY"]?.split(separator: ",").map(String.init)
        for (i, c) in SettingsCategory.allCases.enumerated() {
            if let only, !only.contains(c.label.replacingOccurrences(of: " ", with: "")) { continue }
            rig.navigator.settingsCategory = c
            await rig.pump(2.5)
            await rig.both(String(format: "s%02d-%@", i, c.label.replacingOccurrences(of: " ", with: "")))
            if c == .models {
                for (k, t) in [SettingsProviderTab.connection, .defaults].enumerated() {
                    rig.navigator.settingsProviderTab = t
                    await rig.pump(1.5)
                    rig.snap(String(format: "s%02d%d-ModelsTab", i, k))
                }
                rig.navigator.settingsProviderTab = .models
                if let first = app.providers.enabledModels.first {
                    app.providers.detailMode = .editingModel(first.modelID)
                    await rig.pump(1.5)
                    rig.snap(String(format: "s%02d-ModelPage", i))
                }
                app.providers.detailMode = .addingManualModel
                await rig.pump(1)
                rig.snap(String(format: "s%02d-ModelAdd", i))
                app.providers.detailMode = .adding
                await rig.pump(1.5)
                rig.snap(String(format: "s%02d-ProviderAdd", i))
                app.providers.detailMode = .viewing
                await rig.pump(0.5)
            }
            if c == .profiles {
                for (k, t) in [SettingsProfileTab.prompt, .model, .plugins, .automation].enumerated() {
                    rig.navigator.settingsProfileTab = t
                    await rig.pump(1.5)
                    rig.snap(String(format: "s%02d%d-ProfilesTab", i, k))
                }
                rig.navigator.settingsProfileTab = .general
                app.profiles.detailMode = .adding
                await rig.pump(1.5)
                rig.snap(String(format: "s%02d-ProfileNew", i))
                app.profiles.detailMode = .viewing
                await rig.pump(0.5)
            }
            if c == .integrations {
                for (j, item) in SettingsIntegration.allCases.enumerated() {
                    rig.navigator.settingsIntegration = item
                    await rig.pump(2)
                    await rig.both(String(format: "s%02d%d-%@", i, j, item.label.replacingOccurrences(of: " ", with: "")))
                }
            }
        }
    }

    /// Every pane at the window's minimum and at two larger sizes.
    @Test(.enabled(if: !shots.isEmpty))
    func settingsResize() async throws {
        let app = try await Self.signedIn()
        let rig = Rig(app: app, size: CGSize(width: 1052, height: 600))
        await app.providers.load()
        await app.profiles.load()
        await app.mcpServers.load()
        if rig.accounts.accounts.isEmpty {
            _ = try? await rig.accounts.addAccount(host: Self.host, username: "admin", password: "admin-password-not-secret")
        }
        let convos = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
        rig.mount(SettingsView(providersModel: app.providers, profilesModel: app.profiles, mcpServersModel: app.mcpServers).environment(convos))
        await rig.pump(2)
        for size in [CGSize(width: 1052, height: 600), CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1200)] {
            rig.window.setContentSize(size)
            for (i, c) in SettingsCategory.allCases.enumerated() {
                rig.navigator.settingsCategory = c
                await rig.pump(1.5)
                rig.snap(String(format: "r%04d-%02d-%@", Int(size.width), i, c.label))
            }
        }
    }

    @Test(.enabled(if: !shots.isEmpty))
    func sidebarModes() async throws {
        let app = try await Self.signedIn()
        let rig = Rig(app: app)
        await app.providers.load()
        await app.profiles.load()
        let convos = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
        await convos.refresh()
        rig.mount(HomeView(user: app.authState.currentUser!).environment(convos))
        await rig.pump(2)
        convos.listMode = .byProfile
        await convos.refresh()
        await rig.pump(1.5)
        await rig.both("sb1-byprofile")
        convos.listMode = .search
        convos.searchQuery = "Scroll"
        await convos.refresh()
        await rig.pump(1.5)
        await rig.both("sb2-search")
        convos.searchQuery = "zzzz-nothing"
        await convos.refresh()
        await rig.pump(1.5)
        await rig.both("sb3-search-none")
        convos.listMode = .allChats
        convos.searchQuery = ""
        await convos.refresh()
        if let victim = convos.conversations.first(where: { $0.title?.hasPrefix("Demo Assistant") == true }) {
            await convos.archive(victim.id)
        }
        await rig.pump(1)
        print("PROBE archived count before view:", convos.archivedConversations.count)
    }

    /// The list toggle, driven the way a person drives it: ⌃⌘S, then
    /// again, with captures mid-animation and settled.
    @Test(.enabled(if: !shots.isEmpty))
    func listToggle() async throws {
        let app = try await Self.signedIn()
        let rig = Rig(app: app)
        await app.providers.load()
        await app.profiles.load()
        let convos = ConversationsModel(client: app.client, profiles: app.profiles, hub: app.streamHub)
        await convos.refresh()
        rig.mount(HomeView(user: app.authState.currentUser!).environment(convos))
        await rig.pump(2)
        if let c = convos.conversations.first(where: { $0.title == "Markdown showcase" }) { convos.selectedID = c.id }
        await rig.pump(3)
        await rig.real("lt0-open")
        for v in Rig.find(rig.window.contentView!.superview!, where: { $0 is NSSplitView }) {
            let sv = v as! NSSplitView
            print("PROBE splitview delegate:", sv.delegate.map { String(describing: type(of: $0)) } ?? "nil")
            if let c = sv.delegate as? NSSplitViewController {
                print("PROBE items:", c.splitViewItems.map { "\($0.behavior.rawValue) collapsed:\($0.isCollapsed) canCollapse:\($0.canCollapse)" })
            }
        }
        var chain: [String] = []
        var q: [NSViewController] = rig.window.contentViewController.map { [$0] } ?? []
        while !q.isEmpty { let c = q.removeFirst(); chain.append(String(describing: type(of: c)).prefix(50).description); q += c.children }
        print("PROBE vcs:", rig.window.contentViewController == nil ? "no contentVC" : chain.joined(separator: ", "))
        rig.navigator.listShown = false
        await rig.pump(0.12)
        await rig.real("lt1-hiding")
        await rig.pump(1.5)
        await rig.real("lt2-hidden")
        rig.navigator.listShown = true
        await rig.pump(1.5)
        await rig.real("lt4-shown")
        // The system's own toggle, as the old View menu item sent it.
        for v in Rig.find(rig.window.contentView!.superview!, where: { $0 is NSSplitView }) { print("PROBE split", (v as! NSSplitView).subviews.map { "\($0.frame.integral) hidden:\($0.isHidden)" }) }
        print("PROBE toggleSidebar sent:", NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: rig.window))
        await rig.pump(1.5)
        await rig.real("lt4b-after-system-toggle")
        if let list = Rig.find(rig.window.contentView!, where: { String(describing: type(of: $0)).contains("ListCoreScrollView") }).first as? NSScrollView {
            list.contentView.scroll(to: NSPoint(x: 0, y: 200))
            list.reflectScrolledClipView(list.contentView)
            await rig.pump(0.6)
            await rig.real("lt4c-list-scrolled")
        }
        rig.window.setContentSize(NSSize(width: 900, height: 700))
        await rig.pump(1)
        await rig.real("lt5-narrow")
    }

    /// Launch with the server down, after a session that filled this
    /// account's cache: the chats should render from cache under the
    /// offline banner, not a spinner and not onboarding.
    @Test(.enabled(if: !shots.isEmpty))
    func launchWithServerDown() async throws {
        let account = UUID()
        let tokens = InMemoryTokenStore()
        let live = AppModel(host: Self.host, tokenStore: tokens, authState: AuthState(), accountID: account)
        _ = try await live.client.auth.login(username: "admin", password: "admin-password-not-secret", clientLabel: "live-probe")
        await live.bootstrap()
        await live.providers.load()
        await live.profiles.load()
        let warm = ConversationsModel(client: live.client, profiles: live.profiles, hub: live.streamHub)
        await warm.refresh()
        let token = try tokens.load() ?? ""
        print("PROBE warm conversations:", warm.conversations.count)

        let start = Date()
        let dead = AppModel(host: URL(string: "http://127.0.0.1:9")!, tokenStore: InMemoryTokenStore(initial: token), authState: AuthState(), accountID: account)
        let rig = Rig(app: dead)
        rig.mount(RootView())
        Task { await dead.bootstrap() }
        for t in [1.0, 2.0, 4.0, 8.0] {
            await rig.pump(t - Date().timeIntervalSince(start) > 0 ? t - Date().timeIntervalSince(start) : 0.1)
            rig.snap(String(format: "off-%02.0fs", t))
            print("PROBE t=\(t) phase=\(dead.authState.phase) providersLoaded=\(dead.providers.hasLoadedOnce) onboarding=\(dead.providers.needsOnboarding) connectivity=\(dead.connectivity.state)")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Psmith/Accounts/\(account.uuidString)"))
    }
}

/// Reports itself key and main, so controls and materials draw in their
/// active state (what the user sees with the app in front) without the
/// test process activating and taking focus.
final class KeyedWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    /// Offscreen captures of tall boards need windows taller than the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isMainWindow: Bool { true }
}
