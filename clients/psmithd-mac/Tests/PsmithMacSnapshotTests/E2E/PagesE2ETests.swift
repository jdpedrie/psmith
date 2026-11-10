import Testing
import AppKit
@testable import PsmithMac
import PsmithKit
import PsmithUI

/// The conversation inspector and the pages that open in the reading
/// column, against a real server. Every change is read back from the
/// server, and every surface is opened and closed before a watched send,
/// the iOS regression where a reply vanished after a page closed.
@Suite(.serialized, .enabled(if: MacE2E.enabled))
@MainActor
struct PagesE2ETests {
    static let inspectorButton = "Show the inspector (⌥⌘I)"

    @Test func inspectorOpensAndClosesFromButtonAndShortcut() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Inspector")
            try await e.seedTurn(conv, "echo maple")
            await e.mountHome()
            await e.open(conv, minMessages: 2)
            #expect(!e.navigator.inspectorShown)

            await e.press(Self.inspectorButton)
            await e.waitFor("the button never opened the inspector") { e.navigator.inspectorShown }
            await e.waitForText("context size")
            #expect(e.element("Plugins") != nil, "the inspector's tabs aren't on screen: \(e.labels())")
            await e.press(Self.inspectorButton)
            await e.waitFor("the button never closed the inspector") { !e.navigator.inspectorShown }
            #expect(!e.screenText().contains("context size"))

            await e.shortcut(34, "i", modifiers: [.command, .option])
            await e.waitFor("⌥⌘I never opened the inspector") { e.navigator.inspectorShown }
            await e.waitForText("context size")
            await e.shortcut(34, "i", modifiers: [.command, .option])
            await e.waitFor("⌥⌘I never closed the inspector") { !e.navigator.inspectorShown }

            await e.sendAndWatch("pages-inspector-closed")
        }
    }

    @Test func contextTabSwitchesAndDeletesContexts() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Contexts")
            try await e.seedTurn(conv, "echo maple")
            let (_, first) = try await e.app.client.conversations.get(id: conv.id)
            let second = try await e.app.client.conversations.createContextManual(
                conversationID: conv.id, initialUserMessage: "begin again with cedar", mode: .replace).context
            #expect(try await e.app.client.conversations.get(id: conv.id).1.id == second.id)

            await e.mountHome()
            await e.open(conv, minMessages: 1)
            await e.press(Self.inspectorButton)
            await e.press("Context")
            await e.waitFor("the inspector never listed both contexts") { e.model?.contexts.count == 2 }
            await e.waitForText("cedar")
            // The server titles the first context; the inspector numbers
            // an untitled one.
            let firstTitle = try #require(e.model?.contexts.first { $0.id == first.id }?.title)

            // Pressing the archived row switches to it: the server's
            // active context and the transcript follow.
            await e.press(containing: firstTitle)
            await e.eventually("the server never switched to the first context") {
                try await e.app.client.conversations.get(id: conv.id).1.id == first.id
            }
            await e.waitForText("heard maple")
            #expect(e.model?.activeContext?.id == first.id)

            // Delete asks in place first; Cancel keeps the context.
            await e.contextAction("Delete Context…", onRow: "Context 2")
            await e.waitForText("delete context 2?")
            await e.press("Cancel")
            #expect(try await e.app.client.conversations.listContexts(conversationID: conv.id).count == 2)

            await e.contextAction("Delete Context…", onRow: "Context 2")
            await e.press("Delete Context")
            await e.eventually("the server never deleted the second context") {
                try await e.app.client.conversations.listContexts(conversationID: conv.id).map(\.id) == [first.id]
            }
            await e.waitFor("the inspector still lists the deleted context") { e.model?.contexts.count == 1 }

            await e.press(Self.inspectorButton)
            await e.sendAndWatch("pages-after-contexts")
        }
    }

    @Test func settingsTabEditsSavesAndDiscardsCallSettings() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Call settings")
            _ = try await e.app.client.conversations.updateSettings(id: conv.id, settings: PsmithConversationSettings(
                defaultProviderID: e.seed.provider.id, defaultModelID: "model-one",
                callSettings: PsmithCallSettings(temperature: 0.7)))
            try await e.seedTurn(conv, "echo maple")
            await e.mountHome()
            await e.open(conv, minMessages: 2)

            await e.press(Self.inspectorButton)
            await e.press("Settings")
            await e.waitFor("the Settings tab never showed") { e.navigator.inspectorTab == .settings }
            await e.waitForText("temperature")
            await e.waitForText("0.7")
            await e.waitForText("this conversation")

            await e.press(containing: "Edit Call Settings")
            await e.waitFor("Edit Call Settings never opened the page") { e.navigator.page == .callSettings }
            await e.waitForText("max output tokens")

            // Saved: the edit lands on the conversation and keeps what
            // was already set there.
            await e.setMaxOutput("4096")
            await e.press("Save")
            await e.eventually("Save never wrote the conversation's call settings") {
                let cs = try await e.app.client.conversations.get(id: conv.id).0.settings?.callSettings
                return cs?.maxOutputTokens == 4096 && cs?.temperature == 0.7
            }
            await e.waitFor("the save bar stayed after saving") { e.element("Save") == nil }
            await e.waitForText("4,096")

            // Discarded: the draft goes back and nothing is written.
            await e.setMaxOutput("8192")
            await e.press("Discard")
            await e.waitFor("Discard never restored the draft") {
                e.model?.conversationCallSettingsDraft.maxOutputTokens == 4096 && e.element("Save") == nil
            }
            await e.spin(0.5)
            let cs = try await e.app.client.conversations.get(id: conv.id).0.settings?.callSettings
            #expect(cs?.maxOutputTokens == 4096, "Discard wrote to the server: \(String(describing: cs))")

            await e.pressBreadcrumbBack(conv)
            await e.waitFor("the breadcrumb never went back") { e.navigator.page == nil }
            await e.press(Self.inspectorButton)
            await e.sendAndWatch("pages-after-call-settings")
        }
    }

    @Test func pluginsTabTurnsAProfilePluginOffForThisConversation() async throws {
        try await MacE2E.run { e in
            _ = try await e.app.client.profiles.setProfilePlugins(profileID: e.seed.alpha.id, plugins: [
                PsmithProfilePlugin(pluginName: "basic_grounding", ordinal: 0, config: Data("{}".utf8))])
            let conv = try await e.makeConversation("Plugins")
            try await e.seedTurn(conv, "echo maple")
            await e.mountHome()
            await e.open(conv, minMessages: 2)

            await e.press(Self.inspectorButton)
            await e.press("Plugins")
            await e.waitFor("the profile's plugin never listed") { e.value("Basic Grounding") == "1" }
            await e.waitForText("profile")

            await e.press("Basic Grounding")
            await e.eventually("turning it off never wrote a conversation override") {
                let o = try await e.app.client.conversations.getPlugins(conversationID: conv.id)
                return o.map(\.pluginName) == ["basic_grounding"] && o.first?.disabled == true
            }
            await e.eventually("the server still runs the plugin for the conversation") {
                try await e.app.client.conversations.resolvePipeline(conversationID: conv.id).isEmpty
            }
            await e.waitFor("the switch never showed off") { e.value("Basic Grounding") == "0" }
            #expect(try await e.app.client.profiles.getProfilePlugins(profileID: e.seed.alpha.id).map(\.pluginName) == ["basic_grounding"],
                    "turning it off for the conversation changed the profile")

            await e.press("Basic Grounding")
            await e.eventually("turning it back on never cleared the override") {
                try await e.app.client.conversations.getPlugins(conversationID: conv.id).isEmpty
            }
            await e.waitFor("the switch never showed on") { e.value("Basic Grounding") == "1" }

            await e.press(Self.inspectorButton)
            await e.sendAndWatch("pages-after-plugins")
        }
    }

    @Test func modelsPagePicksModelTwoAndKeepsTheDraft() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Models")
            try await e.seedTurn(conv, "echo maple")
            await e.mountHome()
            await e.open(conv, minMessages: 2)
            let draft = "a half-written thought about kelp"

            // Back from the page without a pick.
            await e.typeDraft(draft)
            await e.openModelsPage()
            await e.waitForText("model for this conversation")
            await e.pressBreadcrumbBack(conv)
            await e.waitFor("the breadcrumb never went back") { e.navigator.page == nil }
            await e.waitFor("the draft was lost going back") { e.composer()?.string == draft }

            // A pick persists and goes back.
            await e.openModelsPage()
            await e.press(containing: "Model Two")
            await e.waitFor("picking a model never went back to the transcript") { e.navigator.page == nil }
            await e.eventually("the pick never reached the server") {
                try await e.app.client.conversations.get(id: conv.id).0.settings?.defaultModelID == "model-two"
            }
            await e.waitForText("model two")
            await e.waitFor("the draft was lost across the pick") { e.composer()?.string == draft }

            await e.press(Self.inspectorButton)
            await e.sendAndWatch("pages-after-models")
            let last = try await e.messages(conv).last { $0.role == .assistant }
            #expect(last?.modelID == "model-two", "the send after the pick used \(last?.modelID ?? "nil")")
        }
    }

    @Test func modelsPageGoesBackToTheProfilesModel() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Back to profile")
            try await e.seedTurn(conv, "echo maple")
            await e.mountHome()
            await e.open(conv, minMessages: 2)
            await e.openModelsPage()
            await e.press(containing: "Model Two")
            await e.eventually("the pick never reached the server") {
                try await e.app.client.conversations.get(id: conv.id).0.settings?.defaultModelID == "model-two"
            }
            // The inspector's Model row now names the pin, so the page is
            // opened the way its row does.
            e.navigator.page = .models
            await e.press(containing: "Use the profile’s model")
            await e.waitFor("the clear row never went back") { e.navigator.page == nil }
            await e.eventually("the pin is still on the server") {
                (try await e.app.client.conversations.get(id: conv.id).0.settings?.defaultModelID ?? "").isEmpty
            }
            await e.waitFor("the view model still pins a model") { e.model?.pinsModel == false }
            await e.sendAndWatch("pages-after-profile-model")
            let last = try await e.messages(conv).last { $0.role == .assistant }
            #expect(last?.modelID != "model-two", "the send after clearing still used model-two")
        }
    }

    @Test func escapeGoesBackFromAPage() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Escape")
            try await e.seedTurn(conv, "echo maple")
            await e.mountHome()
            await e.open(conv, minMessages: 2)
            e.navigator.page = .models
            await e.waitForText("model for this conversation")
            await e.shortcut(53, "\u{1b}", modifiers: [])
            await e.waitFor("Escape didn't leave the models page") { e.navigator.page == nil }
        }
    }

    @Test func fullTextPageOpensFromALongMessage() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Full text")
            let paragraph = "The eager stack makes every offset exact, so the follow logic never guesses where a row lands.\n\n"
            let long = "echo walrus\n\n" + String(repeating: paragraph, count: MarkdownBudget.inlineLimit / paragraph.count + 20)
            try await e.seedTurn(conv, long)
            await e.mountHome()
            await e.open(conv, minMessages: 2)

            await e.press(containing: "Show full text")
            await e.waitFor("Show full text never opened the full-text page") {
                if case .fullText(_, let markdown) = e.navigator.page { return markdown == long }
                return false
            }
            await e.waitForText("eager stack")
            #expect(e.window?.attachedSheet == nil, "the full text opened as a sheet")

            await e.pressBreadcrumbBack(conv)
            await e.waitFor("the breadcrumb never went back") { e.navigator.page == nil }
            await e.sendAndWatch("pages-after-full-text")
        }
    }

    @Test func imagePageOpensFromAnAttachment() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Image")
            let file = try await e.app.client.files.upload(data: Self.png(), mimeType: "image/png", originalFilename: "tidal-chart.png")
            _ = try await e.app.client.conversations.sendMessage(conversationID: conv.id, content: "echo heron", attachmentFileIDs: [file.id])
            await e.eventually("the seeded image turn never got a reply", timeout: 20) {
                try await e.messages(conv).contains { $0.role == .assistant }
            }
            await e.mountHome()
            await e.open(conv, minMessages: 2)

            await e.press("tidal-chart.png")
            await e.waitFor("the thumbnail never opened the image page") {
                if case .image(_, let fileID, let name) = e.navigator.page { return fileID == file.id && name == "tidal-chart.png" }
                return false
            }
            await e.waitForText("double-click to zoom")

            await e.shortcut(33, "[", modifiers: .command)
            await e.waitFor("⌘[ never went back") { e.navigator.page == nil }
            await e.sendAndWatch("pages-after-image")
        }
    }

    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 48).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

private extension MacE2E {
    /// Types into the composer without sending.
    func typeDraft(_ text: String) async {
        await waitFor("no composer on screen") { composer()?.isEditable == true }
        guard let view = composer() else { return }
        view.window?.makeFirstResponder(view)
        view.selectAll(nil)
        view.insertText(text, replacementRange: view.selectedRange())
        await spin(0.3)
    }

    /// The Model row at the top of the inspector's Settings tab.
    func openModelsPage() async {
        if !navigator.inspectorShown { await press(PagesE2ETests.inspectorButton) }
        await press("Settings")
        await press(containing: "From Alpha")
        await waitFor("the Model row never opened the models page") { navigator.page == .models }
        await press(PagesE2ETests.inspectorButton)
    }

    /// A page's breadcrumb back to the conversation, named by its title.
    func pressBreadcrumbBack(_ conv: PsmithConversation) async {
        await press(conv.title ?? "Untitled")
    }

    /// Max output tokens on the call settings page: typed, then Return.
    func setMaxOutput(_ text: String) async {
        await waitFor("no Value field on the call settings page") { field("Value") != nil }
        guard let f = field("Value") else { return }
        await type(text, into: f)
        if let editor = f.currentEditor() as? NSTextView { editor.insertNewline(nil) }
        await spin(0.3)
    }

    /// The inspector's context row whose label starts with `title`.
    func contextRow(_ title: String) -> NSObject? {
        elements().last { Self.name($0).hasPrefix(title + ",") }
    }

    /// A context row's menu item, through the row's accessibility actions.
    func contextAction(_ name: String, onRow title: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitFor("no row for \(title)", sourceLocation: sourceLocation) { contextRow(title) != nil }
        guard let row = contextRow(title) else { return }
        let actions = (Self.ax(row, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
        guard let action = actions.first(where: { $0.name == name }) else {
            Issue.record("\(title)'s row has no “\(name)” action. Has: \(actions.map(\.name))", sourceLocation: sourceLocation)
            return
        }
        if let handler = action.handler { _ = handler() } else if let target = action.target, let sel = action.selector {
            _ = (target as AnyObject).perform(sel, with: action)
        }
        await spin(0.4)
    }
}
