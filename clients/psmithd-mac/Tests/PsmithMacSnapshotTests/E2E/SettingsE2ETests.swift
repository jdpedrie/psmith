import Testing
import AppKit
import SwiftUI
@testable import PsmithMac
import PsmithKit
import PsmithUI

/// Settings and accounts helpers. Names are specific to keep clear of
/// what the other E2E suites add to MacE2E.
extension MacE2E {
    /// The Settings window as the app builds it for a signed-in account
    /// (SettingsWindowRoot's signed-in branch), on `pane`.
    @discardableResult
    func mountSettings(_ pane: SettingsCategory = .general, size: CGSize = CGSize(width: 1052, height: 720)) async -> NSWindow {
        navigator.settingsCategory = pane
        return await mountWindow(
            SettingsView(providersModel: app.providers, profilesModel: app.profiles, mcpServersModel: app.mcpServers)
                .environment(\.fontScale, sharedAppPreferences.fontScale),
            size: size)
    }

    /// Presses a pane's tab in the Settings header. The header comes
    /// first in the tree, so the first control with the pane's name is
    /// its tab, not a same-named subtab further down.
    func settingsPane(_ pane: SettingsCategory, sourceLocation: SourceLocation = #_sourceLocation) async {
        await pressFirst(pane.label, sourceLocation: sourceLocation)
        await waitFor("the \(pane.label) pane never opened", sourceLocation: sourceLocation) { self.navigator.settingsCategory == pane }
        await spin(0.6)
    }

    /// The first control named `label`, or named "`label`, …" (a list
    /// row with its subtitle or badge read after it). Static text is
    /// skipped: the Settings header titles itself with the pane's name.
    func firstElement(_ label: String) -> NSObject? {
        elements().first {
            let n = Self.name($0)
            return (n == label || n.hasPrefix(label + ", ")) && Self.role($0) != "AXStaticText"
        }
    }

    @discardableResult
    func pressFirst(_ label: String, timeout: TimeInterval = 6, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while firstElement(label) == nil && Date() < end { await spin(0.1) }
        guard let match = firstElement(label) else {
            Issue.record("No control “\(label)”. Have: \(labels())", sourceLocation: sourceLocation)
            return false
        }
        await pressNode(match)
        return true
    }

    /// Presses the first control named `label` that comes after the
    /// element named `anchor`: the Add button on one plugin's row.
    @discardableResult
    func pressNext(_ label: String, after anchor: String, timeout: TimeInterval = 6, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        func find() -> NSObject? {
            let all = elements()
            guard let i = all.firstIndex(where: { Self.name($0) == anchor || Self.name($0).hasPrefix(anchor + ",") }) else { return nil }
            return all[(i + 1)...].first { Self.name($0) == label && Self.role($0) != "AXStaticText" }
        }
        let end = Date().addingTimeInterval(timeout)
        while find() == nil && Date() < end { await spin(0.1) }
        guard let match = find() else {
            Issue.record("No “\(label)” after “\(anchor)”. Have: \(labels())", sourceLocation: sourceLocation)
            return false
        }
        await pressNode(match)
        return true
    }

    func pressNode(_ element: NSObject) async {
        _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
        await spin(0.35)
    }

    func hasLabel(_ label: String) -> Bool { element(label) != nil }
    func hasLabel(containing text: String) -> Bool { element(containing: text) != nil }

    @discardableResult
    func waitForLabel(_ label: String, timeout: TimeInterval = 8, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await waitFor("“\(label)” never showed. Have: \(labels())", timeout: timeout, sourceLocation: sourceLocation) { self.hasLabel(label) }
    }

    @discardableResult
    func waitForLabel(containing text: String, timeout: TimeInterval = 8, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await waitFor("nothing containing “\(text)” showed. Have: \(labels())", timeout: timeout, sourceLocation: sourceLocation) { self.hasLabel(containing: text) }
    }

    @discardableResult
    func waitForNoLabel(_ label: String, timeout: TimeInterval = 8, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await waitFor("“\(label)” never went away. Have: \(labels())", timeout: timeout, sourceLocation: sourceLocation) { !self.hasLabel(label) }
    }

    /// Whether `element` carries the selected trait.
    static func isSelectedNode(_ element: NSObject?) -> Bool {
        guard let element, element.responds(to: NSSelectorFromString("isAccessibilitySelected")) else { return false }
        return (element.value(forKey: "accessibilitySelected") as? NSNumber)?.boolValue == true
    }

    func isSelectedNode(_ label: String) -> Bool { Self.isSelectedNode(element(label)) }

    /// Whether `element` is enabled, as VoiceOver reports it.
    static func isEnabledNode(_ element: NSObject?) -> Bool {
        guard let element, element.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return false }
        return (element.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue == true
    }

    /// Every switch (toggle) named `label`, top to bottom.
    func switches(_ label: String) -> [NSObject] {
        elements().filter { Self.name($0) == label && Self.role($0) == "AXCheckBox" }
    }

    /// A switch's state, "1" or "0".
    func switchValue(_ label: String) -> String? { switches(label).first.flatMap(Self.value) }

    /// The first switch named `label` after the element whose name starts
    /// with `anchor`: one model row's On switch, wherever the row sorts.
    func switchAfter(_ anchor: String, label: String = "On") -> NSObject? {
        let all = elements()
        guard let i = all.firstIndex(where: { Self.name($0).hasPrefix(anchor) }) else { return nil }
        return all[(i + 1)...].first { Self.name($0) == label && Self.role($0) == "AXCheckBox" }
    }

    /// Types into the field whose accessibility label is `label`, as the
    /// keyboard does, waiting for it to appear.
    func fill(_ label: String, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        // SwiftUI labels a field for accessibility only once something
        // has walked the tree; walk it before looking.
        let end = Date().addingTimeInterval(6)
        while labeledField(label) == nil && Date() < end { await spin(0.1) }
        guard let f = labeledField(label) else {
            Issue.record("no field “\(label)”. Have: \(textFields().map { $0.accessibilityLabel() ?? $0.placeholderString ?? "?" })", sourceLocation: sourceLocation)
            return
        }
        await type(text, into: f)
    }

    /// `field(_:)`, after walking the accessibility tree so SwiftUI has
    /// labeled the fields.
    func labeledField(_ label: String) -> NSTextField? {
        _ = elements()
        return field(label)
    }

    /// Presses Return in the field named `label`, as onSubmit expects.
    func submitField(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let f = labeledField(label) else {
            Issue.record("no field “\(label)” to submit", sourceLocation: sourceLocation)
            return
        }
        window?.makeFirstResponder(f)
        await spin(0.1)
        if let editor = f.currentEditor() as? NSTextView {
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        await spin(0.4)
    }

    /// Multiline editors (TextEditor) in the window, top to bottom.
    func textViews() -> [NSTextView] {
        guard let root = window?.contentView else { return [] }
        let views = LiveProbe.Rig.find(root) { v in
            guard let tv = v as? NSTextView, tv.isEditable, !tv.isHiddenOrHasHiddenAncestor else { return false }
            return !tv.isFieldEditor && !(tv is ComposerNSTextView)
        } as! [NSTextView]
        return views.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    func typeInto(_ view: NSTextView, _ text: String) async {
        view.window?.makeFirstResponder(view)
        await spin(0.1)
        view.selectAll(nil)
        view.insertText(text, replacementRange: view.selectedRange())
        await spin(0.3)
    }

    /// Runs `body`, then `cleanup` whether or not it threw.
    func withCleanup(_ cleanup: () async -> Void, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { await cleanup(); throw error }
        await cleanup()
    }
}

@Suite(.serialized, .enabled(if: MacE2E.enabled))
@MainActor
struct SettingsE2ETests {
    // MARK: Shell

    @Test func panesOpenFromTheHeader() async throws {
        try await MacE2E.run { e in
            await e.mountSettings(.general)
            await e.waitForLabel("Context warning")
            let expect: [(SettingsCategory, String)] = [
                (.appearance, "Show turn details"),
                (.accounts, "Add account…"),
                (.models, "E2E \(e.seed.tag)"),
                (.profiles, "Add profile…"),
                (.plugins, "Filter plugins"),
                (.servers, "Add server…"),
                (.usage, "By provider"),
                (.integrations, "Langfuse, Tracing and cost"),
                (.general, "Context warning"),
            ]
            for (pane, marker) in expect {
                await e.settingsPane(pane)
                await e.waitForLabel(marker)
                #expect(MacE2E.isSelectedNode(e.firstElement(pane.label)), "the \(pane.label) tab isn't marked selected")
                await e.waitFor("the window isn't titled \(pane.label)") { e.window?.title == pane.label }
            }
        }
    }

    // MARK: General

    @Test func generalShowsTheServerAndFlipsItsSwitch() async throws {
        try await MacE2E.run { e in
            let notify = sharedAppPreferences.notifyOnUnfocusedCompletion
            try await e.withCleanup({ sharedAppPreferences.notifyOnUnfocusedCompletion = notify }) {
                await e.mountSettings(.general)
                await e.waitForLabel("dev · 127.0.0.1")
                #expect(e.switchValue("Notify when a reply finishes") == (notify ? "1" : "0"))
                await e.pressNode(e.switches("Notify when a reply finishes")[0])
                await e.waitFor("the notify switch didn't flip") { sharedAppPreferences.notifyOnUnfocusedCompletion == !notify }
                #expect(e.switchValue("Notify when a reply finishes") == (notify ? "0" : "1"))
            }
        }
    }

    @Test func generalClearCacheConfirmsInPlace() async throws {
        try await MacE2E.run { e in
            try await e.app.client.cache?.set(["e2e"], kind: "e2e", id: e.seed.tag, capBytes: 50_000_000)
            await e.mountSettings(.general)
            await e.waitForLabel("Clear Cache…")
            await e.press("Clear Cache…")
            await e.waitForLabel("Clear the cache?")
            await e.press("Cancel")
            await e.waitForNoLabel("Clear the cache?")
            #expect(e.hasLabel("Clear Cache…"))
            await e.press("Clear Cache…")
            await e.press("Clear Cache")
            await e.waitForNoLabel("Clear the cache?")
            await e.spin(0.5)
            let left = await e.app.client.cache?.get([String].self, kind: "e2e", id: e.seed.tag)
            #expect(left == nil, "the cache still holds what the test put in it")
        }
    }

    // MARK: Appearance

    @Test func appearanceThemeAndTextApply() async throws {
        try await MacE2E.run { e in
            let turnDetails = sharedAppPreferences.showTurnDetails
            try await e.withCleanup({
                sharedThemeStore.current = .slate
                sharedAppPreferences.showTurnDetails = turnDetails
                sharedAppPreferences.fontScale = 1.0
            }) {
                await e.mountSettings(.appearance)
                await e.waitForLabel("Sage & Graphite")
                #expect(e.isSelectedNode("Slate Pro"))
                await e.press("Sage & Graphite")
                await e.waitFor("the theme didn't change") { sharedThemeStore.current.id == "sage" }
                await e.waitFor("the Sage tile isn't selected") { e.isSelectedNode("Sage & Graphite") && !e.isSelectedNode("Slate Pro") }

                await e.pressNode(e.switches("Show turn details")[0])
                await e.waitFor("Show turn details didn't flip") { sharedAppPreferences.showTurnDetails == !turnDetails }

                let slider = e.elements().first { MacE2E.role($0) == "AXSlider" }
                #expect(slider != nil)
                if let slider {
                    _ = slider.perform(NSSelectorFromString("accessibilityPerformIncrement"))
                    await e.waitFor("the text size didn't grow") { sharedAppPreferences.fontScale > 1.0 }
                    await e.press("Reset")
                    await e.waitFor("Reset didn't put the text size back") { sharedAppPreferences.fontScale == 1.0 }
                    await e.waitForNoLabel("Reset")
                }
            }
        }
    }

    // MARK: Models

    @Test func modelsTurnsAModelOffAndOnAndTestsTheProvider() async throws {
        try await MacE2E.run { e in
            let pid = e.seed.provider.id
            await e.mountSettings(.models)
            await e.pressFirst("E2E \(e.seed.tag)")
            await e.waitForLabel(containing: "Model Two,")
            await e.waitFor("expected a switch per model") { e.switches("On").count == 2 }

            await e.pressNode(e.switches("On")[1])
            await e.eventually("model-two is still on on the server") {
                try await e.app.client.modelProviders.get(id: pid).1.allSatisfy { $0.modelID != "model-two" }
            }
            await e.waitFor("Model Two is still listed under On") { !e.hasLabel(containing: "Model Two,") }

            // All lists what the provider offers (the fake lists two more)
            // and Model Two: it was added by hand, so turning it off kept it.
            await e.press(containing: "All ")
            await e.waitForLabel(containing: "fake-alpha,")
            await e.waitFor("Model Two isn't under All with its switch off") {
                e.switches("On").count == 4 && e.switchAfter("Model Two,").flatMap(MacE2E.value) == "0"
            }
            if let two = e.switchAfter("Model Two,") { await e.pressNode(two) }
            await e.eventually("model-two never came back on with its metadata") {
                try await e.app.client.modelProviders.get(id: pid).1.first { $0.modelID == "model-two" }?.contextWindow == 32_000
            }
            await e.waitFor("Model Two's switch didn't follow") { e.switchAfter("Model Two,").flatMap(MacE2E.value) == "1" }

            await e.waitFor("fake-alpha's switch isn't there and off") { e.switchAfter("fake-alpha,").flatMap(MacE2E.value) == "0" }
            if let alpha = e.switchAfter("fake-alpha,") { await e.pressNode(alpha) }
            await e.eventually("fake-alpha never came on on the server") {
                try await e.app.client.modelProviders.get(id: pid).1.contains { $0.modelID == "fake-alpha" }
            }
            await e.waitFor("fake-alpha's switch didn't follow") { e.switches("On").count == 4 && e.switchAfter("fake-alpha,").flatMap(MacE2E.value) == "1" }

            await e.press("Test")
            await e.waitForLabel(containing: "models ·", timeout: 15)
        }
    }

    @Test func providerConnectionRenameDiscardsAndSaves() async throws {
        try await MacE2E.run { e in
            let pid = e.seed.provider.id
            let renamed = "Renamed \(e.seed.tag)"
            await e.mountSettings(.models)
            await e.pressFirst("E2E \(e.seed.tag)")
            await e.press("Connection")
            await e.fill("Name", renamed)
            await e.waitForLabel("Name changed")
            await e.press("Discard")
            await e.waitForNoLabel("Name changed")
            #expect(e.labeledField("Name")?.stringValue == "E2E \(e.seed.tag)")

            await e.fill("Name", renamed)
            await e.press("Save")
            await e.eventually("the server never got the new name") {
                try await e.app.client.modelProviders.get(id: pid).0.label == renamed
            }
            await e.waitForNoLabel("Name changed")
            await e.waitFor("the list still shows the old name") { e.firstElement(renamed) != nil }
            #expect(e.labeledField("Name")?.stringValue == renamed)
        }
    }

    @Test func providerDefaultsSave() async throws {
        try await MacE2E.run { e in
            let pid = e.seed.provider.id
            await e.mountSettings(.models)
            await e.pressFirst("E2E \(e.seed.tag)")
            await e.press("Defaults")
            await e.waitForLabel("Long cache")
            await e.pressNode(e.switches("Long cache")[0])
            await e.waitForLabel("Long cache changed")
            await e.press("Save")
            await e.eventually("the server never got the provider default") {
                try await e.app.client.modelProviders.get(id: pid).0.defaultSettings?.explicitCache == true
            }
            await e.waitForNoLabel("Long cache changed")
        }
    }

    @Test func addProviderThenDeleteIt() async throws {
        try await MacE2E.run { e in
            let label = "Added \(e.seed.tag)"
            func added() async throws -> PsmithUserModelProvider? {
                try await e.app.client.modelProviders.listFromServer().first { $0.label == label }
            }
            try await e.withCleanup({
                if let p = try? await added() { try? await e.app.client.modelProviders.delete(id: p.id) }
            }) {
                await e.mountSettings(.models)
                await e.press("Add provider…")
                await e.waitForLabel("Add a provider")
                await e.fill("Name", label)
                await e.fill("API key", "e2e")
                await e.fill("Base URL", MacE2E.server().llm)
                await e.press("Add Provider")
                await e.eventually("the provider never reached the server") { try await added() != nil }
                await e.waitFor("the new provider isn't selected") { e.firstElement(label) != nil && e.hasLabel("Connection") }

                await e.press("Connection")
                await e.press("Delete…")
                await e.waitForLabel("Delete \(label)?")
                await e.press("Cancel")
                await e.waitForNoLabel("Delete \(label)?")
                await e.press("Delete…")
                await e.press("Delete Provider")
                await e.eventually("the provider is still on the server") { try await added() == nil }
                await e.waitFor("the list still shows the deleted provider") { e.firstElement(label) == nil }
            }
        }
    }

    @Test func addACustomModelThenEditIt() async throws {
        try await MacE2E.run { e in
            let pid = e.seed.provider.id
            await e.mountSettings(.models)
            await e.pressFirst("E2E \(e.seed.tag)")
            await e.press("Add Custom Model…")
            await e.waitForLabel("Add a model")
            await e.fill("Name", "Model Three")
            await e.fill("Model ID", "model-three")
            await e.press("Add Model")
            await e.eventually("model-three never reached the server") {
                try await e.app.client.modelProviders.get(id: pid).1.contains { $0.modelID == "model-three" }
            }
            await e.waitForLabel("model-three · on")
            await e.fill("Name", "Model Three Renamed")
            await e.waitForLabel("Name changed")
            await e.press("Save")
            await e.eventually("the rename never reached the server") {
                try await e.app.client.modelProviders.get(id: pid).1.first { $0.modelID == "model-three" }?.displayName == "Model Three Renamed"
            }
            await e.waitForNoLabel("Name changed")
        }
    }

    @Test func aModelRowOpensToTestAndEdit() async throws {
        try await MacE2E.run { e in
            await e.mountSettings(.models)
            await e.pressFirst("E2E \(e.seed.tag)")
            await e.press(containing: "Model One, model-one")
            await e.waitForLabel("Edit Model")
            await e.press("Test Model")
            await e.waitForLabel(containing: "Answered in", timeout: 20)
            await e.press("Edit Model")
            await e.waitForLabel("model-one · on")
            #expect(e.labeledField("Name")?.stringValue == "Model One")
        }
    }

    /// Board SettingsModelDetail, "Added by hand": a hand-added model's page
    /// deletes it; the switch would only turn it off.
    @Test func aHandAddedModelCanBeDeleted() async throws {
        try await MacE2E.run { e in
            let pid = e.seed.provider.id
            let added = try await e.app.client.modelProviders.addManualModel(
                providerID: pid, modelID: "hand-\(e.seed.tag)", displayName: "Hand \(e.seed.tag)", contextWindow: 8_000,
                maxOutputTokens: nil, pricing: nil, modalities: ["text"], capabilities: nil, knowledgeCutoff: nil, defaultSettings: nil)
            try await e.withCleanup({
                try? await e.app.client.modelProviders.disableModels(providerID: pid, modelIDs: [added.modelID], deleteManual: true)
            }) {
                await e.mountSettings(.models)
                await e.pressFirst("E2E \(e.seed.tag)")
                await e.press(containing: "Hand \(e.seed.tag), hand-\(e.seed.tag)")
                await e.press("Edit Model")
                await e.waitForLabel("hand-\(e.seed.tag) · on")
                await e.press("Delete…")
                await e.waitForLabel("Delete Hand \(e.seed.tag)?")
                await e.press("Delete Model")
                await e.eventually("the model is still on the server") {
                    let d = try await e.app.client.modelProviders.getDetail(id: pid)
                    return !d.enabled.contains { $0.modelID == added.modelID } && !d.disabled.contains { $0.modelID == added.modelID }
                }
            }
        }
    }

    @Test func testModelOnTheModelsOwnPageShowsTheResultThere() async throws {
        try await MacE2E.run { e in
            await e.mountSettings(.models)
            await e.pressFirst("E2E \(e.seed.tag)")
            await e.press(containing: "Model One, model-one")
            await e.press("Edit Model")
            await e.waitForLabel("model-one · on")
            #expect(!e.labels().contains { $0.contains("Answered in") }, "a result showed before any test")
            await e.press("Test Model")
            await e.waitForLabel(containing: "Answered in", timeout: 20)
        }
    }

    // MARK: Profiles

    private func profile(_ e: MacE2E, named name: String) async throws -> PsmithProfile? {
        try await e.app.client.profiles.list().first { $0.name == name }
    }

    @Test func createAProfile() async throws {
        try await MacE2E.run { e in
            let name = "Gamma \(e.seed.tag)"
            try await e.withCleanup({
                if let p = try? await profile(e, named: name) { try? await e.app.client.profiles.delete(id: p.id) }
            }) {
                await e.mountSettings(.profiles)
                await e.press("Add profile…")
                await e.waitForLabel("New profile")
                #expect(!MacE2E.isEnabledNode(e.element("Create Profile")), "Create Profile is enabled with no name")
                await e.fill("Name", name)
                await e.fill("Description", "Made by the e2e test")
                await e.press("Create Profile")
                await e.eventually("the profile never reached the server") {
                    try await profile(e, named: name)?.description == "Made by the e2e test"
                }
                await e.waitForNoLabel("New profile")
                await e.waitFor("the new profile isn't selected and shown") { e.hasLabel("Export…") && e.labeledField("Name")?.stringValue == name }
            }
        }
    }

    @Test func editAProfileDiscardsThenSavesNamePromptAndModel() async throws {
        try await MacE2E.run { e in
            let beta = e.seed.beta
            let renamed = "Beta edited \(e.seed.tag)"
            await e.mountSettings(.profiles)
            await e.pressFirst(beta.name)
            await e.waitFor("Beta isn't open") { e.labeledField("Name")?.stringValue == beta.name }

            await e.fill("Name", renamed)
            await e.waitForLabel("Name changed")
            await e.press("Discard")
            await e.waitForNoLabel("Name changed")
            #expect(e.labeledField("Name")?.stringValue == beta.name)

            await e.fill("Name", renamed)
            await e.press("Prompt")
            await e.waitFor("no system message editor") { !e.textViews().isEmpty }
            if let editor = e.textViews().first { await e.typeInto(editor, "Answer in one line.") }
            await e.fill("Greeting", "Hello from the test")
            await e.press("Model")
            await e.press("Model: Model One")
            await e.press(containing: "Model Two")
            await e.waitForLabel("Model: Model Two")
            await e.waitForLabel(containing: "Name and ")
            await e.press("Save")
            await e.eventually("the edits never reached the server") {
                let (p, _) = try await e.app.client.profiles.get(id: beta.id)
                return p.name == renamed && p.systemMessage == "Answer in one line." && p.welcomeMessage == "Hello from the test"
                    && p.defaultSettings?.defaultModelID == "model-two"
            }
            await e.waitForNoLabel("Discard")
        }
    }

    @Test func profilePluginsAttachAndRemove() async throws {
        try await MacE2E.run { e in
            let beta = e.seed.beta
            await e.mountSettings(.profiles)
            await e.pressFirst(beta.name)
            await e.press("Plugins")
            await e.waitForLabel("Add a plugin")
            await e.pressNext("Add", after: "Text Injector")
            if e.hasLabel(containing: "Saves with the profile") {
                await e.press("Plugins")
            }
            await e.waitForLabel(containing: "Plugins changed")
            await e.press("Save")
            await e.eventually("the plugin never reached the server") {
                try await e.app.client.profiles.getProfilePlugins(profileID: beta.id).contains { $0.pluginName == "text_injector" }
            }
            await e.waitForNoLabel("Discard")

            await e.pressNext("Remove", after: "Text Injector")
            await e.waitForLabel("Remove Text Injector from this profile?")
            await e.pressNext("Remove", after: "Remove Text Injector from this profile?")
            await e.waitForLabel(containing: "Plugins changed")
            await e.press("Save")
            await e.eventually("the plugin is still on the server") {
                try await e.app.client.profiles.getProfilePlugins(profileID: beta.id).isEmpty
            }
        }
    }

    /// A child that switches off its parent's plugin (a row other clients can
    /// make): the Mac doesn't list the plugin as running, and saving an
    /// unrelated plugin edit keeps the switch-off instead of turning it on.
    @Test func aSwitchedOffInheritedPluginStaysOff() async throws {
        try await MacE2E.run { e in
            let c = e.app.client.profiles
            let parent = try await c.create(PsmithProfilePatch(name: "Parent \(e.seed.tag)"))
            let child = try await c.create(PsmithProfilePatch(name: "Child \(e.seed.tag)", parentProfileID: parent.id))
            try await e.withCleanup({
                try? await c.delete(id: child.id)
                try? await c.delete(id: parent.id)
            }) {
                _ = try await c.setProfilePlugins(profileID: parent.id, plugins: [
                    PsmithProfilePlugin(pluginName: "lettered_choices", ordinal: 0, config: Data("{}".utf8)),
                ])
                _ = try await c.setProfilePlugins(profileID: child.id, plugins: [
                    PsmithProfilePlugin(pluginName: "lettered_choices", ordinal: 0, config: Data("{}".utf8), disabled: true),
                ])
                await e.app.profiles.load()
                await e.mountSettings(.profiles)
                await e.pressFirst("Child \(e.seed.tag)")
                await e.press("Plugins")
                await e.waitForLabel("Add a plugin")
                #expect(!e.hasLabel(containing: "Inherited from Parent \(e.seed.tag)"), "the child lists a plugin it switched off as running")
                await e.pressNext("Add", after: "Text Injector")
                if e.hasLabel(containing: "Saves with the profile") {
                    await e.press("Plugins")
                }
                await e.waitForLabel(containing: "Plugins changed")
                await e.press("Save")
                await e.eventually("the save never reached the server") {
                    try await c.getProfilePlugins(profileID: child.id).contains { $0.pluginName == "text_injector" }
                }
                let rows = try await c.getProfilePlugins(profileID: child.id)
                #expect(rows.contains { $0.pluginName == "lettered_choices" && $0.disabled },
                        "the save turned the parent's plugin back on: \(rows.map { "\($0.pluginName) disabled=\($0.disabled)" })")
            }
        }
    }

    @Test func profileAutomationSavesCompression() async throws {
        try await MacE2E.run { e in
            let beta = e.seed.beta
            await e.mountSettings(.profiles)
            await e.pressFirst(beta.name)
            await e.press("Automation")
            await e.waitForLabel("Replace")
            await e.press("Replace")
            await e.waitForLabel("Compression changed")
            await e.press("Save")
            await e.eventually("compression never reached the server") {
                try await e.app.client.profiles.get(id: beta.id).0.compressionMode == .replace
            }
        }
    }

    @Test func profileDefaultSwitchMovesTheDefault() async throws {
        try await MacE2E.run { e in
            let beta = e.seed.beta
            await e.mountSettings(.profiles)
            await e.pressFirst(beta.name)
            await e.waitForLabel("Default")
            #expect(e.switchValue("Default") == "0")
            await e.pressNode(e.switches("Default")[0])
            await e.eventually("Beta never became the default") {
                try await e.app.client.profiles.get(id: beta.id).0.isDefault
            }
            await e.waitFor("the switch didn't follow") { e.switchValue("Default") == "1" }
        }
    }

    @Test func profileFavoriteSaves() async throws {
        try await MacE2E.run { e in
            let beta = e.seed.beta
            await e.mountSettings(.profiles)
            await e.pressFirst(beta.name)
            await e.waitForLabel("Favorite")
            await e.pressNode(e.switches("Favorite")[0])
            await e.eventually("the favorite never reached the server") {
                try await e.app.client.profiles.get(id: beta.id).0.favorite
            }
            await e.waitFor("the switch didn't follow") { e.switchValue("Favorite") == "1" }
        }
    }

    /// The main window's profile gear lands here, on that profile.
    @Test func openProfileSettingsLandsOnTheProfile() async throws {
        try await MacE2E.run { e in
            await e.mountSettings(.general)
            await e.waitForLabel("Context warning")
            e.navigator.openProfileSettings(id: e.seed.beta.id)
            await e.waitFor("Settings didn't move to Profiles") { e.navigator.settingsCategory == .profiles }
            await e.waitFor("Beta isn't the profile on screen") { e.labeledField("Name")?.stringValue == e.seed.beta.name }
        }
    }

    @Test func profileParentThenDelete() async throws {
        try await MacE2E.run { e in
            let name = "Child \(e.seed.tag)"
            let child = try await e.app.client.profiles.create(PsmithProfilePatch(name: name))
            await e.app.profiles.load()
            try await e.withCleanup({ try? await e.app.client.profiles.delete(id: child.id) }) {
                await e.mountSettings(.profiles)
                await e.pressFirst(name)
                await e.waitFor("the child isn't open") { e.labeledField("Name")?.stringValue == name }
                await e.press(containing: "\(e.seed.alpha.name),")
                await e.waitForLabel("Parent changed")
                await e.press("Save")
                await e.eventually("the parent never reached the server") {
                    try await e.app.client.profiles.get(id: child.id).0.parentProfileID == e.seed.alpha.id
                }
                await e.waitForLabel("Inherits from \(e.seed.alpha.name)")

                // A parent with a child can't be deleted until the child goes.
                await e.pressFirst(e.seed.alpha.name + ", Default")
                await e.waitForLabel(containing: "inherits from this one")
                #expect(!MacE2E.isEnabledNode(e.element("Delete…")), "Delete is enabled on a profile with a child")

                await e.pressFirst(name)
                await e.waitFor("the child isn't open") { e.labeledField("Name")?.stringValue == name }
                await e.press("Delete…")
                await e.waitForLabel("Delete \(name)?")
                await e.press("Delete Profile")
                await e.eventually("the child is still on the server") { try await profile(e, named: name) == nil }
                await e.waitFor("the list still shows the deleted profile") { e.firstElement(name) == nil }
            }
        }
    }

    // MARK: Plugins

    @Test func pluginSharedSettingsSave() async throws {
        try await MacE2E.run { e in
            let original = try? await e.app.client.profiles.getUserPluginSettings(pluginName: "brave_search").config
            try await e.withCleanup({
                _ = try? await e.app.client.profiles.upsertUserPluginSettings(pluginName: "brave_search", config: original ?? Data("{}".utf8))
            }) {
                await e.mountSettings(.plugins)
                await e.pressFirst("Brave Search")
                await e.waitForLabel(containing: "before it works")
                await e.fill("API key", "brave-e2e-\(e.seed.tag)")
                await e.waitForLabel(containing: "API key added")
                await e.press("Discard")
                await e.waitForNoLabel("Discard")
                await e.fill("API key", "brave-e2e-\(e.seed.tag)")
                await e.press("Save")
                await e.eventually("the key never reached the server") {
                    let data = try await e.app.client.profiles.getUserPluginSettings(pluginName: "brave_search").config
                    let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    return dict?["api_key"] as? String == "brave-e2e-\(e.seed.tag)"
                }
                await e.waitFor("the setup warning stayed") { !e.hasLabel(containing: "before it works") }
            }
        }
    }

    // MARK: Servers

    @Test func addTestRenameAndDeleteAServer() async throws {
        try await MacE2E.run { e in
            let name = "MCP \(e.seed.tag)"
            let renamed = "MCP renamed \(e.seed.tag)"
            func server() async throws -> PsmithMCPServer? {
                try await e.app.client.profiles.listMCPServers().first { $0.name == name || $0.name == renamed }
            }
            try await e.withCleanup({
                if let s = try? await server() { try? await e.app.client.profiles.deleteMCPServer(id: s.id) }
            }) {
                await e.mountSettings(.servers)
                await e.press("Add server…")
                await e.waitForLabel("Add a server")
                await e.fill("Name", name)
                await e.press("In-process")
                await e.press("Add Server")
                await e.eventually("the server never reached the server") { try await server()?.transport == "inproc" }
                await e.waitForLabel("Test Connection")

                await e.press("Test Connection")
                await e.waitForLabel(containing: "Connected ·", timeout: 15)

                await e.fill("Name", renamed)
                await e.waitForLabel("Name changed")
                await e.press("Save")
                await e.eventually("the rename never reached the server") { try await server()?.name == renamed }
                await e.waitForNoLabel("Name changed")
                #expect(e.labeledField("Name")?.stringValue == renamed, "the field went back to the old name after saving")

                await e.press("Delete…")
                await e.waitForLabel("Delete \(renamed)?")
                await e.press("Delete Server")
                await e.eventually("the server is still registered") { try await server() == nil }
                await e.waitFor("the list still shows the deleted server") { e.firstElement(renamed) == nil }
            }
        }
    }

    // MARK: Usage

    @Test func usageShowsATurnsCost() async throws {
        try await MacE2E.run { e in
            let conv = try await e.makeConversation("Usage")
            try await e.seedTurn(conv, "echo ledger")
            await e.mountSettings(.usage)
            await e.waitForLabel(containing: "1 turn", timeout: 12)
            #expect(e.hasLabel(e.seed.provider.label))
            await e.press("Day")
            await e.waitForLabel("Spent in the last 24 hours")
            await e.waitForLabel(containing: "1 turn")
            await e.press("Custom")
            await e.waitFor("the custom range has no fields") { e.labeledField("From") != nil && e.labeledField("To") != nil }
        }
    }

    // MARK: Integrations

    @Test func langfuseSaveTestAndDelete() async throws {
        try await MacE2E.run { e in
            try await e.withCleanup({ try? await e.app.client.langfuse.delete() }) {
                e.navigator.settingsIntegration = .langfuse
                await e.mountSettings(.integrations)
                await e.waitFor("Langfuse never loaded") { e.labeledField("Host") != nil }
                await e.fill("Host", MacE2E.server().llm)
                await e.fill("Public key", "pk-lf-e2e")
                await e.fill("Secret", "sk-lf-e2e")
                await e.pressNode(e.switches("Send traces")[0])
                await e.waitForLabel(containing: "Host and 3 more changed")
                await e.press("Save")
                await e.eventually("Langfuse never reached the server") {
                    let c = try await e.app.client.langfuse.get()
                    return c.enabled && c.publicKey == "pk-lf-e2e" && c.secretKeySet && c.host == MacE2E.server().llm
                }
                await e.waitForLabel("Langfuse, Tracing and cost, On")

                // The server reports success once the trace is handed off,
                // whatever the host answers (docs/todo.md, Mac), so this
                // checks a result shows, not which.
                await e.press("Send Test Trace")
                await e.waitFor("no test result showed. Have: \(e.labels())", timeout: 15) {
                    e.hasLabel(containing: "Look for it in your Langfuse") || e.hasLabel(containing: "Test failed after")
                }

                await e.press("Delete…")
                await e.waitForLabel("Delete the Langfuse configuration?")
                await e.press("Delete")
                await e.eventually("Langfuse is still configured") {
                    let c = try await e.app.client.langfuse.get()
                    return !c.secretKeySet && c.publicKey.isEmpty
                }
            }
        }
    }

    @Test func embedderRejectsTheWrongSizeThenSavesTestsAndDeletes() async throws {
        try await MacE2E.run { e in
            try await e.withCleanup({ try? await e.app.client.embedder.delete() }) {
                e.navigator.settingsIntegration = .embedder
                await e.mountSettings(.integrations)
                await e.waitFor("the embedder never loaded") { e.labeledField("Base URL") != nil }
                await e.pressNode(e.switches("Use this embedder")[0])
                await e.fill("Base URL", MacE2E.server().llm)
                await e.fill("Model", "fake-embed")
                await e.fill("Dimensions", "1024")
                await e.commitEditing()
                await e.waitForLabel(containing: "more changed")
                await e.press("Save")
                await e.waitForLabel("Couldn't save")

                await e.fill("Dimensions", "768")
                await e.commitEditing()
                await e.press("Save")
                await e.eventually("the embedder never reached the server") {
                    let c = try await e.app.client.embedder.get()
                    return c.enabled && c.model == "fake-embed" && c.dimensions == 768 && c.baseURL == MacE2E.server().llm
                }
                await e.waitForNoLabel("Couldn't save")

                await e.press("Test Connection")
                await e.waitForLabel(containing: "Test failed after", timeout: 15)

                await e.press("Delete…")
                await e.waitForLabel("Delete the embedder configuration?")
                await e.press("Delete")
                await e.eventually("the embedder is still configured") {
                    guard let c = try? await e.app.client.embedder.get() else { return true }
                    return !c.enabled && c.model != "fake-embed"
                }
            }
        }
    }

    @Test func speechSavesACloudEngineThenResets() async throws {
        try await MacE2E.run { e in
            try await e.withCleanup({ try? await e.app.client.speech.delete() }) {
                e.navigator.settingsIntegration = .speech
                await e.mountSettings(.integrations)
                await e.waitForLabel("OpenAI-compatible")
                await e.press("OpenAI-compatible")
                await e.fill("Voice", "alloy")
                await e.fill("Base URL", MacE2E.server().llm)
                await e.fill("Secret", "sk-speech-e2e")
                await e.press("Save")
                await e.eventually("speech never reached the server") {
                    let c = try await e.app.client.speech.get()
                    return c.kind == "openai-compatible" && c.voice == "alloy" && c.baseURL == MacE2E.server().llm && c.apiKeySet
                }
                await e.waitForLabel("Speech, Read replies aloud, Cloud")

                await e.press("Test Synthesis")
                await e.waitForLabel(containing: "Test failed after", timeout: 15)

                await e.press("Reset…")
                await e.waitForLabel("Reset speech to the on-device voice?")
                await e.press("Reset")
                await e.eventually("speech is still on the cloud engine") {
                    try await e.app.client.speech.get().kind == PsmithSpeechConfig.kindAppleLocal
                }
            }
        }
    }

    @Test func deviceToolsForgetsTheFolder() async throws {
        try await MacE2E.run { e in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("psmith-e2e-notes-\(e.seed.tag)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FilesFolderBookmark.save(folderURL: folder)
            try await e.withCleanup({
                FilesFolderBookmark.clear()
                try? FileManager.default.removeItem(at: folder)
            }) {
                e.navigator.settingsIntegration = .deviceTools
                await e.mountSettings(.integrations)
                await e.waitForLabel(folder.lastPathComponent)
                #expect(e.hasLabel("Device tools, Calendar, reminders, notes, Folder set"))
                await e.waitForLabel(containing: "No calls yet")
                await e.press("Refresh")
                await e.waitForLabel(containing: "No calls yet")

                await e.press("Forget Folder")
                await e.waitForLabel("Forget the notes folder?")
                await e.press("Cancel")
                await e.waitForNoLabel("Forget the notes folder?")
                #expect(FilesFolderBookmark.isSet)
                await e.press("Forget Folder")
                await e.pressNext("Forget Folder", after: "Forget the notes folder?")
                await e.waitFor("the bookmark is still saved") { !FilesFolderBookmark.isSet }
                await e.waitForLabel("Choose Folder…")
                await e.waitForLabel("Device tools, Calendar, reminders, notes")
            }
        }
    }
}
