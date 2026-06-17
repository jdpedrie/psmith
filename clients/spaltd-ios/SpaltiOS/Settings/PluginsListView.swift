import SwiftUI
import SpaltKit
import SpaltUI

/// iOS Plugins list. Push from SettingsRoot. Per
/// `docs/clients/ios-reference.md`: lists every plugin (warning icon
/// trailing if required globals unset). Tap → push
/// `PluginSettingsView` containing the shared `PluginConfigForm`.
struct PluginsListView: View {
    @Environment(AppModel.self) private var app
    @State private var loaded = false

    var body: some View {
        @Bindable var profiles = app.profiles
        Group {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if profiles.pluginTypes.isEmpty {
                EmptyStateView(
                    "No plugins compiled in",
                    systemImage: "puzzlepiece.extension",
                    description: "The server's binary was built without any plugins registered. Check your spaltd build."
                )
            } else {
                List {
                    ForEach(profiles.pluginTypes) { plugin in
                        NavigationLink {
                            PluginSettingsScreen(plugin: plugin)
                        } label: {
                            pluginRow(plugin)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if profiles.pluginTypes.isEmpty {
                await profiles.loadPluginTypes()
            }
            await profiles.loadUserPluginSettings()
            loaded = true
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: SpaltPluginType) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.displayName)
                    .foregroundStyle(.primary)
                if !plugin.description.isEmpty {
                    Text(plugin.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if hasUnsetRequiredGlobals(plugin) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Required global settings missing")
            }
        }
    }

    private func hasUnsetRequiredGlobals(_ plugin: SpaltPluginType) -> Bool {
        let blob = app.profiles.globalSettings(for: plugin.name).config
        let dict: [String: Any]
        if blob.isEmpty {
            dict = [:]
        } else {
            dict = (try? JSONSerialization.jsonObject(with: blob) as? [String: Any]) ?? [:]
        }
        for field in plugin.globalConfigFields where field.required {
            if field.isUnsatisfied(by: dict[field.name]) { return true }
        }
        return false
    }
}

// MARK: - Per-plugin detail screen

private struct PluginSettingsScreen: View {
    let plugin: SpaltPluginType
    @Environment(AppModel.self) private var app

    @State private var draft: [String: Any] = [:]
    @State private var seeded = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !plugin.description.isEmpty {
                    Text(plugin.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let globals = plugin.globalConfigFields
                if globals.isEmpty {
                    Text("This plugin has no global settings.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Shared settings — apply to every profile that attaches \(plugin.displayName).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    PluginConfigEditor(
                        pluginName: plugin.name,
                        fields: globals,
                        config: Binding(
                            get: { draft },
                            set: { draft = $0 }
                        )
                    )
                }

                let profileScoped = plugin.profileScopedConfigFields
                if !profileScoped.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Per-profile settings")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text("\(plugin.displayName) also exposes \(profileScoped.count) field\(profileScoped.count == 1 ? "" : "s") that live on each profile that attaches this plugin. Edit those from the profile editor.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .navigationTitle(plugin.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSaving {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .onAppear { seedFromModel() }
        .onChange(of: dirtyKey) { _, _ in
            Task { await save() }
        }
    }

    private var dirtyKey: String {
        guard let data = try? JSONSerialization.data(withJSONObject: draft, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private func seedFromModel() {
        guard !seeded else { return }
        let blob = app.profiles.globalSettings(for: plugin.name).config
        if !blob.isEmpty,
           let dict = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] {
            draft = dict
        } else {
            var initial: [String: Any] = [:]
            for field in plugin.globalConfigFields {
                if !field.defaultJSON.isEmpty,
                   let data = field.defaultJSON.data(using: .utf8),
                   let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    initial[field.name] = any
                }
            }
            draft = initial
        }
        seeded = true
    }

    private func save() async {
        let blob = app.profiles.globalSettings(for: plugin.name).config
        let stored: [String: Any] = (blob.isEmpty)
            ? [:]
            : ((try? JSONSerialization.jsonObject(with: blob) as? [String: Any]) ?? [:])
        if let storedJSON = try? JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys]),
           let draftJSON = try? JSONSerialization.data(withJSONObject: draft, options: [.sortedKeys]),
           storedJSON == draftJSON {
            return
        }
        isSaving = true; saveError = nil
        defer { isSaving = false }
        do {
            let data = try JSONSerialization.data(withJSONObject: draft, options: [.sortedKeys])
            try await app.profiles.upsertUserPluginSettings(pluginName: plugin.name, config: data)
        } catch {
            saveError = SpaltError.display(error)
        }
    }
}
