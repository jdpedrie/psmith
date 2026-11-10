import SwiftUI
import PsmithKit
import PsmithUI

/// What a profile inherits: its ancestors' plugins resolved root first,
/// each level adding or overriding by name and a disabled row taking one
/// away, the same order the server resolves at send time.
@MainActor
enum ProfileInheritance {
    struct Inherited: Identifiable {
        var id: String { pluginName }
        let pluginName: String
        let from: PsmithProfile
    }

    static func inherited(parentID: String?, profiles: ProfilesViewModel) -> [Inherited] {
        let chain = ProfileLookup.ancestors(of: parentID, in: profiles.known)
        var effective: [(String, PsmithProfile)] = []
        for ancestor in chain.reversed() {
            for row in profiles.profilePlugins[ancestor.id] ?? [] {
                effective.removeAll { $0.0 == row.pluginName }
                if !row.disabled { effective.append((row.pluginName, ancestor)) }
            }
        }
        return effective.map { Inherited(pluginName: $0.0, from: $0.1) }
    }

    static func loadChain(parentID: String?, profiles: ProfilesViewModel) async {
        for ancestor in ProfileLookup.ancestors(of: parentID, in: profiles.known)
        where profiles.profilePlugins[ancestor.id] == nil {
            await profiles.loadPlugins(forProfileID: ancestor.id)
        }
    }
}

/// A profile's plugins (board SettingsProfilePlugins): what it inherits,
/// each of which it can turn off, and what it adds. Changes join the
/// profile's draft and its save bar.
struct SettingsProfilePlugins: View {
    @Bindable var draft: ProfileDraft
    @Environment(AppModel.self) private var app
    @State private var configTarget: UUID?

    var body: some View {
        SettingsProfilePluginsScreen(draft: draft, configTarget: $configTarget)
            .navigationDestination(item: $configTarget) { id in ProfilePluginConfigPage(draft: draft, pluginID: id) }
            .task {
                async let own: Void = draft.loadPlugins(app.profiles)
                async let chain: Void = ProfileInheritance.loadChain(parentID: draft.fields.parentProfileID, profiles: app.profiles)
                _ = await (own, chain)
            }
    }
}

struct SettingsProfilePluginsScreen: View {
    @Bindable var draft: ProfileDraft
    @Binding var configTarget: UUID?
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    private var profiles: ProfilesViewModel { app.profiles }
    private var profileName: String { draft.fields.name.isEmpty ? "this profile" : draft.fields.name }
    private var inherited: [ProfileInheritance.Inherited] {
        ProfileInheritance.inherited(parentID: draft.fields.parentProfileID, profiles: profiles)
    }
    private var own: [ProfileDraftPlugin] { draft.plugins.filter { !$0.disabled } }

    var body: some View {
        IKSettingsPage(title: "Plugins") {
            if !inherited.isEmpty, let parent = profiles.profile(id: draft.fields.parentProfileID) {
                HStack(spacing: 6) {
                    Text("From")
                    IKDot(color: ProfileLookup.color(parent, theme: theme), size: 8)
                    Text(parent.name)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IK.tertiary)
                .padding(EdgeInsets(top: 4, leading: 4, bottom: 6, trailing: 4))
                IKGroup {
                    ForEach(inherited) { inheritedRow($0) }
                }
                IKSFooter("Inherited plugins run unless you turn them off here. Their settings belong to \(parent.name).")
            }

            IKSHead("Set here", first: inherited.isEmpty)
            IKGroup {
                if draft.pluginsLoadFailed {
                    IKSRow(vertical: 10) {
                        Text("Couldn’t load this profile’s plugins.").foregroundStyle(IK.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry") { Task { await draft.loadPlugins(profiles) } }.ikButton()
                    }
                } else if !draft.pluginsLoaded {
                    IKSRow { ProgressView().frame(maxWidth: .infinity) }
                } else {
                    ForEach(own) { ownRow($0) }
                    NavigationLink {
                        AddPluginScreen(types: addable) { type in attach(type) }
                    } label: {
                        IKSRow(color: theme.accentInk) {
                            Image(systemName: "plus").font(.system(size: 17)).frame(width: 18)
                            Text("Add plugin").frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(addable.isEmpty)
                }
            }
            IKSFooter("Plugins run in the order you added them. Changes here join \(profileName)’s draft; save them there.")
            if let error = draft.error { IKSError(text: error) }
        } bar: {
            ProfileDraftBar(draft: draft)
        }
    }

    private var addable: [PsmithPluginType] {
        let taken = Set(own.map(\.pluginName))
        return profiles.pluginTypes.filter { !taken.contains($0.name) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func attach(_ type: PsmithPluginType) {
        // An override of an inherited plugin replaces its disabled row, if any.
        draft.plugins.removeAll { $0.pluginName == type.name && $0.disabled }
        let row = ProfileDraftPlugin(pluginName: type.name, config: initialConfigFromDefaults(type))
        draft.plugins.append(row)
        // A plugin with per-profile fields opens straight to them, so a
        // required field isn't left unset by accident.
        if !type.profileScopedConfigFields.isEmpty {
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                configTarget = row.id
            }
        }
    }

    private func isOn(_ name: String) -> Bool { !draft.plugins.contains { $0.pluginName == name && $0.disabled } }

    private func inheritedRow(_ item: ProfileInheritance.Inherited) -> some View {
        let type = profiles.pluginTypes.first { $0.name == item.pluginName }
        let on = isOn(item.pluginName)
        return IKSRow {
            IKSToggle(title: type?.displayName ?? item.pluginName, isOn: Binding(
                get: { on },
                set: { newValue in
                    if newValue {
                        draft.plugins.removeAll { $0.pluginName == item.pluginName && $0.disabled }
                    } else {
                        draft.plugins.append(ProfileDraftPlugin(pluginName: item.pluginName, config: [:], disabled: true))
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(type?.displayName ?? item.pluginName).foregroundStyle(on ? IK.text : IK.secondary)
                    Text(on ? (type?.description ?? "") : "Off for \(profileName)")
                        .font(.system(size: 12.5)).foregroundStyle(IK.secondary).lineLimit(1)
                }
            }
        }
    }

    private func ownRow(_ plugin: ProfileDraftPlugin) -> some View {
        let type = profiles.pluginTypes.first { $0.name == plugin.pluginName }
        let title = type?.displayName ?? plugin.pluginName
        let scoped = type?.profileScopedConfigFields ?? []
        let required = scoped.filter { $0.isUnsatisfied(by: plugin.config[$0.name]) }.count
        let globalUnset = type.map { PluginSetup.unsetGlobals($0, config: profiles.globalSettings(for: $0.name).config) } ?? []
        return HStack(alignment: .top, spacing: 0) {
            Button {
                draft.plugins.removeAll { $0.id == plugin.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, IK.destructiveFill)
                    .frame(width: 34, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6)
            .accessibilityLabel("Remove \(title)")
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    configTarget = plugin.id
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(IK.text)
                            if let d = type?.description, !d.isEmpty {
                                Text(d).font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(IK.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        IKChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure \(title)")
                let chips = type?.capabilities.toolProvider == true || !globalUnset.isEmpty || required > 0
                if chips {
                    HStack(spacing: 6) {
                        if type?.capabilities.toolProvider == true { IKSChip(text: "Tool") }
                        if let type, !globalUnset.isEmpty {
                            NavigationLink { SettingsPluginConfig(plugin: type) } label: {
                                IKSChip(text: "Global setup needed", warning: true)
                            }
                            .buttonStyle(.plain)
                        }
                        if required > 0 { IKSChip(text: "\(required) required", warning: true) }
                    }
                    .padding(.top, 7)
                }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 14))
    }
}

/// Plugins not yet attached; picking one attaches it and comes back.
struct AddPluginScreen: View {
    let types: [PsmithPluginType]
    let onPick: (PsmithPluginType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        IKSettingsPage(title: "Add plugin") {
            IKGroup {
                if types.isEmpty {
                    IKSRow { Text("Every plugin is already attached.").foregroundStyle(IK.secondary) }
                }
                ForEach(types) { type in
                    Button {
                        onPick(type)
                        dismiss()
                    } label: {
                        IKSRow(vertical: 9) {
                            Image(systemName: type.name.hasPrefix("mcp:") ? "server.rack" : "puzzlepiece.extension")
                                .font(.system(size: 14))
                                .foregroundStyle(IK.strong)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8).fill(IK.wash(0.08)))
                            IKSTitleNote(title: type.displayName, note: type.description.isEmpty ? nil : type.description, noteSize: 12.5)
                            Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(IK.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// One attached plugin's per-profile fields. Edits write straight into the
/// profile's draft.
struct ProfilePluginConfigPage: View {
    @Bindable var draft: ProfileDraft
    let pluginID: UUID
    @Environment(AppModel.self) private var app

    var body: some View {
        let row = draft.plugins.first { $0.id == pluginID }
        let type = app.profiles.pluginTypes.first { $0.name == row?.pluginName }
        IKSettingsPage(title: type?.displayName ?? row?.pluginName ?? "Plugin") {
            if let type, row != nil {
                if !type.description.isEmpty { IKSFooter(type.description, top: 0) }
                IKSHead("For this profile")
                if type.profileScopedConfigFields.isEmpty {
                    IKGroup { IKSRow { Text("Nothing to set per profile.").foregroundStyle(IK.secondary) } }
                } else {
                IKGroup {
                    PluginConfigEditor(
                        pluginName: type.name,
                        fields: type.profileScopedConfigFields,
                        config: Binding(
                            get: { draft.plugins.first { $0.id == pluginID }?.config ?? [:] },
                            set: { new in
                                if let i = draft.plugins.firstIndex(where: { $0.id == pluginID }) { draft.plugins[i].config = new }
                            }
                        ),
                        availableModels: app.profiles.availableModels,
                        providerLabels: app.profiles.providerLabels,
                        providerTypes: app.profiles.providerTypes,
                        providerPresetIDs: app.profiles.providerPresetIDs,
                        availableProfiles: app.profiles.profiles.map { ($0.id, $0.name) }
                    )
                    .padding(14)
                }
                }
                IKSFooter("Shared settings, like credentials, live in Settings › Plugins.")
            } else {
                IKSFooter("This plugin isn’t attached any more.", top: 0)
            }
        } bar: {
            ProfileDraftBar(draft: draft)
        }
    }
}
