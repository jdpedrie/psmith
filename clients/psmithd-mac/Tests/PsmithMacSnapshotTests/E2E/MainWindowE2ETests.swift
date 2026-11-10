import Testing
import AppKit
@testable import PsmithMac
import PsmithKit

/// The main window end to end: the real HomeView against psmithd, in an
/// offscreen window bridged to its title bar the way a WindowGroup is.
/// Row actions go through the rows' own context menus (asked for, never
/// shown); everything that persists is read back from the server.
@Suite(.serialized, .enabled(if: MacE2E.enabled))
@MainActor
struct MainWindowE2ETests {
    /// Title-bar text fields that would draw. The reading pane's header
    /// draws the conversation's title; the system's must not.
    private func drawnTitles(_ window: NSWindow) -> [String] {
        guard let frame = window.contentView?.superview else { return [] }
        return (LiveProbe.Rig.find(frame) { v in
            guard let f = v as? NSTextField, !f.stringValue.isEmpty else { return false }
            return !f.isHiddenOrHasHiddenAncestor && f.alphaValue > 0 && f.frame.width > 0
                && String(describing: type(of: v)).contains("Title")
        } as! [NSTextField]).map(\.stringValue)
    }

    // MARK: Title bar

    @Test func theTitleBarNeverDrawsTheConversationTitle() async throws {
        try await MacE2E.run { e in
            let one = try await e.makeConversation("Gamemaster")
            let two = try await e.makeConversation("Second")
            try await e.seedTurn(one, "echo maple")
            let w = await e.mountHome()
            #expect(drawnTitles(w).isEmpty)

            await e.open(one, minMessages: 2)
            #expect(w.title.contains("Gamemaster"), "the window still names the conversation for the Window menu")
            #expect(drawnTitles(w).isEmpty, "the title bar drew \(drawnTitles(w))")

            // Switching conversations changes the title again.
            await e.open(two)
            await e.spin(0.5)
            #expect(drawnTitles(w).isEmpty, "the title bar drew \(drawnTitles(w))")

            // And a rename that arrives while it's open.
            _ = try await e.app.client.conversations.updateTitle(id: two.id, title: "Renamed \(e.seed.tag)")
            await e.convos.refresh()
            await e.spin(0.6)
            #expect(drawnTitles(w).isEmpty, "the title bar drew \(drawnTitles(w))")
        }
    }

    // MARK: List

    @Test func searchNarrowsTheListToMatchingTitles() async throws {
        try await MacE2E.run { e in
            let keep = try await e.makeConversation("Lighthouse keeper")
            _ = try await e.makeConversation("Orchard plan")
            await e.mountHome()
            let field = try #require(e.field("Search conversations") ?? e.textFields().first)
            await e.type("Lighthouse keeper \(e.seed.tag)", into: field)
            await e.waitFor("search never narrowed the list", timeout: 8) {
                e.labels().contains { $0.hasPrefix("Lighthouse keeper \(e.seed.tag)") }
                    && !e.labels().contains { $0.hasPrefix("Orchard plan \(e.seed.tag)") }
            }
            await e.press(containing: "Lighthouse keeper \(e.seed.tag)")
            await e.waitFor("picking a result didn't open it") { e.model?.conversation.id == keep.id }
        }
    }

    @Test func clickingARowOpensIt() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Click me")
            try await e.seedTurn(conv, "echo cedar")
            await e.mountHome()
            await e.press(containing: "Click me \(e.seed.tag)")
            await e.waitFor("the row didn't open its conversation") {
                e.model?.conversation.id == conv.id && (e.model?.messages.count ?? 0) >= 2
            }
            await e.waitForText("heard cedar")
        }
    }

    @Test func pinFromTheRowMenuPinsOnTheServer() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Pin target")
            await e.mountHome()
            await e.contextMenu(on: "Pin target \(e.seed.tag)", choose: "Pin")
            await e.eventually("the pin never reached the server") {
                try await e.app.client.conversations.get(id: conv.id).0.pinnedAt != nil
            }
            await e.press("Pinned")
            await e.waitFor("the Pinned filter doesn't show it") {
                e.labels().contains { $0.hasPrefix("Pin target \(e.seed.tag)") }
            }
            // The in-process accessibility walk keeps a row's first set of
            // actions (no assistive client is listening for the change);
            // a fresh window reads them anew.
            await e.mountHome()
            await e.contextMenu(on: "Pin target \(e.seed.tag)", choose: "Unpin")
            await e.eventually("the unpin never reached the server") {
                try await e.app.client.conversations.get(id: conv.id).0.pinnedAt == nil
            }
        }
    }

    @Test func renameFromTheRowMenuRenamesOnTheServer() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Old name")
            let w = await e.mountHome()
            await e.contextMenu(on: "Old name \(e.seed.tag)", choose: "Rename")
            let field = try #require(await firstEditableField(e), "the row didn't turn into a rename field")
            await e.type("New name \(e.seed.tag)", into: field)
            if let editor = field.currentEditor() { e.key(editor, 36, "\r") }
            await e.eventually("the rename never reached the server") {
                try await e.app.client.conversations.get(id: conv.id).0.title == "New name \(e.seed.tag)"
            }
            await e.waitFor("the row didn't show the new name") {
                e.labels().contains { $0.hasPrefix("New name \(e.seed.tag)") }
            }
            #expect(drawnTitles(w).isEmpty)
        }
    }

    @Test func archiveThenUnarchiveFromTheArchive() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Archive me")
            // The Archived row draws under the list's rows; this test goes
            // that way (anEmptyListOpensTheArchive covers the empty list).
            _ = try await e.makeConversation("Keep me")
            await e.mountHome()
            await e.contextMenu(on: "Archive me \(e.seed.tag)", choose: "Archive")
            await e.eventually("the archive never reached the server") {
                try await e.app.client.conversations.get(id: conv.id).0.archivedAt != nil
            }
            await e.waitFor("the archived row stayed in the list") {
                !e.labels().contains { $0.hasPrefix("Archive me \(e.seed.tag)") }
            }
            await e.mountHome()
            await e.press("Archived")
            await e.waitFor("the archive doesn't list it", timeout: 8) {
                e.labels().contains { $0.hasPrefix("Archive me \(e.seed.tag)") }
            }
            await e.contextMenu(on: "Archive me \(e.seed.tag)", choose: "Unarchive")
            await e.eventually("the unarchive never reached the server") {
                try await e.app.client.conversations.get(id: conv.id).0.archivedAt == nil
            }
        }
    }

    @Test func anEmptyListOpensTheArchive() async throws {
        try await MacE2E.run { e in
            // Every suite shares one user; this test needs none active.
            var parked: [String] = []
            while true {
                let page = try await e.app.client.conversations.list(pageSize: 100)
                if page.items.isEmpty { break }
                for c in page.items { try await e.app.client.conversations.archive(id: c.id); parked.append(c.id) }
            }
            let mine = try await e.makeConversation("Only archived")
            try await e.app.client.conversations.archive(id: mine.id)
            await e.mountHome()
            await e.waitFor("the empty list didn't say it", timeout: 8) {
                e.labels().contains("No active conversations")
            }
            await e.press(containing: "Archived, ")
            await e.waitFor("the button didn't open the archive", timeout: 8) {
                e.labels().contains { $0.hasPrefix("Only archived \(e.seed.tag)") }
            }
            for id in parked + [mine.id] { try? await e.app.client.conversations.unarchive(id: id) }
        }
    }

    @Test func deleteConfirmsInPlaceThenDeletes() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Doomed")
            await e.mountHome()
            await e.contextMenu(on: "Doomed \(e.seed.tag)", choose: "Delete…")
            await e.waitFor("the row didn't turn into a confirm card") {
                e.labels().contains { $0.contains("Delete “Doomed \(e.seed.tag)”?") }
            }
            // Cancel leaves it.
            await e.press("Cancel")
            await e.waitFor("Cancel didn't bring the row back") {
                e.labels().contains { $0.hasPrefix("Doomed \(e.seed.tag)") }
            }
            await e.contextMenu(on: "Doomed \(e.seed.tag)", choose: "Delete…")
            await e.press("Delete")
            await e.eventually("the delete never reached the server") {
                do { _ = try await e.app.client.conversations.get(id: conv.id); return false } catch { return true }
            }
            await e.waitFor("the deleted row is still listed") {
                !e.labels().contains { $0.hasPrefix("Doomed \(e.seed.tag)") }
            }
        }
    }

    @Test func aClickedNotificationOpensItsConversation() async throws {
        try await MacE2E.run { e in
            let target = try await e.makeConversation("Notified")
            try await e.seedTurn(target, "echo cedar")
            let other = try await e.makeConversation("Reading")
            await e.mountHome()
            await e.open(other)
            // What MacNotifier sets when a "reply ready" banner is clicked.
            e.navigator.pendingConversationSelection = target.id
            await e.waitFor("the notification didn't open its conversation") {
                e.model?.conversation.id == target.id && (e.model?.messages.count ?? 0) >= 2
            }
            #expect(e.navigator.pendingConversationSelection == nil)

            // One made elsewhere after the list loaded.
            let late = try await e.makeConversation("Made elsewhere")
            e.navigator.pendingConversationSelection = late.id
            await e.waitFor("a conversation the list hadn't loaded didn't open") {
                e.model?.conversation.id == late.id
            }
        }
    }

    @Test func hidingTheListAndBringingItBack() async throws {
        try await MacE2E.run { e in
            await e.mountHome()
            await e.press("Hide the conversation list (⌃⌘S)")
            await e.waitFor("the list didn't hide") { !e.navigator.listShown }
            #expect(!e.labels().contains("Search conversations"))
            // ⌃⌘S is a menu-bar command, outside the window; the header's
            // button runs the same toggle.
            await e.press(containing: "Show the conversation list")
            await e.waitFor("the list didn't come back") { e.navigator.listShown }
        }
    }

    // MARK: New conversation

    @Test func newConversationKeepsProfileAndModelThroughTheModelPage() async throws {
        try await MacE2E.run { e in
            let w = await e.mountHome()
            await e.press("New conversation (⌘N)")
            await e.waitFor("the start screen never showed") { e.model?.isDraft == true }
            await e.waitForText("who are you talking to")
            // Pick Beta from its card.
            await e.press(containing: "Beta \(e.seed.tag)")
            await e.waitFor("Beta wasn't chosen") { e.model?.draftProfile?.id == e.seed.beta.id }
            // The model page, model-two, back.
            let draftModel = try #require(e.model)
            // The header's model menu is native (it can't be opened headlessly);
            // its All Models… item sets this page.
            e.navigator.page = .models
            await e.waitFor("the model page didn't open") { e.navigator.page == .models }
            await e.press(containing: "Model Two")
            await e.waitFor("model-two wasn't chosen") { e.model?.selectedModelID == "model-two" }
            if e.navigator.page != nil { e.navigator.page = nil }
            await e.spin(0.5)
            #expect(e.model === draftModel, "the draft's view model was rebuilt")
            #expect(e.model?.draftProfile?.id == e.seed.beta.id, "the profile reset after the model page")
            #expect(e.model?.selectedModelID == "model-two", "the model reset after the model page")

            await e.sendAndWatch("mac-new-conversation", text: "echo juniper", user: "echo juniper", reply: "heard juniper")
            let created = try #require(e.model?.conversation)
            #expect(!created.id.isEmpty && e.model?.isDraft == false)
            await e.eventually("the conversation wasn't created with Beta and model-two") {
                let (c, _) = try await e.app.client.conversations.get(id: created.id)
                return c.profileID == e.seed.beta.id
            }
            let msgs = try await e.messages(created)
            #expect(msgs.last { $0.role == .assistant }?.modelID == "model-two")
            await e.waitFor("the new conversation isn't selected in the list") { e.convos.selectedID == created.id }
            #expect(drawnTitles(w).isEmpty)
        }
    }

    @Test func theStartScreenScrollsWhenProfilesOverflow() async throws {
        try await MacE2E.run { e in
            var extra: [String] = []
            for i in 1...30 {
                let p = try await e.app.client.profiles.create(PsmithProfilePatch(name: "Overflow \(i) \(e.seed.tag)",
                    description: "One of many profiles."))
                extra.append(p.id)
            }
            defer { Task { for id in extra { try? await e.app.client.profiles.delete(id: id) } } }
            await e.app.profiles.load()
            while e.app.profiles.hasMore { await e.app.profiles.loadMore() }
            await e.convos.refresh()
            await e.mountHome(size: CGSize(width: 1080, height: 620))
            await e.press("New conversation (⌘N)")
            await e.waitFor("the start screen never showed") { e.model?.isDraft == true }
            await e.spin(0.6)
            let sv = try #require(e.scrollView(), "no scroll view")
            let doc = sv.documentView?.frame.height ?? 0
            #expect(doc > sv.contentView.bounds.height + 300, "the profiles are clipped to the window")
            let before = sv.contentView.bounds.origin.y
            await e.scroll(sv, dy: -4000)
            #expect(sv.contentView.bounds.origin.y - before > 300, "the start screen didn't scroll")
            // The last card can be picked once scrolled to.
            await e.press(containing: "Overflow 30 \(e.seed.tag)")
            await e.waitFor("the last profile couldn't be chosen") { e.model?.draftProfile?.name == "Overflow 30 \(e.seed.tag)" }
            for id in extra { try? await e.app.client.profiles.delete(id: id) }
            extra = []
        }
    }

    private func firstEditableField(_ e: MacE2E) async -> NSTextField? {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if let f = e.textFields().first(where: { $0.stringValue.contains("Old name") }) { return f }
            await e.spin(0.1)
        }
        return nil
    }
}
