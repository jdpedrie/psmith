import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Plugins (board SettingsPlugins): every plugin the server
/// offers, built in and from MCP servers, with the state of its shared
/// settings. Attaching happens on a profile.
struct SettingsPlugins: View {
    @Environment(AppModel.self) private var app
    @State private var loaded = false

    var body: some View {
        SettingsPluginsScreen(
            loaded: loaded,
            pluginTypes: app.profiles.pluginTypes.filter { !$0.name.hasPrefix("mcp:") },
            servers: app.mcpServers.servers,
            error: app.profiles.error,
            globals: { app.profiles.globalSettings(for: $0).config },
            onRetry: { Task { await load() } }
        )
        .task { await load() }
    }

    private func load() async {
        app.profiles.error = nil
        if app.profiles.pluginTypes.isEmpty { await app.profiles.loadPluginTypes() }
        async let settings: Void = app.profiles.loadUserPluginSettings()
        async let servers: Void = app.mcpServers.load()
        _ = await (settings, servers)
        loaded = true
    }
}

enum PluginSetup {
    /// Required shared fields the user hasn't filled.
    static func unsetGlobals(_ plugin: PsmithPluginType, config: Data) -> [PsmithConfigField] {
        let dict = decodePluginConfig(config)
        return plugin.globalConfigFields.filter { $0.required && $0.isUnsatisfied(by: dict[$0.name]) }
    }

    /// "Needs an API key", "Needs 2 settings".
    static func needs(_ fields: [PsmithConfigField]) -> String {
        guard fields.count == 1, let f = fields.first else { return "Needs \(fields.count) settings" }
        let name = f.display.hasPrefix("API") ? f.display : f.display.lowercased()
        let article = "aeiouAEIOU".contains(name.first ?? "x") ? "an" : "a"
        return "Needs \(article) \(name)"
    }
}

struct SettingsPluginsScreen: View {
    let loaded: Bool
    let pluginTypes: [PsmithPluginType]
    let servers: [PsmithMCPServer]
    let error: String?
    let globals: (String) -> Data
    let onRetry: () -> Void

    var body: some View {
        IKSettingsPage(title: "Plugins") {
            if !loaded && pluginTypes.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            } else if pluginTypes.isEmpty, let error {
                IKSError(text: "Couldn’t load plugins. \(error)")
                Button("Retry", action: onRetry).ikButton().padding(.top, 10)
            } else {
                if pluginTypes.isEmpty {
                    IKSFooter("This server was built without any plugins.", top: 0)
                } else {
                    IKSHead("Built in", first: true)
                    IKGroup(separatorInset: 14) {
                        ForEach(pluginTypes) { plugin in
                            NavigationLink { SettingsPluginConfig(plugin: plugin) } label: { builtinRow(plugin) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                if !servers.isEmpty {
                    IKSHead("From MCP servers")
                    IKGroup {
                        ForEach(servers) { server in
                            NavigationLink { SettingsServerDetail(serverID: server.id) } label: {
                                row(icon: "server.rack", title: server.name) {
                                    Text(server.transport == "http" ? "http · \(URL(string: server.url)?.host ?? server.url)" : server.summary)
                                        .foregroundStyle(IK.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                IKSFooter("Shared settings, like credentials, apply to every profile that attaches the plugin. Attach plugins from a profile.")
            }
        }
    }

    private func builtinRow(_ plugin: PsmithPluginType) -> some View {
        let unset = PluginSetup.unsetGlobals(plugin, config: globals(plugin.name))
        return row(icon: "puzzlepiece.extension", title: plugin.displayName) {
            if !unset.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(PluginSetup.needs(unset))
                }
                .foregroundStyle(IK.orange)
            } else if plugin.globalConfigFields.isEmpty {
                Text("No shared settings").foregroundStyle(IK.secondary)
            } else {
                Text("Shared settings set").foregroundStyle(IK.secondary)
            }
        }
    }

    private func row<Sub: View>(icon: String, title: String, @ViewBuilder sub: () -> Sub) -> some View {
        IKSRow(vertical: 9) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(IK.strong)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(IK.wash(0.08)))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                sub().font(.system(size: 12.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IKChevron()
        }
    }
}

// MARK: - One plugin's shared settings

/// The draft behind a plugin's shared settings: edits wait in the save bar
/// until Save.
@Observable
@MainActor
final class PluginGlobalsDraft {
    var draft: [String: Any] = [:]
    private(set) var baseline: [String: Any] = [:]
    private(set) var seeded = false

    func seed(stored: Data, plugin: PsmithPluginType) {
        guard !seeded else { return }
        var dict = decodePluginConfig(stored)
        if stored.isEmpty {
            for field in plugin.globalConfigFields where !field.defaultJSON.isEmpty {
                if let data = field.defaultJSON.data(using: .utf8),
                   let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    dict[field.name] = any
                }
            }
        }
        draft = dict
        baseline = dict
        seeded = true
    }

    /// Keys whose value differs from what's stored.
    var changeCount: Int {
        let keys = Set(draft.keys).union(baseline.keys)
        return keys.filter { k in
            switch (draft[k], baseline[k]) {
            case (nil, nil): false
            case (let a?, let b?): !pluginValuesEqual(a, b)
            default: true
            }
        }.count
    }

    func revert() { draft = baseline }

    func markSaved() { baseline = draft }
}

/// Equality on what PluginConfigEditor writes: strings, bools, numbers,
/// arrays and objects of them.
func pluginValuesEqual(_ a: Any, _ b: Any) -> Bool {
    if let a = a as? String, let b = b as? String { return a == b }
    if let a = a as? NSNumber, let b = b as? NSNumber { return a == b }
    if let a = a as? [Any], let b = b as? [Any] {
        return a.count == b.count && zip(a, b).allSatisfy { pluginValuesEqual($0, $1) }
    }
    if let a = a as? [String: Any], let b = b as? [String: Any] {
        return a.count == b.count && a.allSatisfy { k, v in b[k].map { pluginValuesEqual(v, $0) } ?? false }
    }
    return false
}

/// One plugin's page (board SettingsPluginConfig): what it is, its shared
/// settings behind an explicit save bar, and the per-profile fields it also
/// has.
struct SettingsPluginConfig: View {
    let plugin: PsmithPluginType
    @Environment(AppModel.self) private var app
    @State private var draft = PluginGlobalsDraft()
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        SettingsPluginConfigScreen(
            plugin: plugin,
            draft: draft,
            loaded: app.profiles.userPluginSettingsLoaded,
            saving: saving,
            saveError: saveError,
            onRetry: {
                Task {
                    await app.profiles.loadUserPluginSettings()
                    seed()
                }
            },
            onSave: { Task { await save() } }
        )
        .onAppear { seed() }
    }

    private func seed() {
        // Unknown stored settings would seed defaults and then save them over the real ones.
        guard app.profiles.userPluginSettingsLoaded else { return }
        draft.seed(stored: app.profiles.globalSettings(for: plugin.name).config, plugin: plugin)
    }

    private func save() async {
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            try await app.profiles.upsertUserPluginSettings(pluginName: plugin.name, config: encodePluginConfig(draft.draft))
            draft.markSaved()
        } catch {
            saveError = PsmithError.display(error)
        }
    }
}

struct SettingsPluginConfigScreen: View {
    let plugin: PsmithPluginType
    @Bindable var draft: PluginGlobalsDraft
    let loaded: Bool
    let saving: Bool
    let saveError: String?
    let onRetry: () -> Void
    let onSave: () -> Void

    var body: some View {
        IKSettingsPage(title: plugin.displayName) {
            IKGroup {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(plugin.displayName).font(.system(size: 17, weight: .semibold)).foregroundStyle(IK.text)
                        Text(plugin.name).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(IK.tertiary)
                    }
                    if !plugin.description.isEmpty {
                        Text(plugin.description).font(.system(size: 14)).lineSpacing(3).foregroundStyle(IK.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let globals = plugin.globalConfigFields
            IKSHead("Shared settings")
            if !loaded {
                IKGroup {
                    IKSRow(vertical: 10) {
                        Text("Couldn’t load this plugin’s saved settings.").foregroundStyle(IK.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry", action: onRetry).ikButton()
                    }
                }
            } else if globals.isEmpty {
                IKGroup { IKSRow { Text("This plugin has no shared settings.").foregroundStyle(IK.secondary) } }
            } else {
                IKGroup {
                    if globals.allSatisfy({ IKSPluginField.handles($0) }) {
                        ForEach(globals, id: \.name) { field in
                            IKSPluginField(field: field, config: $draft.draft).padding(14)
                        }
                    } else {
                        PluginConfigEditor(pluginName: plugin.name, fields: globals, config: $draft.draft)
                            .padding(14)
                    }
                }
                IKSFooter("Applies to every profile that attaches \(plugin.displayName).")
            }
            if let saveError { IKSError(text: saveError) }

            let scoped = plugin.profileScopedConfigFields
            if !scoped.isEmpty {
                IKSHead("Per-profile settings")
                IKGroup {
                    ForEach(scoped, id: \.name) { field in
                        IKSRow { Text(field.display).foregroundStyle(IK.secondary) }
                    }
                }
                IKSFooter("These live on each profile that attaches \(plugin.displayName). Edit them from the profile’s plugins.")
            }
        } bar: {
            if draft.changeCount > 0 {
                IKSaveBar(summary: SettingsFormat.unsaved(draft.changeCount), canSave: !saving,
                          onRevert: { draft.revert() }, onSave: onSave)
            }
        }
    }
}

/// One plain plugin field drawn in the Settings style: text, long text,
/// number or switch. Anything richer goes through PluginConfigEditor.
/// Fields that hold a credential are masked.
struct IKSPluginField: View {
    let field: PsmithConfigField
    @Binding var config: [String: Any]

    static func handles(_ f: PsmithConfigField) -> Bool {
        switch f.type {
        case .text, .textarea, .number, .boolean: true
        default: false
        }
    }

    private var secret: Bool {
        let n = (field.name + " " + field.display).lowercased()
        return ["key", "token", "secret", "password"].contains { n.contains($0) }
    }

    private var text: Binding<String> {
        Binding(
            get: {
                switch config[field.name] {
                case let s as String: s
                case let n as NSNumber: n.stringValue
                default: ""
                }
            },
            set: { new in
                if field.type == .number {
                    if new.isEmpty { config[field.name] = nil } else if let d = Double(new) { config[field.name] = d }
                } else {
                    config[field.name] = new.isEmpty ? nil : new
                }
            }
        )
    }

    var body: some View {
        switch field.type {
        case .boolean:
            IKSToggle(title: field.display, isOn: Binding(get: { (config[field.name] as? Bool) ?? false }, set: { config[field.name] = $0 })) {
                IKSTitleNote(title: field.display, note: field.description.isEmpty ? nil : field.description, noteSize: 12.5)
            }
        case .textarea:
            IKSTextArea(label: field.display, text: text, caption: field.description.isEmpty ? nil : field.description)
        default:
            IKSStackedField(label: field.display, required: field.required, text: text,
                            caption: field.description.isEmpty ? nil : field.description,
                            mono: secret || field.type == .number, secure: secret)
                .keyboardType(field.type == .number ? .decimalPad : .default)
        }
    }
}
