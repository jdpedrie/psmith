import SwiftUI
import PsmithKit
import PsmithUI

// MARK: - Plugins

/// The Plugins pane (board "Plugins · shared settings"): every plugin on
/// the left; a plugin's settings that apply to every profile using it,
/// and which profiles do, on the right.
struct PluginsPane: View {
    @Bindable var model: ProfilesViewModel
    @Environment(AppModel.self) private var app
    @State private var filter = ""

    var body: some View {
        SKSplit(scrollsDetail: false) {
            SKSearchField(placeholder: "Filter plugins", text: $filter).padding(.top, 8).padding(.bottom, 2)
            SKListHeader(text: "Plugins")
            ForEach(shown) { t in
                let on = model.selectedPluginID == t.name
                SKListItem(
                    title: t.displayName,
                    selected: on,
                    action: { model.selectedPluginID = t.name },
                    lead: {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 12)).foregroundStyle(on ? .white : SK.secondary).frame(width: 16)
                    },
                    trail: {
                        if needsSetup(t) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(on ? .white : SK.orange)
                                .accessibilityLabel("Needs setup")
                        } else if isMCP(t) {
                            SKChip(text: "MCP", color: on ? .white : SK.secondary)
                        }
                    }
                )
                .help(t.description)
            }
            if model.pluginTypes.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        } detail: {
            if let t = model.pluginTypes.first(where: { $0.name == model.selectedPluginID }) {
                PluginDetail(model: model, plugin: t).id(t.name)
            } else {
                SKDetailPage { SKPageHead("Plugins", subtitle: "Pick one to see the settings it shares across profiles.") }
            }
        }
        .task {
            if model.pluginTypes.isEmpty { await model.loadPluginTypes() }
            await model.loadUserPluginSettings()
            if app.mcpServers.servers.isEmpty { await app.mcpServers.load() }
            if model.selectedPluginID == nil { model.selectedPluginID = model.pluginTypes.first?.name }
            if model.profiles.isEmpty { await model.load() }
            await model.loadAvailableModels()
            // "Used by" needs every profile's attachments.
            for p in model.profiles where model.profilePlugins[p.id] == nil { await model.loadPlugins(forProfileID: p.id) }
        }
    }

    private var shown: [PsmithPluginType] {
        let q = filter.lowercased()
        return model.pluginTypes.filter { q.isEmpty || $0.displayName.lowercased().contains(q) }
    }

    private func isMCP(_ t: PsmithPluginType) -> Bool {
        app.mcpServers.servers.contains { $0.name == t.name || $0.name == t.displayName }
    }

    private func needsSetup(_ t: PsmithPluginType) -> Bool {
        let values = PluginDetail.dict(model.globalSettings(for: t.name).config)
        return t.globalConfigFields.contains { $0.required && $0.isUnsatisfied(by: values[$0.name]) }
    }
}

private struct PluginDetail: View {
    @Bindable var model: ProfilesViewModel
    let plugin: PsmithPluginType
    @Environment(Navigator.self) private var navigator
    @State private var values: [String: Any] = [:]
    @State private var baseline = ""
    @State private var saving = false
    @State private var error: String?

    static func dict(_ data: Data) -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func key(_ v: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
    }

    private var users: [PsmithProfile] {
        model.profiles.filter { p in (model.profilePlugins[p.id] ?? []).contains { $0.pluginName == plugin.name } }
    }

    private var missing: PsmithConfigField? {
        plugin.globalConfigFields.first { $0.required && $0.isUnsatisfied(by: values[$0.name]) }
    }

    private var logos: [String: String] {
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

    var body: some View {
        SKDetailPage {
            SKPageHead(plugin.displayName, subtitle: plugin.description.isEmpty ? nil : plugin.description)
            if let missing {
                let names = users.map(\.name)
                SKBanner(.warning, "Needs \(Self.article(missing))\(missing.display.isEmpty ? missing.name : missing.display.lowercased()) before it works",
                         message: names.isEmpty ? "No profile uses it yet." : "\(Self.list(names)) \(names.count == 1 ? "has" : "have") it attached. It doesn't run until this is set.")
            }
            if let error { SKBanner(.error, "Couldn't save", message: error) }
            if plugin.globalConfigFields.isEmpty {
                SKGroup("Shared settings") {
                    SKRawRow { Text("This plugin has no shared settings. Anything it needs is set on each profile.").sk(13, SK.secondary) }
                }
            } else if !model.userPluginSettingsLoaded {
                SKBanner(kind: .error, title: "Couldn't load this plugin's saved settings", message: model.error) {
                    Button("Retry") { Task { await model.loadUserPluginSettings() } }.skButton(small: true)
                }
            } else {
                SKPluginFields(fields: plugin.globalConfigFields, values: $values, models: model.availableModels,
                               providerLabels: model.providerLabels, providerLogos: logos, profiles: model.profiles,
                               mainTitle: "Shared settings", trailing: AnyView(SKChip.synced))
            }
            SKGroup("Used by") {
                if users.isEmpty {
                    SKRawRow { Text("No profile uses it yet. Attach it from a profile's Plugins tab.").sk(13, SK.secondary) }
                }
                ForEach(users) { p in
                    SKRow(p.name) {
                        Button {
                            model.detailMode = .viewing
                            model.select(p.id)
                            navigator.settingsProfileTab = .plugins
                            navigator.settingsCategory = .profiles
                        } label: {
                            HStack(spacing: 4) { Text("Open"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                        }
                        .skButton(.plain)
                    }
                }
            } footer: {
                if !plugin.profileScopedConfigFields.isEmpty {
                    Text("Each profile also has \(plugin.profileScopedConfigFields.count) setting\(plugin.profileScopedConfigFields.count == 1 ? "" : "s") of its own for this plugin. Change those on the profile's Plugins tab.")
                }
            }
        } bottom: {
            if Self.key(values) != baseline {
                SKSaveBar(summary: changeSummary, saving: saving, onDiscard: seed, onSave: { Task { await save() } })
            }
        }
        .onAppear(perform: seed)
    }

    private var changeSummary: String {
        let before = Self.dict(model.globalSettings(for: plugin.name).config)
        let changed = plugin.globalConfigFields.filter { f in
            Self.key([f.name: values[f.name] ?? NSNull()]) != Self.key([f.name: before[f.name] ?? NSNull()])
        }
        guard let first = changed.first else { return "Unsaved changes" }
        let name = first.display.isEmpty ? first.name : first.display
        let added = before[first.name] == nil && values[first.name] != nil
        return changed.count == 1 ? "\(name) \(added ? "added" : "changed")" : "\(name) and \(changed.count - 1) more changed"
    }

    private func seed() {
        values = Self.dict(model.globalSettings(for: plugin.name).config)
        baseline = Self.key(values)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.upsertUserPluginSettings(pluginName: plugin.name,
                                                     config: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]))
            baseline = Self.key(values)
            error = nil
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    static func article(_ f: PsmithConfigField) -> String {
        let n = (f.display.isEmpty ? f.name : f.display).lowercased()
        return n.hasSuffix("s") ? "" : (["a", "e", "i", "o", "u"].contains(n.first.map(String.init) ?? "") ? "an " : "a ")
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

// MARK: - Servers

/// The Servers pane (board "Servers · an MCP server"): registered MCP
/// servers on the left; one server's connection, its tools, and delete.
struct ServersPane: View {
    @Bindable var model: MCPServersViewModel

    /// "http · api.example.com", "stdio · npx", "in-process": the host, not
    /// the whole URL, so it fits the list.
    static func summary(_ s: PsmithMCPServer) -> String {
        switch s.transport {
        case "http":
            let host = URL(string: s.url).flatMap { u in u.host.map { $0 + (u.port.map { ":\($0)" } ?? "") } } ?? s.url
            return "http · \(host)"
        case "stdio": return "stdio · \(s.command)"
        default: return "in-process"
        }
    }

    var body: some View {
        SKSplit(scrollsDetail: false) {
            SKListHeader(text: "MCP servers")
            ForEach(model.servers) { s in
                let on = !model.isAddingNew && model.selectedID == s.id
                SKListItem(
                    title: s.name,
                    subtitle: Self.summary(s),
                    selected: on,
                    action: { model.select(s.id) },
                    lead: { Image(systemName: "server.rack").font(.system(size: 12)).foregroundStyle(on ? .white : SK.secondary).frame(width: 16) },
                    trail: {
                        if case .result(let r) = model.testStates[s.id] { SKDot(color: r.ok ? SK.green : SK.red) }
                    }
                )
            }
            if model.isLoading, model.servers.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            SKAddItem(title: "Add server…", selected: model.isAddingNew) { model.startAdding() }
        } detail: {
            if model.isAddingNew {
                ServerPage(model: model, server: nil).id("new")
            } else if let s = model.selected {
                ServerPage(model: model, server: s).id(s.id)
            } else {
                SKDetailPage { SKPageHead("No servers yet", subtitle: "Add one and it shows up as a plugin in every profile and conversation.") }
            }
        }
        .task {
            if model.servers.isEmpty { await model.load() }
            if model.selectedID == nil, !model.isAddingNew, let first = model.servers.first { model.select(first.id) }
        }
    }
}

private struct ServerPage: View {
    @Bindable var model: MCPServersViewModel
    let server: PsmithMCPServer?

    @State private var name = ""
    @State private var transport = "http"
    @State private var url = ""
    @State private var headers = ""
    @State private var clearHeaders = false
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    @State private var clearEnv = false
    @State private var prefix = ""
    @State private var saving = false
    @State private var confirmingDelete = false

    private var adding: Bool { server == nil }

    var body: some View {
        SKDetailPage {
            SKPageHead(title: adding ? "Add a server" : server!.name,
                       subtitle: adding ? "Register an MCP server once. It shows up as a plugin in every profile and conversation."
                                        : "Shows up as a plugin in every profile and conversation.") {
                if let id = server?.id {
                    Button(model.testStates[id] == .testing ? "Testing…" : "Test Connection") { Task { await model.test(id: id) } }
                        .skButton()
                        .disabled(model.testStates[id] == .testing || !changes.isEmpty)
                }
            }
            if let error = model.error { SKBanner(.error, adding ? "Couldn't add the server" : "Couldn't save", message: error) }
            SKGroup("Server") {
                SKRow("Name", detail: "The plugin's name in pickers.") { SKTextField(label: "Name", text: $name, placeholder: "GitHub", width: 260) }
                SKRow("Connects over") {
                    SKSegmented(options: [("http", "HTTP"), ("stdio", "Command"), ("inproc", "In-process")], selection: $transport)
                }
                switch transport {
                case "http":
                    SKRow("URL") { SKTextField(label: "URL", text: $url, placeholder: "https://example.com/mcp", width: 300, mono: true) }
                    secretArea("Headers", detail: "One KEY: VALUE per line, usually the auth header.", saved: server?.hasHeaders == true,
                               text: $headers, cleared: $clearHeaders, placeholder: "Authorization: Bearer …")
                case "stdio":
                    SKRow("Command", detail: "Found on the server's PATH.") { SKTextField(label: "Command", text: $command, placeholder: "npx", width: 300, mono: true) }
                    SKRawRow {
                        VStack(alignment: .leading, spacing: 7) {
                            SKLabel(title: "Arguments", detail: "One per line.")
                            SKTextArea(text: $args, lines: 3, mono: true)
                        }
                    }
                    secretArea("Environment", detail: "KEY=VALUE per line. The command sees nothing else.", saved: server?.hasEnv == true,
                               text: $env, cleared: $clearEnv, placeholder: "GITHUB_TOKEN=…")
                default:
                    SKRawRow { Text("Uses this Psmith server's own MCP tools. Nothing to set.").sk(13, SK.secondary) }
                }
                SKRow("Tool prefix", detail: "Keeps two servers' tools from colliding. Optional.") {
                    SKTextField(label: "Tool prefix", text: $prefix, placeholder: "gh_", width: 120, mono: true)
                }
            } trailing: {
                SKChip.synced
            }
            if let id = server?.id, let state = model.testStates[id] {
                SKGroup("Connection") {
                    switch state {
                    case .testing:
                        SKRawRow { HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Connecting…").sk(12.5, SK.secondary) } }
                    case .result(let r) where r.ok:
                        SKRawRow {
                            HStack(spacing: 7) {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(SK.green)
                                Text("Connected · \(r.toolNames.count) tool\(r.toolNames.count == 1 ? "" : "s") · tested just now").sk(12.5, SK.green)
                            }
                        }
                        if !r.toolNames.isEmpty {
                            SKRawRow {
                                SKFlow(spacing: 6) {
                                    ForEach(r.toolNames.prefix(12), id: \.self) { SKChip(text: $0, color: SK.text) }
                                    if r.toolNames.count > 12 { SKChip(text: "+\(r.toolNames.count - 12) more") }
                                }
                            }
                        }
                    case .result(let r):
                        SKRawRow {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(SK.red)
                                    Text("Couldn't connect").sk(12.5, SK.red)
                                }
                                Text(r.errorMessage).sk(11.5, SK.secondary, mono: true).textSelection(.enabled).padding(.leading, 21)
                            }
                        }
                    }
                }
            }
            if let server {
                SKGroup {
                    if confirmingDelete {
                        SKRawRow(vertical: 8, horizontal: 8) {
                            SKConfirmStrip(question: "Delete \(server.name)?", detail: "Profiles keep the attachment, and it stops doing anything.",
                                           confirmLabel: "Delete Server", onCancel: { confirmingDelete = false },
                                           onConfirm: { confirmingDelete = false; Task { _ = await model.delete(id: server.id) } })
                        }
                    } else {
                        SKRow("Delete server", detail: "Profiles keep the attachment, and it stops doing anything.") {
                            Button("Delete…") { confirmingDelete = true }.skButton(.destructive)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { model.isAddingNew = false; model.selectedID = model.servers.first?.id }.skButton().keyboardShortcut(.cancelAction)
                    Button(saving ? "Adding…" : "Add Server") { Task { await save() } }
                        .skButton(.primary).keyboardShortcut(.defaultAction)
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } bottom: {
            if !adding, !changes.isEmpty {
                SKSaveBar(summary: IntegrationsPane.summary(changes), saving: saving, onDiscard: seed, onSave: { Task { await save() } })
            }
        }
        .onAppear(perform: seed)
    }

    private func secretArea(_ title: String, detail: String, saved: Bool, text: Binding<String>, cleared: Binding<Bool>, placeholder: String) -> some View {
        SKRawRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    SKLabel(title: title, detail: detail)
                    if saved, !cleared.wrappedValue {
                        HStack(spacing: 6) {
                            Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(SK.secondary)
                            Text("Saved").sk(12.5, SK.secondary)
                            Button("Clear") { cleared.wrappedValue = true; text.wrappedValue = "" }.skButton(.plain)
                        }
                    } else if cleared.wrappedValue {
                        Text("Clears when you save").sk(12.5, SK.orange)
                    }
                }
                ZStack(alignment: .topLeading) {
                    SKTextArea(text: text, lines: 2, mono: true)
                    if text.wrappedValue.isEmpty {
                        Text(saved && !cleared.wrappedValue ? "Type to replace the saved \(title.lowercased())" : placeholder)
                            .sk(12, SK.tertiary, mono: true).padding(.horizontal, 9).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var changes: [String] {
        guard let s = server else { return [] }
        var out: [String] = []
        if name != s.name { out.append("Name") }
        if transport != s.transport { out.append("Transport") }
        if url != s.url { out.append("URL") }
        if !headers.isEmpty || clearHeaders { out.append("Headers") }
        if command != s.command { out.append("Command") }
        if args != s.args { out.append("Arguments") }
        if !env.isEmpty || clearEnv { out.append("Environment") }
        if prefix != s.toolPrefix { out.append("Tool prefix") }
        return out
    }

    private func seed() { seed(from: server) }

    private func seed(from server: PsmithMCPServer?) {
        guard let s = server else { return }
        name = s.name; transport = s.transport; url = s.url; command = s.command; args = s.args; prefix = s.toolPrefix
        headers = ""; env = ""; clearHeaders = false; clearEnv = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        // Secrets: nil keeps what's stored, empty clears it.
        let h: String? = clearHeaders ? (headers.isEmpty ? "" : headers) : (headers.isEmpty ? nil : headers)
        let e: String? = clearEnv ? (env.isEmpty ? "" : env) : (env.isEmpty ? nil : env)
        if let saved = await model.upsert(id: server?.id, name: name.trimmingCharacters(in: .whitespaces), transport: transport,
                                          command: command, args: args, env: e, url: url, headers: h, toolPrefix: prefix) {
            model.isAddingNew = false
            model.select(saved.id)
            // `server` is still the value from before the save here.
            seed(from: saved)
        }
    }
}

/// Wraps its children onto as many lines as they need.
struct SKFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
