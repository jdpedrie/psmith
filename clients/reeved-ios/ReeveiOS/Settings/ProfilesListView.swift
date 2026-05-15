import SwiftUI
import ReeveKit
import ReeveUI

/// iOS Profiles list. Push from SettingsRoot. Per
/// `docs/ios-screens.md` §2.16: list with parent-chain captions, tap
/// to push viewer; "+" toolbar opens a creation sheet.
///
/// Phase 7c ships the moderate scope: list + viewer + edit-name/
/// description/parent/default-model/favorite. Compression model,
/// title model, plugins, and full chat-settings remain Mac-only —
/// those land in a follow-up sub-phase.
struct ProfilesListView: View {
    @Environment(AppModel.self) private var app
    @State private var deleteCandidate: ReeveProfile?
    @State private var creating = false

    var body: some View {
        @Bindable var profiles = app.profiles
        Group {
            if profiles.profiles.isEmpty && !creating {
                EmptyStateView(
                    "No profiles yet",
                    systemImage: "person.crop.rectangle",
                    description: "Tap + to create your first profile."
                )
            } else {
                List {
                    ForEach(sortedProfiles) { p in
                        NavigationLink {
                            ProfileViewerScreen(profileID: p.id)
                        } label: {
                            row(p)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteCandidate = p
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                Task { await profiles.toggleFavorite(p.id) }
                            } label: {
                                Label(p.favorite ? "Unfavorite" : "Favorite",
                                      systemImage: p.favorite ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New profile")
            }
        }
        .task {
            if profiles.profiles.isEmpty {
                await profiles.load()
            }
        }
        .sheet(isPresented: $creating) {
            ProfileEditSheet(existingProfileID: nil)
        }
        .alert(
            "Delete profile?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            presenting: deleteCandidate
        ) { p in
            if app.profiles.hasChildren(p.id) {
                Button("OK") { deleteCandidate = nil }
            } else {
                Button("Delete", role: .destructive) {
                    Haptics.notify(.warning)
                    profiles.selectedID = p.id
                    Task { await profiles.deleteSelected() }
                    deleteCandidate = nil
                }
                Button("Cancel", role: .cancel) { deleteCandidate = nil }
            }
        } message: { p in
            if app.profiles.hasChildren(p.id) {
                Text("This profile is the parent of other profiles. Reassign or delete those first.")
            } else {
                Text("This will permanently delete \"\(p.name)\". Conversations using this profile won't be able to send.")
            }
        }
    }

    private var sortedProfiles: [ReeveProfile] {
        app.profiles.profiles.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func row(_ profile: ReeveProfile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                    if profile.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if profile.parentOnly {
                        Text("PARENT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                }
                let chain = app.profiles.parentChainName(for: profile)
                if !chain.isEmpty, chain != profile.name {
                    Text(chain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !profile.description.isEmpty {
                    Text(profile.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Viewer (read-only)

private struct ProfileViewerScreen: View {
    let profileID: String
    @Environment(AppModel.self) private var app
    @State private var editing = false

    private var profile: ReeveProfile? {
        app.profiles.profiles.first(where: { $0.id == profileID })
    }

    var body: some View {
        Group {
            if let p = profile {
                Form {
                    Section("Identity") {
                        row("Name", p.name)
                        if !p.description.isEmpty {
                            row("Description", p.description, multiline: true)
                        }
                        row("Favorite", p.favorite ? "Yes" : "No")
                        row("Parent only", p.parentOnly ? "Yes" : "No")
                    }

                    if let pid = p.parentProfileID,
                       let parent = app.profiles.profiles.first(where: { $0.id == pid }) {
                        Section("Inherits from") {
                            row("Parent", parent.name)
                        }
                    }

                    if let dp = p.defaultSettings?.defaultProviderID,
                       let dm = p.defaultSettings?.defaultModelID {
                        Section("Default model") {
                            row("Model", modelLabel(provider: dp, model: dm) ?? dm)
                        }
                    }

                    if let cp = p.compressionProviderID,
                       let cm = p.compressionModelID {
                        Section("Compression") {
                            row("Model", modelLabel(provider: cp, model: cm) ?? cm)
                            if let mode = p.compressionMode {
                                row("Mode", mode == .replace ? "Replace" : "Append")
                            }
                            if let guide = p.compressionGuide, !guide.isEmpty {
                                row("Guide", guide, multiline: true)
                            }
                        }
                    }

                    if p.titleProviderKind == ReeveTitleProviderKind.appleFoundation {
                        Section("Auto-titling") {
                            row("Generator", "Apple Foundation (on-device)")
                            if let guide = p.titleGuide, !guide.isEmpty {
                                row("Guide", guide, multiline: true)
                            }
                        }
                    } else if let tp = p.titleProviderID,
                              let tm = p.titleModelID {
                        Section("Auto-titling") {
                            row("Model", modelLabel(provider: tp, model: tm) ?? tm)
                            if let guide = p.titleGuide, !guide.isEmpty {
                                row("Guide", guide, multiline: true)
                            }
                        }
                    }

                    if let sys = p.systemMessage, !sys.isEmpty {
                        Section("System message") {
                            Text(sys)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                    if let dum = p.defaultUserMessage, !dum.isEmpty {
                        Section("Default user message") {
                            Text(dum)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle(p.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") {
                            editing = true
                        }
                    }
                }
                .task {
                    // Pull provider labels + model display names so the
                    // Default / Compression / Title rows can render
                    // human-readable values instead of raw UUIDs +
                    // model ids on cold-open.
                    await app.profiles.loadAvailableModels()
                }
                .sheet(isPresented: $editing) {
                    ProfileEditSheet(existingProfileID: p.id)
                }
            } else {
                EmptyStateView(
                    "Profile missing",
                    systemImage: "exclamationmark.triangle",
                    description: "This profile may have been deleted from another device. Pull back to refresh the list."
                )
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, multiline: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(multiline ? nil : 1)
                .textSelection(.enabled)
        }
    }

    /// "<Provider Label> <Model Display Name>" with graceful fallbacks.
    /// Returns nil when neither id is set; raw provider id + model id
    /// when the lookup tables are empty (cold-open, network error).
    /// Mirrors the editor's `modelDisplay` so the viewer and editor
    /// agree on what a chosen model looks like.
    private func modelLabel(provider: String?, model: String?) -> String? {
        guard let pid = provider, let mid = model else { return nil }
        let providerLabel = app.profiles.providerLabels[pid] ?? pid
        let modelDisplay = app.profiles.availableModels
            .first(where: { $0.modelID == mid && $0.providerID == pid })?
            .displayName ?? mid
        return "\(providerLabel) · \(modelDisplay)"
    }
}

// MARK: - Edit / Create sheet

private struct ProfileEditSheet: View {
    /// nil → create new; non-nil → edit existing.
    let existingProfileID: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var favorite: Bool = false
    @State private var parentOnly: Bool = false
    @State private var parentProfileID: String?
    @State private var defaultProviderID: String?
    @State private var defaultModelID: String?
    // Prompt
    @State private var systemMessage: String = ""
    @State private var defaultUserMessage: String = ""
    // Compression
    @State private var compressionMode: ReeveCompressionMode? = nil
    @State private var compressionProviderID: String?
    @State private var compressionModelID: String?
    @State private var compressionGuide: String = ""
    // Auto-titling
    /// `nil` = inherit / use cloud title model. `"apple_foundation"` = on-device.
    @State private var titleProviderKind: String? = nil
    @State private var titleProviderID: String?
    @State private var titleModelID: String?
    @State private var titleGuide: String = ""
    // Default call settings — pushed to a child screen because
    // CallSettingsForm is multi-section and doesn't nest cleanly into
    // a Form.Section.
    @State private var callSettingsDraft: ReeveCallSettings = ReeveCallSettings()
    // Plugins — profile-scoped attachments. `pluginsDraft` is the
    // editable list; `pluginsBaseline` holds the loaded snapshot so
    // we know whether to call savePlugins(...) on save (avoids a
    // round-trip when nothing changed).
    @State private var pluginsDraft: [DraftPlugin] = []
    @State private var pluginsBaseline: [ReeveProfilePlugin] = []
    @State private var pluginsLoaded: Bool = false
    @State private var addingPlugin: Bool = false
    // Picker presentation flags
    @State private var pickingParent: Bool = false
    @State private var pickingDefaultModel: Bool = false
    @State private var pickingCompressionModel: Bool = false
    @State private var pickingTitleModel: Bool = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var seeded = false

    private var existing: ReeveProfile? {
        guard let id = existingProfileID else { return nil }
        return app.profiles.profiles.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                    Toggle("Favorite", isOn: $favorite)
                    Toggle("Parent only (template)", isOn: $parentOnly)
                }

                Section("Inherits from") {
                    Button {
                        pickingParent = true
                    } label: {
                        HStack {
                            Text("Parent profile")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(parentProfileName ?? "None")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Default model") {
                    modelPickerRow(
                        label: "Model",
                        valueText: defaultModelDisplay ?? "Inherit / unset",
                        action: { pickingDefaultModel = true }
                    )
                }

                Section {
                    NavigationLink {
                        ProfileCallSettingsScreen(
                            settings: $callSettingsDraft,
                            inheritedSettings: nil,
                            driverType: defaultDriverType,
                            modelCapabilities: defaultModelCapabilities
                        )
                    } label: {
                        HStack {
                            Text("Call settings")
                            Spacer()
                            Text(callSettingsDraft.isEmpty ? "Defaults" : "Customised")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Default call settings")
                } footer: {
                    Text("Per-profile generation knobs (temperature, max tokens, thinking, …). Any unset field inherits at send time.")
                }

                Section("Prompt") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System message")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MultilineEditor(
                            placeholder: "Optional — sent at the top of every conversation",
                            text: $systemMessage,
                            minHeight: 120
                        )
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default user message")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MultilineEditor(
                            placeholder: "Optional — pre-fills the first user turn",
                            text: $defaultUserMessage,
                            minHeight: 100
                        )
                    }
                }

                Section("Compression") {
                    Picker("Mode", selection: $compressionMode) {
                        Text("Inherit").tag(ReeveCompressionMode?.none)
                        Text("Replace").tag(ReeveCompressionMode?.some(.replace))
                        Text("Append").tag(ReeveCompressionMode?.some(.append))
                    }
                    .pickerStyle(.menu)

                    modelPickerRow(
                        label: "Model",
                        valueText: modelDisplay(provider: compressionProviderID, model: compressionModelID)
                            ?? "Inherit / unset",
                        action: { pickingCompressionModel = true }
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Guide")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MultilineEditor(
                            placeholder: "Optional extra instruction for the summariser",
                            text: $compressionGuide,
                            minHeight: 80
                        )
                    }
                }

                Section("Auto-titling") {
                    Picker("Generator", selection: $titleProviderKind) {
                        Text("Cloud / Inherit").tag(String?.none)
                        // Disabled tag entries don't really exist in
                        // SwiftUI Pickers — render the row but suffix
                        // the unavailability message so the user
                        // understands the option exists but can't
                        // be selected here.
                        if AppleFoundation.isAvailable {
                            Text("Apple Foundation (on-device)").tag(String?.some(ReeveTitleProviderKind.appleFoundation))
                        } else {
                            Text("Apple Foundation — not available on this device")
                                .foregroundStyle(.tertiary)
                                .tag(String?.some(ReeveTitleProviderKind.appleFoundation))
                        }
                    }
                    .pickerStyle(.menu)
                    if !AppleFoundation.isAvailable, let msg = AppleFoundation.unavailabilityMessage {
                        Text("Apple Foundation Models: \(msg)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if titleProviderKind != ReeveTitleProviderKind.appleFoundation {
                        modelPickerRow(
                            label: "Cloud model",
                            valueText: modelDisplay(provider: titleProviderID, model: titleModelID)
                                ?? "Inherit / unset",
                            action: { pickingTitleModel = true }
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Guide")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MultilineEditor(
                            placeholder: "Optional — e.g. \"prefer technical phrasing\"",
                            text: $titleGuide,
                            minHeight: 70
                        )
                    }
                }

                Section {
                    if !pluginsLoaded {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading plugins…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(Array(pluginsDraft.enumerated()), id: \.element.localID) { idx, plugin in
                            pluginRow(at: idx, plugin: plugin)
                        }
                        Button {
                            addingPlugin = true
                        } label: {
                            Label("Add plugin", systemImage: "plus.circle")
                        }
                        .disabled(unattachedPluginTypes.isEmpty)
                    }
                } header: {
                    Text("Plugins")
                } footer: {
                    Text("User-scoped plugin globals (api keys, etc.) are managed in Settings → Plugins.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(existing == nil ? "Create" : "Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .sheet(isPresented: $pickingDefaultModel) {
                NavigationStack {
                    ScrollView {
                        ModelPickerList(
                            models: app.profiles.availableModels,
                            providerLabels: app.profiles.providerLabels,
                            providerTypes: app.profiles.providerTypes,
                            providerPresetIDs: app.profiles.providerPresetIDs,
                            selectedProviderID: defaultProviderID,
                            selectedModelID: defaultModelID,
                            onUnset: {
                                defaultProviderID = nil
                                defaultModelID = nil
                                pickingDefaultModel = false
                            },
                            unsetDescription: "Inherit from parent profile, if any.",
                            onSelect: { providerID, modelID in
                                defaultProviderID = providerID
                                defaultModelID = modelID
                                pickingDefaultModel = false
                            }
                        )
                        .padding(14)
                    }
                    .navigationTitle("Default Model")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { pickingDefaultModel = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $pickingCompressionModel) {
                ProfileModelPickerSheet(
                    title: "Compression Model",
                    providerID: $compressionProviderID,
                    modelID: $compressionModelID,
                    isPresented: $pickingCompressionModel
                )
            }
            .sheet(isPresented: $pickingTitleModel) {
                ProfileModelPickerSheet(
                    title: "Title Model",
                    providerID: $titleProviderID,
                    modelID: $titleModelID,
                    isPresented: $pickingTitleModel
                )
            }
            .sheet(isPresented: $pickingParent) {
                ParentPickerSheet(
                    excludingID: existing?.id,
                    selection: $parentProfileID
                )
            }
            .sheet(isPresented: $addingPlugin) {
                AddPluginSheet(
                    types: unattachedPluginTypes,
                    onPick: { pluginType in
                        attachPlugin(pluginType)
                        addingPlugin = false
                    }
                )
            }
            .navigationDestination(for: PluginConfigDestination.self) { dest in
                PluginConfigSubScreen(
                    pluginName: dest.pluginName,
                    pluginType: app.profiles.pluginTypes.first(where: { $0.name == dest.pluginName }),
                    config: bindingForPluginConfig(localID: dest.localID)
                )
            }
            .onAppear {
                seedFromExisting()
            }
            .task {
                // Ensure the model lookup tables (providerLabels +
                // availableModels) are warm so each model-picker row
                // can render a real "<Provider> · <Model>" label
                // instead of falling back to raw UUIDs. Cheap when
                // already loaded — the call is a single ListAllUserModels
                // RPC that returns from the in-process cache.
                async let plugins: () = loadPlugins()
                async let models: () = app.profiles.loadAvailableModels()
                _ = await (plugins, models)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var parentProfileName: String? {
        guard let pid = parentProfileID else { return nil }
        return app.profiles.profiles.first(where: { $0.id == pid })?.name
    }

    private var defaultModelDisplay: String? {
        modelDisplay(provider: defaultProviderID, model: defaultModelID)
    }

    // MARK: - Plugin row + helpers

    @ViewBuilder
    private func pluginRow(at index: Int, plugin: DraftPlugin) -> some View {
        let pluginType = app.profiles.pluginTypes.first(where: { $0.name == plugin.pluginName })
        let title = pluginType?.displayName ?? plugin.pluginName
        let profileScopedFields = pluginType?.profileScopedConfigFields ?? []
        let drillable = !profileScopedFields.isEmpty
        let unsatisfiedCount = profileScopedFields
            .filter { $0.isUnsatisfied(by: plugin.config[$0.name]) }
            .count

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    if unsatisfiedCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("\(unsatisfiedCount) required field(s) unset")
                    }
                }
                if let desc = pluginType?.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                pluginsDraft.remove(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove plugin")
            if drillable {
                NavigationLink(value: PluginConfigDestination(
                    localID: plugin.localID,
                    pluginName: plugin.pluginName
                )) {
                    EmptyView()
                }
                .frame(width: 0)
                .opacity(0)
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Plugin types not yet attached — feeds the AddPluginSheet's
    /// list. Sorted by display name for stable order.
    private var unattachedPluginTypes: [ReevePluginType] {
        let attached = Set(pluginsDraft.map { $0.pluginName })
        return app.profiles.pluginTypes
            .filter { !attached.contains($0.name) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func attachPlugin(_ pluginType: ReevePluginType) {
        // Seed with default values from the descriptor so booleans /
        // numbers start with their declared defaults.
        var initial: [String: Any] = [:]
        for field in pluginType.profileScopedConfigFields {
            if !field.defaultJSON.isEmpty,
               let data = field.defaultJSON.data(using: .utf8),
               let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                initial[field.name] = any
            }
        }
        pluginsDraft.append(DraftPlugin(pluginName: pluginType.name, config: initial))
    }

    /// Two-way binding into the indexed plugin's config dict — passed
    /// to `PluginConfigSubScreen` so edits flow back into
    /// `pluginsDraft` and dirty-check on save sees them.
    private func bindingForPluginConfig(localID: UUID) -> Binding<[String: Any]> {
        Binding(
            get: {
                pluginsDraft.first(where: { $0.localID == localID })?.config ?? [:]
            },
            set: { newConfig in
                if let idx = pluginsDraft.firstIndex(where: { $0.localID == localID }) {
                    pluginsDraft[idx].config = newConfig
                }
            }
        )
    }

    @MainActor
    private func loadPlugins() async {
        // Need the catalog (plugin descriptors) before the rows can
        // render fields. Load only if not already cached on the VM.
        if app.profiles.pluginTypes.isEmpty {
            await app.profiles.loadPluginTypes()
        }
        // User-scoped plugin globals — used downstream for the
        // "global setup needed" warning. We don't render that on
        // iOS yet but loading it is cheap and matches Mac behavior.
        await app.profiles.loadUserPluginSettings()

        if let id = existingProfileID {
            await app.profiles.loadPlugins(forProfileID: id)
            let stored = app.profiles.profilePlugins[id] ?? []
            pluginsBaseline = stored
            pluginsDraft = stored.map { plugin in
                let dict = (try? JSONSerialization.jsonObject(with: plugin.config, options: [])) as? [String: Any]
                return DraftPlugin(pluginName: plugin.pluginName, config: dict ?? [:])
            }
        }
        pluginsLoaded = true
    }

    private var pluginsAreDirty: Bool {
        if pluginsBaseline.count != pluginsDraft.count { return true }
        for (b, d) in zip(pluginsBaseline, pluginsDraft) {
            if b.pluginName != d.pluginName { return true }
            let bDict = (try? JSONSerialization.jsonObject(with: b.config, options: [])) as? [String: Any] ?? [:]
            if !configsEqual(bDict, d.config) { return true }
        }
        return false
    }


    private func modelDisplay(provider: String?, model: String?) -> String? {
        guard let pid = provider, let mid = model else { return nil }
        let providerLabel = app.profiles.providerLabels[pid] ?? pid
        let modelDisplay = app.profiles.availableModels
            .first(where: { $0.modelID == mid && $0.providerID == pid })?
            .displayName ?? mid
        return "\(providerLabel) · \(modelDisplay)"
    }

    /// Settings-Form-shaped row for the three model pickers (default,
    /// compression, title). Single line, label on the left, value on
    /// the right with `.lineLimit(1)` + `.truncationMode(.middle)` so
    /// long display names don't blow out the cell or wrap weirdly.
    /// The whole row is tappable; opens the supplied picker sheet
    /// via the `action` callback.
    @ViewBuilder
    private func modelPickerRow(
        label: String,
        valueText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(valueText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Driver type for the default model — drives which extras section
    /// CallSettingsForm renders. Falls back to "anthropic" when no
    /// model is picked yet (safe choice; that branch shows only the
    /// universal Common section).
    private var defaultDriverType: String {
        if let pid = defaultProviderID,
           let type = app.profiles.providerTypes[pid] {
            return type
        }
        return "anthropic"
    }

    private var defaultModelCapabilities: ReeveModelCapabilities? {
        guard let pid = defaultProviderID, let mid = defaultModelID else { return nil }
        return app.profiles.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .capabilities
    }

    private func seedFromExisting() {
        guard !seeded else { return }
        if let p = existing {
            name = p.name
            description = p.description
            favorite = p.favorite
            parentOnly = p.parentOnly
            parentProfileID = p.parentProfileID
            defaultProviderID = p.defaultSettings?.defaultProviderID
            defaultModelID = p.defaultSettings?.defaultModelID
            systemMessage = p.systemMessage ?? ""
            defaultUserMessage = p.defaultUserMessage ?? ""
            compressionMode = p.compressionMode
            compressionProviderID = p.compressionProviderID
            compressionModelID = p.compressionModelID
            compressionGuide = p.compressionGuide ?? ""
            titleProviderKind = p.titleProviderKind
            titleProviderID = p.titleProviderID
            titleModelID = p.titleModelID
            titleGuide = p.titleGuide ?? ""
            callSettingsDraft = p.defaultSettings?.callSettings ?? ReeveCallSettings()
        }
        seeded = true
    }

    @MainActor
    private func save() async {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }

        // ProfileDefaults rolls up the per-profile generation knobs:
        // chosen default model + the CallSettingsForm draft. Sparse
        // inside ProfileDefaults — unset fields fall through to the
        // model + provider layers at send time.
        let trimmedSystem = systemMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDefaultUser = defaultUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCompressionGuide = compressionGuide.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitleGuide = titleGuide.trimmingCharacters(in: .whitespacesAndNewlines)

        let defaults = ReeveProfileDefaults(
            defaultProviderID: defaultProviderID,
            defaultModelID: defaultModelID,
            callSettings: callSettingsDraft.isEmpty ? nil : callSettingsDraft
        )

        let patch = ReeveProfilePatch(
            name: name.trimmingCharacters(in: .whitespaces),
            parentProfileID: parentProfileID,
            systemMessage: trimmedSystem.isEmpty ? nil : trimmedSystem,
            defaultUserMessage: trimmedDefaultUser.isEmpty ? nil : trimmedDefaultUser,
            compressionGuide: trimmedCompressionGuide.isEmpty ? nil : trimmedCompressionGuide,
            compressionMode: compressionMode,
            compressionProviderID: compressionProviderID,
            compressionModelID: compressionModelID,
            defaultSettings: defaults,
            titleProviderID: titleProviderID,
            titleModelID: titleModelID,
            titleGuide: trimmedTitleGuide.isEmpty ? nil : trimmedTitleGuide,
            titleProviderKind: titleProviderKind,
            description: description.trimmingCharacters(in: .whitespaces),
            parentOnly: parentOnly,
            favorite: favorite
        )

        // Build the explicit-clear list. Server-side, the proto patch
        // shape uses empty-string-as-clear for some fields and
        // explicit clear-list entries for others; ProfilePatch.clearFields
        // covers both. Field names match proto field names.
        var clearFields: [String] = []
        if parentProfileID == nil          { clearFields.append("parent_profile_id") }
        if trimmedSystem.isEmpty           { clearFields.append("system_message") }
        if trimmedDefaultUser.isEmpty      { clearFields.append("default_user_message") }
        if trimmedCompressionGuide.isEmpty { clearFields.append("compression_guide") }
        if compressionMode == nil          { clearFields.append("compression_mode") }
        if compressionProviderID == nil    { clearFields.append("compression_provider_id") }
        if compressionModelID == nil       { clearFields.append("compression_model_id") }
        if titleProviderID == nil          { clearFields.append("title_provider_id") }
        if titleModelID == nil             { clearFields.append("title_model_id") }
        if trimmedTitleGuide.isEmpty       { clearFields.append("title_guide") }
        if titleProviderKind == nil        { clearFields.append("title_provider_kind") }

        do {
            // Step 1 — create / update the profile so we have an id
            // to attach plugins to.
            let profileID: String
            if let existing = existing {
                _ = try await app.profiles.update(
                    id: existing.id,
                    patch: patch,
                    clearFields: clearFields
                )
                profileID = existing.id
            } else {
                let created = try await app.profiles.create(patch)
                profileID = created.id
            }

            // Step 2 — flush plugins when dirty. Add-mode baseline is
            // empty so any drafts attach to the freshly-created
            // profile; edit-mode skips the round-trip when nothing
            // changed.
            if pluginsAreDirty {
                let plugins: [ReeveProfilePlugin] = try pluginsDraft.enumerated().map { ordinal, plugin in
                    let data = try JSONSerialization.data(withJSONObject: plugin.config, options: [.sortedKeys])
                    return ReeveProfilePlugin(
                        pluginName: plugin.pluginName,
                        ordinal: Int32(ordinal),
                        config: data
                    )
                }
                try await app.profiles.savePlugins(forProfileID: profileID, plugins: plugins)
            }

            await app.profiles.load()
            dismiss()
        } catch {
            errorMessage = ReeveError.display(error)
        }
    }
}

// MARK: - Plugin support types

/// Editable representation of a profile-attached plugin instance.
/// Untyped JSON config dict because each plugin's schema differs at
/// runtime; PluginConfigForm renders the right controls per field.
private struct DraftPlugin {
    let localID = UUID()
    var pluginName: String
    var config: [String: Any]
}

/// NavigationDestination value for the per-plugin config sub-screen.
/// Identifying by `localID` (not pluginName) so two attachments of the
/// same plugin would still navigate independently — defensive; the
/// add-flow filters out already-attached types so this can't happen
/// today.
private struct PluginConfigDestination: Hashable {
    let localID: UUID
    let pluginName: String
}

/// Shallow equality on the JSON-serializable subset PluginConfigForm
/// produces (Bool / Int / Double / String). Drives the dirty-check on
/// save.
private func configsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    guard a.count == b.count else { return false }
    for (k, v) in a {
        guard let other = b[k] else { return false }
        if !anyEqual(v, other) { return false }
    }
    return true
}

private func anyEqual(_ a: Any, _ b: Any) -> Bool {
    if let a = a as? String, let b = b as? String { return a == b }
    if let a = a as? Bool,   let b = b as? Bool   { return a == b }
    if let a = a as? Int,    let b = b as? Int    { return a == b }
    if let a = a as? Double, let b = b as? Double { return a == b }
    // Mixed numeric types — coerce to Double for the comparison.
    if let a = (a as? NSNumber)?.doubleValue,
       let b = (b as? NSNumber)?.doubleValue {
        return a == b
    }
    return false
}

// MARK: - Per-plugin config sub-screen

private struct PluginConfigSubScreen: View {
    let pluginName: String
    let pluginType: ReevePluginType?
    @Binding var config: [String: Any]
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let type = pluginType {
                    if !type.description.isEmpty {
                        Text(type.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let fields = type.profileScopedConfigFields
                    if fields.isEmpty {
                        Text("This plugin has no per-profile fields. Its global settings live in Settings → Plugins.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        PluginConfigForm(
                            fields: fields,
                            config: $config,
                            availableModels: app.profiles.availableModels,
                            providerLabels: app.profiles.providerLabels,
                            providerTypes: app.profiles.providerTypes,
                            providerPresetIDs: app.profiles.providerPresetIDs
                        )
                    }
                } else {
                    Text("Plugin descriptor not loaded — pull back to refresh, then re-enter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .navigationTitle(pluginType?.displayName ?? pluginName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Add plugin sheet

/// Sheet that lists plugin types not yet attached. Tapping a row
/// invokes `onPick` and dismisses; the parent appends a fresh
/// DraftPlugin to its list.
private struct AddPluginSheet: View {
    let types: [ReevePluginType]
    let onPick: (ReevePluginType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if types.isEmpty {
                    Text("Every available plugin is already attached.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(types) { type in
                        Button {
                            onPick(type)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(type.displayName)
                                        .foregroundStyle(.primary)
                                    if !type.description.isEmpty {
                                        Text(type.description)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Profile call-settings child screen

/// Pushed from ProfileEditSheet's "Call settings" row. Hosts the
/// shared `CallSettingsForm` with header context. Bound to the parent
/// sheet's `callSettingsDraft` so changes flow up through the binding.
private struct ProfileCallSettingsScreen: View {
    @Binding var settings: ReeveCallSettings
    let inheritedSettings: ReeveCallSettings?
    let driverType: String
    let modelCapabilities: ReeveModelCapabilities?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CallSettingsForm(
                    settings: $settings,
                    inheritedSettings: inheritedSettings,
                    driverType: driverType,
                    modelCapabilities: modelCapabilities
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .navigationTitle("Call Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Profile-scoped model picker sheet (shared shape)

/// Reusable model picker — used for the compression and title model
/// slots. Default-model picker has its own inline body in
/// ProfileEditSheet because it predates this helper; kept that way to
/// avoid churn.
private struct ProfileModelPickerSheet: View {
    let title: String
    @Binding var providerID: String?
    @Binding var modelID: String?
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                ModelPickerList(
                    models: app.profiles.availableModels,
                    providerLabels: app.profiles.providerLabels,
                    providerTypes: app.profiles.providerTypes,
                    providerPresetIDs: app.profiles.providerPresetIDs,
                    selectedProviderID: providerID,
                    selectedModelID: modelID,
                    onUnset: {
                        providerID = nil
                        modelID = nil
                        isPresented = false
                    },
                    unsetDescription: "Inherit from parent profile, if any.",
                    onSelect: { pid, mid in
                        providerID = pid
                        modelID = mid
                        isPresented = false
                    }
                )
                .padding(14)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Parent picker sheet

private struct ParentPickerSheet: View {
    let excludingID: String?
    @Binding var selection: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    HStack {
                        Text("None")
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)

                ForEach(eligibleParents) { p in
                    Button {
                        selection = p.id
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                if p.parentOnly {
                                    Text("Template")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if selection == p.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Inherits from")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var eligibleParents: [ReeveProfile] {
        app.profiles.profiles
            .filter { $0.id != excludingID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Multi-line text input that scrolls when content exceeds its
/// frame. `TextField(axis: .vertical)` grows up to its lineLimit
/// then stops — content past the cap becomes invisible inside a
/// Form. TextEditor scrolls internally, which is what we want for
/// system messages / default user messages / guide fields that
/// can run long.
///
/// Adds a placeholder overlay (TextEditor doesn't support one
/// natively) and a thin border so the field reads as a control
/// rather than free-floating text in the row.
private struct MultilineEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 100

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .frame(minHeight: minHeight)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}
