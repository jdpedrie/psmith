import SwiftUI
import ReeveKit
import ReeveUI

/// iOS conversation-settings — pushed onto the conversation's
/// NavigationStack per `docs/clients/ios-reference.md` Two segmented tabs:
/// **Call Settings** (the shared CallSettingsForm) and **Plugins** (a
/// per-row view of the merged pipeline with inheritance badges +
/// per-row disable/restore + per-row edit + add-new-override against
/// the conversation override slot).
/// Call-settings draft auto-saves on disappear; plugin overrides
/// persist immediately on each toggle / save.
struct ConversationSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case callSettings = "Call Settings"
        case plugins      = "Plugins"
        var id: String { rawValue }
    }

    @Bindable var model: ConversationViewModel
    @State private var tab: Tab = .callSettings

    /// Draft state for the active per-plugin config push. Identifiable
    /// so `.navigationDestination(item:)` can pop when nil. The parent
    /// owns the dict so the editor's PluginConfigForm can write through
    /// the binding; on save we hand the encoded bytes to the VM.
    @State private var pluginEdit: PluginEditDraft?
    @State private var showingAddPluginSheet: Bool = false

    var body: some View {
        Group {
            if model.preparingSettingsView {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch tab {
                            case .callSettings: callSettingsTab
                            case .plugins:      pluginsTab
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.prepareSettingsView()
        }
        .onDisappear {
            Task { await model.saveCallSettings() }
        }
        .sheet(isPresented: $showingAddPluginSheet) {
            AddPluginSheet(types: addablePluginTypes) { type in
                showingAddPluginSheet = false
                // Seed the draft from the type's declared defaults and push
                // the same per-plugin editor the profile flow uses.
                pluginEdit = PluginEditDraft(
                    pluginName: type.name,
                    config: initialConfigFromDefaults(type),
                    isNew: true
                )
            }
        }
        .navigationDestination(item: $pluginEdit) { draftSnapshot in
            // The screen owns its own draft state seeded from
            // `draftSnapshot` — pulling the bound `pluginEdit` would
            // briefly flash an empty form during the pop animation
            // when the parent nil-clears the item.
            PluginEditScreen(
                initial: draftSnapshot,
                pluginType: registeredType(forName: draftSnapshot.pluginName),
                availableModels: model.availableModels,
                providerLabels: model.providerLabels,
                providerTypes: model.providerTypes,
                providerPresetIDs: model.providerPresetIDs,
                onSave: { editedDraft in
                    let data = encodePluginConfig(editedDraft.config)
                    Task {
                        await model.upsertConversationPluginOverride(
                            pluginName: editedDraft.pluginName,
                            config: data
                        )
                    }
                    pluginEdit = nil
                },
                onCancel: { pluginEdit = nil }
            )
        }
    }

    // MARK: - Call Settings tab

    private var callSettingsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Conversation overrides")
                    .font(.headline)
                Text("Any field left unset inherits from the resolved profile (and below). Changes auto-save when you go back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CallSettingsForm(
                settings: $model.conversationCallSettingsDraft,
                inheritedSettings: model.resolvedCallSettings,
                driverType: effectiveDriverType,
                modelCapabilities: effectiveModelCapabilities,
                modelConstraints: effectiveModelConstraints
            )
        }
    }

    // MARK: - Plugins tab

    private var pluginsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plugin pipeline")
                    .font(.headline)
                Text("Each row shows a plugin that's currently active for this conversation, with where it came from. Tap a row to edit its config — saving writes a conversation-level override on top of the profile chain. Disable a row to subtract it for this conversation only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.resolvedPluginPipeline.isEmpty && subtractedRows.isEmpty {
                Text("No plugins are active for this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.resolvedPluginPipeline) { entry in
                        pluginRow(for: entry)
                    }
                    ForEach(subtractedRows, id: \.self) { name in
                        subtractedRow(for: name)
                    }
                }
            }

            // Add plugin override entry point. Only enabled when there's
            // at least one type we don't already have (active or
            // subtracted).
            Button {
                showingAddPluginSheet = true
            } label: {
                Label("Add plugin override", systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(addablePluginTypes.isEmpty)
            .padding(.top, 4)

            if !model.conversationPluginOverrides.isEmpty {
                Divider().padding(.vertical, 4)
                Button(role: .destructive) {
                    Task { await model.clearAllConversationOverrides() }
                } label: {
                    Label("Clear all conversation overrides", systemImage: "arrow.uturn.backward")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var subtractedRows: [String] {
        let active = Set(model.resolvedPluginPipeline.map { $0.pluginName })
        return model.conversationPluginOverrides
            .filter { $0.disabled && !active.contains($0.pluginName) }
            .map { $0.pluginName }
    }

    /// Plugin types eligible for the "+ Add" sheet — anything in the
    /// registered catalog that isn't currently active in the merged
    /// pipeline AND isn't sitting as a disabled subtract row.
    private var addablePluginTypes: [ReevePluginType] {
        let active = Set(model.resolvedPluginPipeline.map { $0.pluginName })
        let subtracted = Set(model.conversationPluginOverrides
            .filter { $0.disabled }
            .map { $0.pluginName })
        return model.registeredPluginTypes
            .filter { !active.contains($0.name) && !subtracted.contains($0.name) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @ViewBuilder
    private func pluginRow(for entry: ReeveResolvedPipelineEntry) -> some View {
        let displayName = displayName(for: entry.pluginName)
        let source = entry.source
        let hasFields = registeredType(forName: entry.pluginName)?
            .profileScopedConfigFields.isEmpty == false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.callout.weight(.medium))
                sourceBadge(for: source)
                Spacer()
            }
            Text(entry.pluginName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                if hasFields {
                    Button("Edit config") {
                        pluginEdit = PluginEditDraft(
                            pluginName: entry.pluginName,
                            config: decodePluginConfig(entry.config),
                            isNew: false
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                if source == .profile {
                    Button("Disable here") {
                        Task { await model.toggleConversationDisableInherited(pluginName: entry.pluginName) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if source == .conversation {
                    Button("Remove override") {
                        Task { await model.removeConversationOverride(pluginName: entry.pluginName) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func subtractedRow(for pluginName: String) -> some View {
        let displayName = displayName(for: pluginName)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .strikethrough()
                Text("Disabled")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.orange.opacity(0.2))
                    )
                    .foregroundStyle(Color.orange)
                Spacer()
            }
            Text(pluginName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Restore") {
                    Task { await model.toggleConversationDisableInherited(pluginName: pluginName) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    @ViewBuilder
    private func sourceBadge(for source: ReeveResolvedPipelineSource) -> some View {
        let (label, color): (String, Color) = {
            switch source {
            case .profile:      return ("Inherited", .secondary)
            case .conversation: return ("Override", .accentColor)
            case .unspecified:  return ("Unknown", .secondary)
            }
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.2))
            )
            .foregroundStyle(color)
    }

    private func displayName(for pluginName: String) -> String {
        if let t = registeredType(forName: pluginName) {
            return t.displayName.isEmpty ? pluginName : t.displayName
        }
        return pluginName
    }

    private func registeredType(forName name: String?) -> ReevePluginType? {
        guard let name else { return nil }
        return model.registeredPluginTypes.first(where: { $0.name == name })
    }

    // MARK: - Driver / model resolution

    private var effectiveDriverType: String {
        if let pid = effectiveProviderID, let type = model.providerTypes[pid] {
            return type
        }
        return "anthropic"
    }

    /// Provider the NEXT SEND will actually use, in precedence order:
    /// the composer's live selection (what the model chip shows),
    /// then the conversation default, then the profile default. The
    /// old conversation-default-first order ignored the composer
    /// selection the user was looking at, so the extras tab and the
    /// temperature range tracked the wrong provider.
    private var effectiveProviderID: String? {
        if let pid = model.selectedProviderID, !pid.isEmpty { return pid }
        if let pid = model.conversation.settings?.defaultProviderID, !pid.isEmpty { return pid }
        return model.settingsResolvedProfile?.defaultSettings?.defaultProviderID
    }

    private var effectiveModelID: String? {
        if let mid = model.selectedModelID, !mid.isEmpty { return mid }
        if let mid = model.conversation.settings?.defaultModelID, !mid.isEmpty { return mid }
        return model.settingsResolvedProfile?.defaultSettings?.defaultModelID
    }

    private var effectiveModelCapabilities: ReeveModelCapabilities? {
        guard let pid = effectiveProviderID, let mid = effectiveModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .capabilities
    }

    private var effectiveModelConstraints: ReeveModelConstraints? {
        guard let pid = effectiveProviderID, let mid = effectiveModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .constraints
    }
}

// MARK: - Per-plugin edit draft

/// Holds in-flight config for the active per-plugin edit push. Carried
/// in `@State` on the parent so the editor's binding can write through
/// it and the parent can persist on save.
struct PluginEditDraft: Identifiable, Hashable {
    let id: UUID
    var pluginName: String
    var config: [String: Any]
    /// True when this is an "Add new plugin override" flow (no row in
    /// the merged pipeline yet). Used to label the toolbar Save button.
    var isNew: Bool

    init(pluginName: String, config: [String: Any], isNew: Bool, id: UUID = UUID()) {
        self.id = id
        self.pluginName = pluginName
        self.config = config
        self.isNew = isNew
    }

    static func == (lhs: PluginEditDraft, rhs: PluginEditDraft) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Per-plugin edit screen
//
// Wraps the shared `PluginConfigSubScreen` with a toolbar Save button.
// The screen owns no draft state itself — it edits the parent's
// `pluginEdit` via the binding it receives. Save calls back to the
// parent so the conversation-level RPC can fire.

private struct PluginEditScreen: View {
    /// Seed value — captured into local @State on first render so the
    /// edit form survives transient binding flicker when the parent
    /// nils the navigation item after Save.
    let initial: PluginEditDraft
    let pluginType: ReevePluginType?
    let availableModels: [ReeveUserModel]
    let providerLabels: [String: String]
    let providerTypes: [String: String]
    let providerPresetIDs: [String: String]
    let onSave: (PluginEditDraft) -> Void
    let onCancel: () -> Void

    @State private var draft: PluginEditDraft

    init(
        initial: PluginEditDraft,
        pluginType: ReevePluginType?,
        availableModels: [ReeveUserModel],
        providerLabels: [String: String],
        providerTypes: [String: String],
        providerPresetIDs: [String: String],
        onSave: @escaping (PluginEditDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.pluginType = pluginType
        self.availableModels = availableModels
        self.providerLabels = providerLabels
        self.providerTypes = providerTypes
        self.providerPresetIDs = providerPresetIDs
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initial)
    }

    var body: some View {
        PluginConfigSubScreen(
            pluginName: draft.pluginName,
            pluginType: pluginType,
            config: $draft.config,
            availableModels: availableModels,
            providerLabels: providerLabels,
            providerTypes: providerTypes,
            providerPresetIDs: providerPresetIDs
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(draft.isNew ? "Add" : "Save") {
                    onSave(draft)
                }
                .bold()
            }
        }
    }
}
