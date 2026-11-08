import SwiftUI
import PsmithKit
import PsmithUI
import AppKit
import UniformTypeIdentifiers

/// The Profiles pane (boards "Profiles · …"): profiles on the left; one
/// profile's five tabs on the right, edited in place under one save bar;
/// a plugin's per-profile settings drilled into; new profiles, import and
/// export inline.
struct ProfilesPane: View {
    @Bindable var model: ProfilesViewModel
    @Environment(Navigator.self) private var navigator
    @State private var filter = ""

    var body: some View {
        SKSplit(scrollsDetail: false) {
            SKSearchField(placeholder: "Filter profiles", text: $filter).padding(.top, 8).padding(.bottom, 2)
            SKListHeader(text: "Profiles")
            ForEach(shown) { p in
                SKListItem(
                    title: p.name,
                    subtitle: subtitle(p),
                    selected: model.detailMode != .adding && model.detailMode != .importing && model.selectedID == p.id,
                    action: { model.detailMode = .viewing; model.select(p.id) },
                    lead: { EmptyView() },
                    trail: {
                        if p.isDefault {
                            SKChip(text: "Default", color: model.selectedID == p.id ? .white : SK.secondary)
                        } else if p.favorite {
                            Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color(hex: 0xF5C451))
                        }
                    }
                )
            }
            if model.isLoading, model.profiles.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            SKAddItem(title: "Add profile…", selected: model.detailMode == .adding) {
                navigator.settingsProfileTab = .general
                model.detailMode = .adding
            }
            SKAddItem(title: "Import from a file…", selected: model.detailMode == .importing) { chooseImport(model) }
        } detail: {
            switch model.detailMode {
            case .adding:
                ProfileEditor(model: model, profile: nil)
            case .importing:
                ImportPage(model: model)
            default:
                if let p = model.selected() {
                    ProfileEditor(model: model, profile: p).id(p.id)
                } else if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SKDetailPage { SKPageHead("No profiles yet", subtitle: "Add one from the list.") }
                }
            }
        }
        .task {
            if model.profiles.isEmpty { await model.load() }
            if model.selectedID == nil { model.selectedID = model.profiles.first?.id }
            await model.loadAvailableModels()
            if model.pluginTypes.isEmpty { await model.loadPluginTypes() }
        }
    }

    private var shown: [PsmithProfile] {
        let q = filter.lowercased()
        return model.profiles.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    /// "Coding ‹ Shared Defaults", nearest parent first; "Parent only" for a
    /// template with no parent of its own.
    private func subtitle(_ p: PsmithProfile) -> String? {
        let chain = model.parentChainName(for: p)
        if chain.isEmpty { return p.parentOnly ? "Parent only" : nil }
        return chain.replacingOccurrences(of: " / ", with: " ‹ ")
    }
}

/// Opens a .psmithprofile and previews it. A drop on the import page does
/// the same without the panel.
@MainActor
func chooseImport(_ model: ProfilesViewModel) {
    let panel = NSOpenPanel()
    panel.message = "Choose a .psmithprofile file"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    previewImport(url, into: model)
}

@MainActor
func previewImport(_ url: URL, into model: ProfilesViewModel) {
    do {
        let data = try Data(contentsOf: url)
        importedFileName = url.lastPathComponent
        Task { await model.previewImport(payload: data) }
    } catch {
        model.error = "Couldn't read that file: \(error.localizedDescription)"
    }
}

/// The file the import page is showing, for its drop zone's title.
@MainActor var importedFileName = ""

// MARK: - Editor

private struct PluginDraft: Identifiable {
    let id = UUID()
    var name: String
    var config: [String: Any]
}

private struct ProfileEditor: View {
    @Bindable var model: ProfilesViewModel
    let profile: PsmithProfile?
    @Environment(Navigator.self) private var navigator
    @Environment(AppModel.self) private var app

    @State private var name = ""
    @State private var desc = ""
    @State private var parentID: String?
    @State private var parentOnly = false
    @State private var system = ""
    @State private var prefill = ""
    @State private var greeting = ""
    @State private var defaultProviderID: String?
    @State private var defaultModelID: String?
    @State private var callSettings = PsmithCallSettings()
    @State private var compressionMode: PsmithCompressionMode?
    @State private var compressionProviderID: String?
    @State private var compressionModelID: String?
    @State private var compressionGuide = ""
    @State private var titleKind: String?
    @State private var titleProviderID: String?
    @State private var titleModelID: String?
    @State private var titleGuide = ""
    @State private var plugins: [PluginDraft] = []
    @State private var pluginsBaseline = ""
    @State private var pluginsLoaded = false

    @State private var seededKey = ""
    @State private var saving = false
    @State private var error: String?
    @State private var exported: (file: String, url: URL, notices: [String])?
    @State private var confirmingDelete = false
    @State private var confirmingRemove: UUID?
    @State private var drilled: UUID?
    @State private var openRow: String?
    @State private var addFilter = ""

    private var adding: Bool { profile == nil }
    private var parent: PsmithProfile? { model.profiles.first { $0.id == parentID } }
    private var tab: Binding<SettingsProfileTab> {
        Binding(get: { navigator.settingsProfileTab }, set: { navigator.settingsProfileTab = $0 })
    }

    var body: some View {
        SKDetailPage {
            if let d = drilled, let i = plugins.firstIndex(where: { $0.id == d }) {
                pluginPage(i)
            } else {
                if let exported {
                    SKBanner(kind: .ok, title: "Exported to Downloads as \(exported.file)",
                             message: exported.notices.isEmpty ? nil : "Not included: \(exported.notices.joined(separator: " "))") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported.url]) }.skButton(small: true)
                    }
                }
                if let error { SKBanner(.error, adding ? "Couldn't create the profile" : "Couldn't save", message: error) }
                if adding {
                    SKPageHead("New profile", subtitle: "Fill in what's different from its parent. Everything else inherits.")
                } else {
                    SKPageHead(title: profile!.name, subtitle: parent.map { "Inherits from \($0.name)" } ?? "Standalone profile") {
                        Button(model.isSharing ? "Exporting…" : "Export…") { Task { await export() } }.skButton().disabled(model.isSharing)
                    }
                }
                SKSubtabs(options: [(.general, "General"), (.prompt, "Prompt"), (.model, "Model"), (.plugins, "Plugins"), (.automation, "Automation")], selection: tab)
                switch tab.wrappedValue {
                case .general: general
                case .prompt: prompt
                case .model: modelTab
                case .plugins: pluginsTab
                case .automation: automation
                }
                if adding {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Cancel") { model.detailMode = .viewing }.skButton().keyboardShortcut(.cancelAction)
                        Button(saving ? "Creating…" : "Create Profile") { Task { await save() } }
                            .skButton(.primary)
                            .keyboardShortcut(.defaultAction)
                            .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        } bottom: {
            if !adding, !changes.isEmpty {
                SKSaveBar(summary: IntegrationsPane.summary(changes), note: drilled == nil ? nil : "Saves with the profile",
                          saving: saving, onDiscard: { seed(force: true) }, onSave: { Task { await save() } })
            }
        }
        .task(id: profile?.id ?? "new") {
            seed(force: false)
            await loadPlugins()
        }
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKGroup("Profile") {
                SKRow("Name") { SKTextField(label: "Name", text: $name, placeholder: adding ? "Research" : "", width: 300) }
                SKRow("Description") { SKTextField(label: "Description", text: $desc, placeholder: "A sentence on when to use it", width: 300) }
                SKRawRow(vertical: 10) {
                    VStack(alignment: .leading, spacing: 9) {
                        SKLabel(title: "Inherits from", detail: "Anything left blank here comes from this profile.")
                        SKParentCards(profiles: model.sortedForPicker, excluding: profile?.id, parentID: $parentID)
                    }
                }
            } trailing: {
                SKChip.synced
            }
            SKGroup("Where it shows") {
                SKRow("Favorite", detail: "Favorites come first in the new-conversation picker.") {
                    Toggle("Favorite", isOn: Binding(get: { profile?.favorite ?? false }, set: { _ in
                        if let id = profile?.id { Task { await model.toggleFavorite(id) } }
                    })).skSwitch().disabled(adding)
                }
                SKRow("Default for new conversations", detail: defaultDetail) {
                    Toggle("Default", isOn: Binding(get: { profile?.isDefault ?? false }, set: { on in
                        Task { await model.setDefault(on ? profile?.id : nil) }
                    })).skSwitch().disabled(adding)
                }
                SKRow("Parent only", detail: "Hidden from the new-conversation picker. Other profiles can still inherit from it.") {
                    Toggle("Parent only", isOn: $parentOnly).skSwitch()
                }
            }
            if !adding, let profile { deleteGroup(profile) }
        }
    }

    private var defaultDetail: String {
        if profile?.isDefault == true { return "New conversations start with this profile." }
        if let d = model.defaultProfile { return "\(d.name) is the default now." }
        return "New conversations ask which profile to use."
    }

    @ViewBuilder
    private func deleteGroup(_ profile: PsmithProfile) -> some View {
        let children = model.profiles.filter { $0.parentProfileID == profile.id }
        SKGroup {
            if confirmingDelete {
                SKRawRow(vertical: 8, horizontal: 8) {
                    SKConfirmStrip(question: "Delete \(profile.name)?",
                                   detail: "Conversations using it keep working but lose what they inherit from it.",
                                   confirmLabel: "Delete Profile",
                                   onCancel: { confirmingDelete = false },
                                   onConfirm: { confirmingDelete = false; Task { await model.deleteSelected() } })
                }
            } else {
                SKRow("Delete profile", detail: children.isEmpty ? "Conversations using it keep working."
                      : "\(children.map(\.name).joined(separator: ", ")) inherit\(children.count == 1 ? "s" : "") from this one. Change or delete \(children.count == 1 ? "it" : "them") first.") {
                    Button(model.isDeleting ? "Deleting…" : "Delete…") { confirmingDelete = true }
                        .skButton(.destructive)
                        .disabled(!children.isEmpty || model.isDeleting)
                }
            }
        }
    }

    // MARK: Prompt

    private var inheritsName: String { parent?.name ?? "the parent" }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKGroup("System message") {
                SKRawRow(vertical: 10, horizontal: 10) { SKTextArea(text: $system, lines: 6) }
            } trailing: {
                SKChip.synced
            } footer: {
                Text(parent == nil ? "Sent at the top of every request." : "Sent at the top of every request. Blank inherits \(inheritsName)'s.")
            }
            SKGroup("New conversations start with") {
                SKRow("Prefilled message", detail: "Put in the composer, not sent until you send it.") {
                    SKTextField(label: "Prefilled message", text: $prefill, placeholder: parent.map { "Inherits \($0.name)'s" } ?? "None", width: nil)
                }
                SKRow("Greeting", detail: "Shown as the assistant's first message. Not sent to the model.") {
                    SKTextField(label: "Greeting", text: $greeting, placeholder: parent.map { "Inherits \($0.name)'s" } ?? "None", width: nil)
                }
            }
        }
    }

    // MARK: Model

    private var providerLogos: [String: String] {
        var out: [String: String] = [:]
        for (id, type) in model.providerTypes {
            switch type {
            case "anthropic": out[id] = "anthropic"
            case "google": out[id] = "google"
            default: if let p = model.providerPresetIDs[id] { out[id] = p }
            }
        }
        return out
    }

    private var chosenModel: PsmithUserModel? {
        model.availableModels.first { $0.modelID == defaultModelID && $0.providerID == defaultProviderID }
    }

    /// The parent's resolved default model, for the Inherit row.
    private var inheritedModel: (provider: String, model: String, from: String)? {
        var p = parent
        var seen: Set<String> = []
        while let cur = p, !seen.contains(cur.id) {
            seen.insert(cur.id)
            if let d = cur.defaultSettings, let pid = d.defaultProviderID, let mid = d.defaultModelID { return (pid, mid, cur.name) }
            p = model.profiles.first { $0.id == cur.parentProfileID }
        }
        return nil
    }

    private var modelTab: some View {
        let effective = chosenModel ?? inheritedModel.flatMap { i in model.availableModels.first { $0.modelID == i.model && $0.providerID == i.provider } }
        let providerID = effective?.providerID
        var inherited = providerID.flatMap { model.providerDefaultSettings[$0] } ?? PsmithCallSettings()
        if let m = effective?.defaultSettings { inherited = Self.merge(inherited, over: m) }
        let source = [effective?.displayName, providerID.flatMap { model.providerLabels[$0] }].compactMap { $0 }.joined(separator: " and ")
        return VStack(alignment: .leading, spacing: 0) {
            SKGroup("Default model") {
                SKModelRow(title: "Model", detail: "Used for normal turns unless a conversation picks another.",
                           models: model.availableModels, providerLabels: model.providerLabels, providerLogos: providerLogos,
                           providerID: defaultProviderID, modelID: defaultModelID,
                           inheritLabel: inheritedModel.map { i in "Inherit: \(model.availableModels.first { $0.modelID == i.model }?.displayName ?? i.model) from \(i.from)" } ?? "Inherit: none",
                           openRow: $openRow) { p, m in defaultProviderID = p; defaultModelID = m }
            } trailing: {
                SKChip.synced
            }
            Text("Default settings").sk(12, SK.secondary, weight: .semibold).padding(.horizontal, 2).padding(.top, 4).padding(.bottom, 7)
            Text(source.isEmpty ? "Above the model's and provider's, below a conversation's." : "Above the model's and provider's, below a conversation's. Blue text is inherited from \(source).")
                .sk(11.5, SK.tertiary).padding(.horizontal, 2).padding(.bottom, 10)
            SKCallSettings(settings: $callSettings, inherited: inherited, inheritedFrom: source.isEmpty ? nil : source,
                           driver: providerID.flatMap { model.providerTypes[$0] } ?? "anthropic", driverTabs: true,
                           constraints: effective?.constraints)
        }
    }

    /// `top` over `base`, field by field.
    static func merge(_ base: PsmithCallSettings, over top: PsmithCallSettings) -> PsmithCallSettings {
        var out = base
        if let v = top.temperature { out.temperature = v }
        if let v = top.topP { out.topP = v }
        if let v = top.maxOutputTokens { out.maxOutputTokens = v }
        if let v = top.topK { out.topK = v }
        if !top.stopSequences.isEmpty { out.stopSequences = top.stopSequences }
        if let v = top.thinking { out.thinking = v }
        if let v = top.explicitCache { out.explicitCache = v }
        if let v = top.anthropic { out.anthropic = v }
        if let v = top.openai { out.openai = v }
        if let v = top.google { out.google = v }
        return out
    }

    // MARK: Plugins

    private func type(_ name: String) -> PsmithPluginType? { model.pluginTypes.first { $0.name == name } }

    private var ancestors: [PsmithProfile] {
        var out: [PsmithProfile] = []
        var p = parent
        var seen: Set<String> = []
        while let cur = p, !seen.contains(cur.id) {
            seen.insert(cur.id)
            out.insert(cur, at: 0)
            p = model.profiles.first { $0.id == cur.parentProfileID }
        }
        return out
    }

    private var pluginsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKGroup("Attached, in the order they run") {
                ForEach(ancestors) { a in
                    ForEach(model.profilePlugins[a.id] ?? [], id: \.id) { pp in
                        pluginRow(name: pp.pluginName, inheritedFrom: a.name, draft: nil)
                    }
                }
                ForEach(plugins) { p in
                    if confirmingRemove == p.id {
                        SKRawRow(vertical: 8, horizontal: 8) {
                            SKConfirmStrip(question: "Remove \(type(p.name)?.displayName ?? p.name) from this profile?",
                                           detail: "Its settings on this profile go with it.", confirmLabel: "Remove",
                                           onCancel: { confirmingRemove = nil },
                                           onConfirm: { plugins.removeAll { $0.id == p.id }; confirmingRemove = nil })
                        }
                    } else {
                        pluginRow(name: p.name, inheritedFrom: nil, draft: p)
                            .draggable(p.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let s = items.first, let from = plugins.firstIndex(where: { $0.id.uuidString == s }),
                                      let to = plugins.firstIndex(where: { $0.id == p.id }) else { return false }
                                withAnimation { plugins.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
                                return true
                            }
                    }
                }
                if plugins.isEmpty, ancestors.allSatisfy({ (model.profilePlugins[$0.id] ?? []).isEmpty }) {
                    SKRawRow { Text("No plugins yet. Add one below.").sk(13, SK.secondary) }
                }
            } trailing: {
                SKChip.synced
            } footer: {
                Text(ancestors.isEmpty ? "Drag to reorder." : "Drag to reorder. Plugins inherited from \(ancestors.last!.name) run first and change in \(ancestors.last!.name).")
            }
            let attached = Set(plugins.map(\.name))
            let addable = model.pluginTypes.filter { !attached.contains($0.name) }
                .filter { addFilter.isEmpty || $0.displayName.lowercased().contains(addFilter.lowercased()) }
            SKGroup("Add a plugin") {
                SKRawRow(vertical: 10, horizontal: 12) { SKSearchField(placeholder: "Filter plugins", text: $addFilter) }
                ForEach(addable) { t in
                    HStack(spacing: 12) {
                        SKLabel(title: t.displayName, detail: t.description.isEmpty ? nil : t.description, detailLines: 1).help(t.description)
                        Button { add(t) } label: {
                            HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)); Text("Add") }
                        }
                        .skButton(small: true)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 14)
                }
            }
        }
    }

    private func pluginRow(name: String, inheritedFrom: String?, draft: PluginDraft?) -> some View {
        let t = type(name)
        let scoped = t?.profileScopedConfigFields ?? []
        let globalsMissing = (t?.globalConfigFields ?? []).first { f in
            f.required && f.isUnsatisfied(by: Self.dict(model.globalSettings(for: name).config)[f.name])
        }
        let scopedMissing = draft.map { d in scoped.filter { $0.required && $0.isUnsatisfied(by: d.config[$0.name]) } } ?? []
        return SKRawRow {
            HStack(spacing: 10) {
                Image(systemName: "circle.grid.2x3.fill").font(.system(size: 8)).foregroundStyle(inheritedFrom == nil ? SK.tertiary : .clear)
                    .frame(width: 14)
                    .accessibilityLabel("Drag to reorder")
                SKLabel(title: t?.displayName ?? name, detail: t?.description, detailLines: 1)
                    .help(t?.description ?? "")
                HStack(spacing: 10) {
                    if let inheritedFrom {
                        SKChip(text: "Inherited from \(inheritedFrom)")
                    } else {
                        if let g = globalsMissing {
                            SKChip(text: "Needs \(g.display.isEmpty ? g.name : g.display.lowercased())", color: SK.orange, fill: SK.orange.opacity(0.14))
                        } else if !scopedMissing.isEmpty {
                            SKChip(text: "\(scopedMissing.count) required", color: SK.orange, fill: SK.orange.opacity(0.14))
                        } else if !scoped.isEmpty {
                            SKChip(text: "\(scoped.count) setting\(scoped.count == 1 ? "" : "s")")
                        }
                        Button("Remove") { confirmingRemove = draft?.id }.skButton(.plainQuiet)
                        if !scoped.isEmpty {
                            Button { drilled = draft?.id } label: {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(SK.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Settings")
                        }
                    }
                }
            }
        }
    }

    private func add(_ t: PsmithPluginType) {
        var config: [String: Any] = [:]
        for f in t.profileScopedConfigFields {
            if let d = f.defaultJSON.data(using: .utf8), !f.defaultJSON.isEmpty,
               let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) { config[f.name] = v }
        }
        let draft = PluginDraft(name: t.name, config: config)
        plugins.append(draft)
        if !t.profileScopedConfigFields.isEmpty { drilled = draft.id }
    }

    @ViewBuilder
    private func pluginPage(_ i: Int) -> some View {
        let t = type(plugins[i].name)
        SKBreadcrumb(parts: [(name.isEmpty ? "New profile" : name, { drilled = nil; navigator.settingsProfileTab = .general }),
                             ("Plugins", { drilled = nil; navigator.settingsProfileTab = .plugins })],
                     current: t?.displayName ?? plugins[i].name)
        SKPageHead(title: t?.displayName ?? plugins[i].name, subtitle: "Settings on \(name.isEmpty ? "this profile" : name). Shared settings live in the Plugins pane.") {
            Button {
                model.selectedPluginID = plugins[i].name
                navigator.settingsCategory = .plugins
            } label: {
                HStack(spacing: 4) { Text("Open in Plugins"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
            }
            .skButton()
        }
        SKPluginFields(fields: t?.profileScopedConfigFields ?? [],
                       values: Binding(get: { plugins.indices.contains(i) ? plugins[i].config : [:] },
                                       set: { if plugins.indices.contains(i) { plugins[i].config = $0 } }),
                       models: model.availableModels, providerLabels: model.providerLabels, providerLogos: providerLogos,
                       profiles: model.profiles, mainTitle: "Settings")
    }

    static func dict(_ data: Data) -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Automation

    private var automation: some View {
        VStack(alignment: .leading, spacing: 0) {
            SKGroup("Compression") {
                SKRow("Mode", detail: "Replace swaps the context for a summary. Append keeps both.") {
                    SKSegmented(options: [(PsmithCompressionMode?.none, "Inherit"), (.replace, "Replace"), (.append, "Append")], selection: $compressionMode)
                }
                SKModelRow(title: "Summary model", models: model.availableModels, providerLabels: model.providerLabels, providerLogos: providerLogos,
                           providerID: compressionProviderID, modelID: compressionModelID,
                           inheritLabel: "Inherit: \(parent.map { "\($0.name)'s" } ?? "none, so no compression")", openRow: $openRow) { p, m in
                    compressionProviderID = p; compressionModelID = m
                }
                SKRawRow {
                    VStack(alignment: .leading, spacing: 7) {
                        SKLabel(title: "Guide", detail: "An extra instruction for the summarizer.")
                        SKTextArea(text: $compressionGuide, lines: 2)
                    }
                }
            } trailing: {
                SKChip.synced
            }
            SKGroup("Titles") {
                SKRawRow(vertical: 12) {
                    HStack(spacing: 8) {
                        genCard("On this Mac", AppleFoundation.isAvailable ? "Apple's on-device model. Free and private." : "Not available on this Mac.",
                                "apple.logo", selected: titleKind == PsmithTitleProviderKind.appleFoundation, badge: "macOS 26") {
                            titleKind = PsmithTitleProviderKind.appleFoundation
                        }
                        .disabled(!AppleFoundation.isAvailable)
                        genCard("A cloud model", titleModelID.flatMap { id in model.availableModels.first { $0.modelID == id }?.displayName } ?? "Pick one below.",
                                "cloud", selected: titleKind == nil && titleModelID != nil, badge: nil) {
                            titleKind = nil
                            if titleModelID == nil { openRow = "Title model" }
                        }
                        genCard("Inherit", parent.map { "\($0.name)'s titler." } ?? "No titles.", "arrow.uturn.backward",
                                selected: titleKind == nil && titleModelID == nil && openRow != "Title model", badge: nil) {
                            titleKind = nil; titleProviderID = nil; titleModelID = nil
                        }
                    }
                }
                if titleKind == nil, titleModelID != nil || openRow == "Title model" {
                    SKModelRow(title: "Title model", detail: "Used for every title in this profile's conversations.",
                               models: model.availableModels, providerLabels: model.providerLabels, providerLogos: providerLogos,
                               providerID: titleProviderID, modelID: titleModelID, inheritLabel: nil, unsetName: "Choose", openRow: $openRow) { p, m in
                        titleProviderID = p; titleModelID = m
                    }
                }
                SKRawRow {
                    VStack(alignment: .leading, spacing: 7) {
                        SKLabel(title: "Guide", detail: "An extra instruction for the titler.")
                        SKTextArea(text: $titleGuide, lines: 2)
                    }
                }
            }
        }
    }

    private func genCard(_ title: String, _ sub: String, _ symbol: String, selected: Bool, badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 12)).frame(width: 15)
                    Text(title).sk(12.5, weight: .semibold)
                    if let badge { SKChip(text: badge) }
                }
                Text(sub).sk(11.5, SK.secondary).lineLimit(2)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? SK.accent.opacity(0.12) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? SK.accent : SK.line, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: State

    private func seed(force: Bool) {
        let key = profile.map { "\($0.id)-\($0.updatedAt?.timeIntervalSince1970 ?? 0)" } ?? "new"
        guard force || key != seededKey else { return }
        seededKey = key
        guard let p = profile else {
            name = ""; desc = ""; parentID = nil; parentOnly = false
            return
        }
        name = p.name
        desc = p.description
        parentID = p.parentProfileID
        parentOnly = p.parentOnly
        system = p.systemMessage ?? ""
        prefill = p.defaultUserMessage ?? ""
        greeting = p.welcomeMessage ?? ""
        defaultProviderID = p.defaultSettings?.defaultProviderID
        defaultModelID = p.defaultSettings?.defaultModelID
        callSettings = p.defaultSettings?.callSettings ?? PsmithCallSettings()
        compressionMode = p.compressionMode
        compressionProviderID = p.compressionProviderID
        compressionModelID = p.compressionModelID
        compressionGuide = p.compressionGuide ?? ""
        titleKind = p.titleProviderKind
        titleProviderID = p.titleProviderID
        titleModelID = p.titleModelID
        titleGuide = p.titleGuide ?? ""
        if force { resetPlugins() }
    }

    private func loadPlugins() async {
        for a in ancestors where model.profilePlugins[a.id] == nil { await model.loadPlugins(forProfileID: a.id) }
        if model.pluginTypes.isEmpty { await model.loadPluginTypes() }
        await model.loadUserPluginSettings()
        guard let id = profile?.id else { pluginsLoaded = true; return }
        await model.loadPlugins(forProfileID: id)
        resetPlugins()
        pluginsLoaded = true
    }

    private func resetPlugins() {
        guard let id = profile?.id else { plugins = []; pluginsBaseline = Self.key([]); return }
        plugins = (model.profilePlugins[id] ?? []).sorted { $0.ordinal < $1.ordinal }.map { PluginDraft(name: $0.pluginName, config: Self.dict($0.config)) }
        pluginsBaseline = Self.key(plugins)
    }

    private static func key(_ plugins: [PluginDraft]) -> String {
        plugins.map { p in
            let data = (try? JSONSerialization.data(withJSONObject: p.config, options: [.sortedKeys])) ?? Data()
            return p.name + ":" + (String(data: data, encoding: .utf8) ?? "")
        }.joined(separator: "|")
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var changes: [String] {
        guard let p = profile else { return [] }
        var out: [String] = []
        if name.trimmingCharacters(in: .whitespaces) != p.name { out.append("Name") }
        if desc.trimmingCharacters(in: .whitespaces) != p.description { out.append("Description") }
        if parentID != p.parentProfileID { out.append("Parent") }
        if parentOnly != p.parentOnly { out.append("Parent only") }
        if Self.trimmed(system) != p.systemMessage { out.append("System message") }
        if Self.trimmed(prefill) != p.defaultUserMessage { out.append("Prefilled message") }
        if Self.trimmed(greeting) != p.welcomeMessage { out.append("Greeting") }
        if defaultModelID != p.defaultSettings?.defaultModelID || defaultProviderID != p.defaultSettings?.defaultProviderID { out.append("Default model") }
        out += CallSettingsDiff.changed(from: p.defaultSettings?.callSettings ?? PsmithCallSettings(), to: callSettings)
        if compressionMode != p.compressionMode || compressionModelID != p.compressionModelID || Self.trimmed(compressionGuide) != p.compressionGuide { out.append("Compression") }
        if titleKind != p.titleProviderKind || titleModelID != p.titleModelID || Self.trimmed(titleGuide) != p.titleGuide { out.append("Titles") }
        if pluginsLoaded, Self.key(plugins) != pluginsBaseline {
            out.append(Set(plugins.map(\.name)) == Set(pluginsBaseline.split(separator: "|").map { String($0.split(separator: ":").first ?? "") }) ? "Plugin order" : "Plugins")
        }
        return out
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var patch = PsmithProfilePatch()
        patch.name = name.trimmingCharacters(in: .whitespaces)
        patch.description = desc.trimmingCharacters(in: .whitespaces)
        patch.parentOnly = parentOnly
        patch.parentProfileID = parentID
        patch.systemMessage = Self.trimmed(system)
        patch.defaultUserMessage = Self.trimmed(prefill)
        patch.welcomeMessage = Self.trimmed(greeting)
        // The server replaces the whole defaults blob, and this page doesn't
        // edit include-thinking: carry it through or a save here erases it.
        let includeThinking = profile?.defaultSettings?.includeThinkingInHistory
        if defaultProviderID != nil || defaultModelID != nil || !callSettings.isEmpty || includeThinking != nil {
            patch.defaultSettings = PsmithProfileDefaults(defaultProviderID: defaultProviderID, defaultModelID: defaultModelID,
                                                          includeThinkingInHistory: includeThinking,
                                                          callSettings: callSettings.isEmpty ? nil : callSettings)
        }
        patch.compressionMode = compressionMode
        patch.compressionProviderID = compressionProviderID
        patch.compressionModelID = compressionModelID
        patch.compressionGuide = Self.trimmed(compressionGuide)
        // The on-device titler and a cloud model are exclusive on the server.
        if titleKind == PsmithTitleProviderKind.appleFoundation {
            patch.titleProviderKind = PsmithTitleProviderKind.appleFoundation
        } else {
            patch.titleProviderID = titleProviderID
            patch.titleModelID = titleModelID
        }
        patch.titleGuide = Self.trimmed(titleGuide)

        var clear: [String] = []
        if profile != nil {
            // Blank means inherit: say so, or the server keeps the old value.
            if patch.systemMessage == nil { clear.append("system_message") }
            if patch.defaultUserMessage == nil { clear.append("default_user_message") }
            if patch.welcomeMessage == nil { clear.append("welcome_message") }
            if patch.defaultSettings == nil { clear.append("default_settings") }
            if patch.parentProfileID == nil { clear.append("parent_profile_id") }
            if patch.compressionMode == nil { clear.append("compression_mode") }
            if patch.compressionProviderID == nil { clear.append("compression_provider_id") }
            if patch.compressionModelID == nil { clear.append("compression_model_id") }
            if patch.compressionGuide == nil { clear.append("compression_guide") }
            if patch.titleProviderID == nil { clear.append("title_provider_id") }
            if patch.titleModelID == nil { clear.append("title_model_id") }
            if patch.titleGuide == nil { clear.append("title_guide") }
            if patch.titleProviderKind == nil { clear.append("title_provider_kind") }
        }
        do {
            let id: String
            if let profile {
                _ = try await model.update(id: profile.id, patch: patch, clearFields: clear)
                id = profile.id
            } else {
                id = try await model.create(patch).id
                model.selectedID = id
            }
            if pluginsLoaded, Self.key(plugins) != pluginsBaseline {
                let list = try plugins.enumerated().map { i, p in
                    PsmithProfilePlugin(pluginName: p.name, ordinal: Int32(i),
                                        config: try JSONSerialization.data(withJSONObject: p.config, options: [.sortedKeys]))
                }
                try await model.savePlugins(forProfileID: id, plugins: list)
                pluginsBaseline = Self.key(plugins)
            }
            error = nil
            if profile == nil { model.detailMode = .viewing }
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    /// Writes the export to Downloads, next to a number if the name is taken.
    private func export() async {
        guard let id = profile?.id else { return }
        await model.exportProfile(id: id)
        guard let e = model.pendingExport else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (e.suggestedFilename as NSString).deletingPathExtension
        let ext = (e.suggestedFilename as NSString).pathExtension
        var url = downloads.appendingPathComponent(e.suggestedFilename)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        do {
            try e.payload.write(to: url)
            exported = (url.lastPathComponent, url, e.notices)
        } catch {
            self.error = "Couldn't save the export: \(error.localizedDescription)"
        }
    }
}

// MARK: - Import

private struct ImportPage: View {
    @Bindable var model: ProfilesViewModel
    @Environment(Navigator.self) private var navigator
    @Environment(AppModel.self) private var app
    @State private var targeted = false

    var body: some View {
        SKDetailPage {
            SKPageHead("Import a profile", subtitle: "Nothing is created until you import.")
            if let error = model.error { SKBanner(.error, "Couldn't import", message: error) }
            drop
            Color.clear.frame(height: 16)
            if let result = model.pendingImport {
                SKGroup("Creates") {
                    ForEach(result.profiles) { p in
                        let renamed = result.renamed.contains(p.name)
                        SKRow(p.name, detail: renamed ? "You already have one with this name, so this one is renamed."
                              : result.profiles.first { $0.id == p.parentProfileID }.map { "Inherits from \($0.name)" }) {
                            if renamed { SKChip(text: "Renamed") } else { SKChip(text: "New") }
                        }
                    }
                }
                let attention = result.warnings.filter { $0.kind != .renamed }
                if !attention.isEmpty {
                    SKGroup("Needs attention") {
                        ForEach(attention) { w in
                            SKRow(w.message) {
                                switch w.kind {
                                case .providerMissing:
                                    Button("Add Provider") { navigator.settingsCategory = .models; app.providers.startAddingCustom() }.skButton(small: true)
                                case .mcpServerMissing:
                                    Button("Add Server") { navigator.settingsCategory = .servers }.skButton(small: true)
                                default:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { model.cancelImport() }.skButton().keyboardShortcut(.cancelAction)
                    Button(model.isSharing ? "Importing…" : "Import \(result.profiles.count) Profile\(result.profiles.count == 1 ? "" : "s")") {
                        Task { await model.confirmImport() }
                    }
                    .skButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSharing)
                }
            }
        }
    }

    private var drop: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 20)).foregroundStyle(SK.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(importedFileName.isEmpty ? "Drop a .psmithprofile here" : importedFileName).sk(13, weight: .semibold)
                Text("Drop another file to replace it.").sk(11.5, SK.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose Another…") { chooseImport(model) }.skButton()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(targeted ? 0.06 : 0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? SK.accent : Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            previewImport(url, into: model)
            return true
        } isTargeted: { targeted = $0 }
    }
}
