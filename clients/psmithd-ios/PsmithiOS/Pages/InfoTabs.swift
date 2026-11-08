import SwiftUI
import PsmithKit
import PsmithUI

// MARK: - Settings tab

/// What the next send runs with, and where each value comes from. Read
/// only: the model row opens the picker, the button opens the editor.
struct InfoSettingsTab: View {
    @Bindable var model: ConversationViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let harness = model.harness {
                HarnessBindingCard(binding: harness).padding(.top, 14)
            }
            IKPageHead(text: "Model")
            IKPageGroup {
                NavigationLink(value: ConversationPage.models) {
                    IKPageRow(title: "Model") {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(model.ikModel?.displayName ?? model.ikModelID ?? "None")
                                .font(.system(size: 15.5)).foregroundStyle(IK.text).lineLimit(1)
                            Text(model.ikPinsModel ? "This conversation" : "Profile default")
                                .font(.system(size: 12)).foregroundStyle(model.ikPinsModel ? theme.accentInk : IK.tertiary)
                        }
                        IKPageChevron()
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.canChangeProvider)
            }

            IKPageHead(text: "Call settings")
            IKPageGroup {
                readout("Temperature", { $0.temperature }) { String(format: "%.2f", $0) }
                readout("Top P", { $0.topP }) { String(format: "%.2f", $0) }
                readout("Max output", { $0.maxOutputTokens }) { $0.formatted() }
                readout("Top K", { $0.topK }) { $0.formatted() }
                readout("Thinking", { $0.thinking?.effort }) { $0.label }
                readout("Explicit cache", { $0.explicitCache }) { $0 ? "On" : "Off" }
                readout("Stop sequences", { $0.stopSequences.isEmpty ? nil : $0.stopSequences.count }) { "\($0)" }
            }
            IKPageNote("Unset fields inherit from the profile, then the model.")

            NavigationLink(value: ConversationPage.callSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium))
                    Text("Edit Call Settings").font(.system(size: 15))
                }
                .foregroundStyle(IK.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(IK.wash(0.09)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
    }

    /// The layers in resolution order, highest first, with the word the
    /// row shows for each.
    private var layers: [(PsmithCallSettings?, String)] {
        let pid = model.ikProviderID
        return [
            (model.conversationCallSettingsDraft, "this conversation"),
            (model.settingsResolvedProfile?.defaultSettings?.callSettings, "inherited"),
            (model.ikModel?.defaultSettings, "model"),
            (pid.flatMap { model.providerDefaultSettings[$0] }, "provider"),
        ]
    }

    private func readout<T>(_ title: String, _ get: (PsmithCallSettings) -> T?, _ fmt: (T) -> String) -> some View {
        var shown: (String, String)?
        for (layer, source) in layers {
            if let layer, let v = get(layer) { shown = (fmt(v), source); break }
        }
        return IKPageRow(title: title) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(shown?.0 ?? "Default").font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(shown == nil ? IK.secondary : IK.text)
                if let source = shown?.1 {
                    Text(source).font(.system(size: 12))
                        .foregroundStyle(source == "this conversation" ? theme.accentInk : IK.tertiary)
                }
            }
        }
    }
}

// MARK: - Plugins tab

/// The conversation's plugin pipeline. Switches stage changes; the save
/// bar applies them. Tapping a plugin with settings opens its editor, which
/// saves an override for this conversation only.
struct InfoPluginsTab: View {
    @Bindable var model: ConversationViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Bindable var staging: PluginStaging
    @State private var confirmingClear = false
    @State private var editing: PluginOverrideDraft?

    init(model: ConversationViewModel, staging: PluginStaging) {
        self.model = model
        self.staging = staging
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IKPageNote("Each row is a plugin active in this conversation and where it came from. Switching one off removes it here only. The profile stays as it is.", top: 14)

            IKPageHead(text: "Plugin pipeline")
            if rows.isEmpty {
                IKPageGroup { IKPageRow("No plugins are active here.", titleColor: IK.secondary) }
            } else {
                IKPageGroup {
                    ForEach(rows, id: \.name) { row in pluginRow(row) }
                }
            }
            IKPageNote("Inherited plugins come from \(profileName) and the profiles it’s based on.")

            if !addable.isEmpty {
                IKPageGroup {
                    Menu {
                        ForEach(addable, id: \.name) { t in
                            Button(t.displayName.isEmpty ? t.name : t.displayName) {
                                editing = PluginOverrideDraft(pluginName: t.name, config: initialConfigFromDefaults(t), isNew: true)
                            }
                        }
                    } label: {
                        IKPageRow(title: "Add Plugin Override", titleColor: theme.accentInk) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accentInk)
                        }
                    }
                }
                .padding(.top, 18)
            }

            if !model.conversationPluginOverrides.isEmpty {
                Group {
                    if confirmingClear {
                        IKConfirmCard(question: "Clear all conversation overrides?",
                                      detail: "Every plugin returns to what the profile sets. Settings edited here are lost.",
                                      confirmLabel: "Clear",
                                      onCancel: { withAnimation(.snappy) { confirmingClear = false } },
                                      onConfirm: {
                                          confirmingClear = false
                                          staging.staged = [:]
                                          Task { await model.clearAllConversationOverrides() }
                                      })
                    } else {
                        IKPageGroup {
                            Button { withAnimation(.snappy) { confirmingClear = true } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.uturn.backward").font(.system(size: 14, weight: .medium))
                                    Text("Clear All Conversation Overrides").font(.system(size: 15.5))
                                }
                                .foregroundStyle(IK.red)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 18)
            }
        }
        .navigationDestination(item: $editing) { draft in
            PluginOverrideEditor(initial: draft, model: model) { edited in
                Task {
                    await model.upsertConversationPluginOverride(pluginName: edited.pluginName,
                                                                 config: encodePluginConfig(edited.config))
                }
                editing = nil
            }
        }
    }

    private var rows: [PluginStaging.Row] { staging.rows(model) }

    private var profileName: String {
        model.settingsResolvedProfile?.name
            ?? app.profiles.profiles.first { $0.id == model.conversation.profileID }?.name ?? "the profile"
    }

    private var addable: [PsmithPluginType] {
        let taken = Set(rows.map(\.name))
        return model.registeredPluginTypes.filter { !taken.contains($0.name) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func type(_ name: String) -> PsmithPluginType? { model.registeredPluginTypes.first { $0.name == name } }

    private func displayName(_ name: String) -> String {
        guard let t = type(name), !t.displayName.isEmpty else { return name }
        return t.displayName
    }

    @ViewBuilder
    private func pluginRow(_ row: PluginStaging.Row) -> some View {
        let off = staging.staged[row.name] ?? row.disabled
        let hasFields = type(row.name)?.profileScopedConfigFields.isEmpty == false
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(displayName(row.name)).font(.system(size: 15.5))
                        .foregroundStyle(off ? IK.secondary : IK.text)
                        .strikethrough(off, color: IK.secondary)
                    badge(row, off: off)
                }
                Text(row.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(IK.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasFields, !off else { return }
                let config = model.resolvedPluginPipeline.first { $0.pluginName == row.name }?.config ?? Data()
                editing = PluginOverrideDraft(pluginName: row.name, config: decodePluginConfig(config), isNew: false)
            }
            if hasFields && !off { IKPageChevron() }
            Toggle(displayName(row.name), isOn: Binding(
                get: { !off },
                set: { on in
                    staging.set(row, on: on)
                }))
                .labelsHidden()
                .tint(theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .background(off ? IK.orange.opacity(0.06) : .clear)
        .contextMenu {
            if row.source == .conversation {
                Button("Remove Override", systemImage: "arrow.uturn.backward") {
                    Task { await model.removeConversationOverride(pluginName: row.name) }
                }
            }
        }
    }

    @ViewBuilder
    private func badge(_ row: PluginStaging.Row, off: Bool) -> some View {
        if off {
            IKBadge(text: "Off here", color: IK.orange, fill: IK.orange.opacity(0.18))
        } else if row.source == .conversation {
            IKBadge(text: "This conversation", color: theme.accentInk, fill: theme.accent.opacity(0.22))
        } else {
            IKBadge(text: "Inherited", color: IK.strong, fill: IK.secondary.opacity(0.18))
        }
    }

}

extension ConversationViewModel {
    var resolvedPipelineNames: Set<String> { Set(resolvedPluginPipeline.map(\.pluginName)) }
}

/// The Plugins tab's staged switches. The page owns it so the save bar can
/// float over the bottom safe area outside the scrolling list.
@Observable
@MainActor
final class PluginStaging {
    struct Row { let name: String; let source: PsmithResolvedPipelineSource?; let disabled: Bool }

    /// Plugin name to the disabled state the user wants.
    var staged: [String: Bool] = [:]
    var saving = false

    func rows(_ model: ConversationViewModel) -> [Row] {
        let active = model.resolvedPipelineNames
        var out = model.resolvedPluginPipeline.map { Row(name: $0.pluginName, source: $0.source, disabled: false) }
        for o in model.conversationPluginOverrides where o.disabled && !active.contains(o.pluginName) {
            out.append(Row(name: o.pluginName, source: nil, disabled: true))
        }
        return out
    }

    func set(_ row: Row, on: Bool) {
        staged[row.name] = (!on == row.disabled) ? nil : !on
    }

    func pending(_ model: ConversationViewModel) -> [String] {
        let rows = rows(model)
        return staged.filter { name, off in rows.first { $0.name == name }?.disabled != off }.keys.sorted()
    }

    func revert() { staged = [:] }

    /// Applies each staged switch. A plugin switched off writes a
    /// subtracting override; one switched back on drops it.
    func save(_ model: ConversationViewModel) async {
        let names = pending(model)
        saving = true
        for name in names { await model.toggleConversationDisableInherited(pluginName: name) }
        staged = [:]
        saving = false
    }
}

// MARK: - Plugin override editor

struct PluginOverrideDraft: Identifiable, Hashable {
    let id = UUID()
    var pluginName: String
    var config: [String: Any]
    var isNew: Bool
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// The per-plugin editor, saving an override for this conversation only.
struct PluginOverrideEditor: View {
    let model: ConversationViewModel
    let onSave: (PluginOverrideDraft) -> Void
    @State private var draft: PluginOverrideDraft
    @Environment(AppModel.self) private var app

    init(initial: PluginOverrideDraft, model: ConversationViewModel, onSave: @escaping (PluginOverrideDraft) -> Void) {
        self.model = model
        self.onSave = onSave
        _draft = State(initialValue: initial)
    }

    var body: some View {
        PluginConfigSubScreen(
            pluginName: draft.pluginName,
            pluginType: model.registeredPluginTypes.first { $0.name == draft.pluginName },
            config: $draft.config,
            availableModels: model.availableModels,
            providerLabels: model.providerLabels,
            providerTypes: model.providerTypes,
            providerPresetIDs: model.providerPresetIDs,
            availableProfiles: app.profiles.profiles.map { ($0.id, $0.name) }
        )
        .scrollEdgeEffectStyle(.hard, for: .top)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(draft.isNew ? "Add" : "Save") { onSave(draft) }
                    .fontWeight(.semibold)
                    .foregroundStyle(IK.text)
            }
        }
    }
}
