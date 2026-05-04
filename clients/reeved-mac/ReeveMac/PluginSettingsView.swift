import SwiftUI
import ReeveKit
import ReeveUI

/// Plugin Settings — the user-scoped surface for plugin config fields
/// the plugin marks `Global=true`. The middle column lists every
/// registered plugin (sorted by display name); the detail column shows
/// the global config form for whichever plugin is selected, plus a
/// preview banner of the plugin's profile-scoped fields ("these live in
/// per-profile plugin settings, not here") so users see the full surface
/// at a glance.
///
/// Save is per-plugin (auto-save on field commit, with a small saving
/// indicator). The form binds against the view-model's
/// `userPluginSettings[name]` cache; the cache is repopulated by the
/// repository after each upsert.

// MARK: - Middle column

struct PluginSettingsMiddleColumn: View {
    @Bindable var model: ProfilesViewModel
    let onBack: () -> Void
    @Environment(\.theme) private var theme
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsListHeader(
                title: "Plugins",
                count: model.pluginTypes.count,
                countNoun: "plugin",
                onBack: onBack,
                onCreate: { /* not creatable */ },
                createDisabled: true
            )
            Divider()

            if !loaded {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else if model.pluginTypes.isEmpty {
                EmptyStateView(
                    "No plugins compiled in",
                    systemImage: "puzzlepiece.extension",
                    description: nil
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.pluginTypes) { plugin in
                            PluginListRow(
                                plugin: plugin,
                                isSelected: model.selectedPluginID == plugin.name,
                                hasUnsetRequiredGlobals: hasUnsetRequiredGlobals(plugin)
                            ) {
                                model.selectedPluginID = plugin.name
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .task {
            if model.pluginTypes.isEmpty {
                await model.loadPluginTypes()
            }
            await model.loadUserPluginSettings()
            // Auto-select the first plugin so the detail pane isn't a
            // bare empty state on entry.
            if model.selectedPluginID == nil {
                model.selectedPluginID = model.pluginTypes.first?.name
            }
            loaded = true
        }
    }

    private func hasUnsetRequiredGlobals(_ plugin: ReevePluginType) -> Bool {
        let blob = model.globalSettings(for: plugin.name).config
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

private struct PluginListRow: View {
    let plugin: ReevePluginType
    let isSelected: Bool
    let hasUnsetRequiredGlobals: Bool
    let onSelect: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    if !plugin.description.isEmpty {
                        Text(plugin.description)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if hasUnsetRequiredGlobals {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.orange))
                        .help("Required global settings missing.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail column

struct PluginSettingsDetail: View {
    @Bindable var model: ProfilesViewModel

    var body: some View {
        Group {
            if let id = model.selectedPluginID,
               let plugin = model.pluginTypes.first(where: { $0.name == id }) {
                PluginSettingsForm(plugin: plugin, model: model)
            } else {
                EmptyStateView(
                    "Select a plugin",
                    systemImage: "puzzlepiece.extension",
                    description: "Plugins listed here have settings that apply across every profile that uses them — credentials and other shared values."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Detail form

private struct PluginSettingsForm: View {
    let plugin: ReevePluginType
    @Bindable var model: ProfilesViewModel

    @State private var draft: [String: Any] = [:]
    @State private var seeded = false
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
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
                        PluginConfigForm(
                            fields: globals,
                            config: Binding(
                                get: { draft },
                                set: { draft = $0 }
                            )
                        )
                    }

                    let profileScoped = plugin.profileScopedConfigFields
                    if !profileScoped.isEmpty {
                        Divider().padding(.vertical, 4)
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
                        Text(saveError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.leading, 24)
                .padding(.trailing, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { seedFromModel() }
        .onChange(of: plugin.id) { _, _ in
            seeded = false
            seedFromModel()
        }
        .onChange(of: dirtyKey) { _, _ in
            // Auto-save on each change; debounce-by-task avoids racing the
            // repository on rapid keystrokes (we always run with the
            // latest draft value; older Tasks no-op).
            Task { await save() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(plugin.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isSaving {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: paneHeaderHeight)
    }

    /// Stable hash of the draft used as the auto-save trigger. We can't
    /// use draft itself with `.onChange` because `[String: Any]` isn't
    /// Equatable; encoding to JSON gives us a deterministic key.
    private var dirtyKey: String {
        guard let data = try? JSONSerialization.data(withJSONObject: draft, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private func seedFromModel() {
        guard !seeded else { return }
        let blob = model.globalSettings(for: plugin.name).config
        if !blob.isEmpty,
           let dict = try? JSONSerialization.jsonObject(with: blob) as? [String: Any] {
            draft = dict
        } else {
            // Pull defaults out of the descriptor so booleans/numbers
            // start with their declared default.
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
        // Skip the initial onChange that fires from seeding the draft.
        // We diff against what's currently stored — if equal, nothing
        // to save.
        let blob = model.globalSettings(for: plugin.name).config
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
            try await model.upsertUserPluginSettings(pluginName: plugin.name, config: data)
        } catch {
            saveError = error.localizedDescription
        }
    }
}
