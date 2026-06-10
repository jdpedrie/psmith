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
        // Always re-fetch on appear (and on pull-to-refresh) so an
        // edit made elsewhere — another client, the Reeve Manager via
        // MCP, a direct DB tweak — shows up the next time the user
        // opens this list, instead of being locked into whatever
        // snapshot landed in `profiles.profiles` on first launch.
        .task { await profiles.load() }
        .refreshable { await profiles.load() }
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
                    if let welcome = p.welcomeMessage, !welcome.isEmpty {
                        Section("Welcome message") {
                            Text(welcome)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                    if let cs = p.defaultSettings?.callSettings, !cs.isEmpty {
                        Section("Call settings") {
                            row("Overrides", callSettingsSummary(cs))
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

    /// One-line readout of which call-settings fields the profile
    /// overrides — enough for the read-only viewer; the editor's
    /// Call settings screen shows full values.
    private func callSettingsSummary(_ cs: ReeveCallSettings) -> String {
        var parts: [String] = []
        if let t = cs.temperature      { parts.append("temp \(String(format: "%.2f", t))") }
        if let p = cs.topP             { parts.append("top-p \(String(format: "%.2f", p))") }
        if let m = cs.maxOutputTokens  { parts.append("max \(m)") }
        if let k = cs.topK             { parts.append("top-k \(k)") }
        if !cs.stopSequences.isEmpty   { parts.append("\(cs.stopSequences.count) stop seq") }
        if cs.thinking?.isEmpty == false  { parts.append("thinking") }
        if cs.explicitCache != nil     { parts.append("caching") }
        if cs.anthropic?.isEmpty == false { parts.append("anthropic") }
        if cs.openai?.isEmpty == false    { parts.append("openai") }
        if cs.google?.isEmpty == false    { parts.append("google") }
        return parts.isEmpty ? "Customised" : parts.joined(separator: " · ")
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
    @State private var welcomeMessage: String = ""
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
    /// Drives the inner NavigationStack so we can push a fresh
    /// plugin's config sub-screen the moment the user picks one
    /// from AddPluginSheet — no second tap on the row required.
    @State private var navPath: [ProfileSubScreen] = []
    /// Show the "Discard changes?" confirmation when the user tries
    /// to back out of the editor with unsaved work.
    @State private var showingDiscardConfirm: Bool = false
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
        NavigationStack(path: $navPath) {
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
                            inheritedSettings: inheritedCallSettings,
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
                    LongTextEditorRow(label: "System message",
                                      preview: systemMessage,
                                      placeholder: "Optional — sent at the top of every conversation",
                                      destination: .longTextEditor(field: .systemMessage))
                    LongTextEditorRow(label: "Default user message",
                                      preview: defaultUserMessage,
                                      placeholder: "Optional — pre-fills the first user turn",
                                      destination: .longTextEditor(field: .defaultUserMessage))
                    LongTextEditorRow(label: "Welcome message",
                                      preview: welcomeMessage,
                                      placeholder: "Optional — first assistant bubble in new conversations",
                                      destination: .longTextEditor(field: .welcomeMessage))
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

                    LongTextEditorRow(label: "Guide",
                                      preview: compressionGuide,
                                      placeholder: "Optional extra instruction for the summariser",
                                      destination: .longTextEditor(field: .compressionGuide))
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

                    LongTextEditorRow(label: "Guide",
                                      preview: titleGuide,
                                      placeholder: "Optional — e.g. \"prefer technical phrasing\"",
                                      destination: .longTextEditor(field: .titleGuide))
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
                    Button("Cancel") { attemptDismiss() }
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
            // Block swipe-down dismissal when there's unsaved
            // work — the user has to go through the Cancel button
            // (which routes through the confirmation alert) so a
            // careless swipe doesn't silently drop a half-
            // configured plugin or an in-progress system message.
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog(
                "Discard changes?",
                isPresented: $showingDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your edits to this profile will be lost.")
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
            .navigationDestination(for: ProfileSubScreen.self) { dest in
                switch dest {
                case let .pluginConfig(localID, pluginName):
                    PluginConfigSubScreen(
                        pluginName: pluginName,
                        pluginType: app.profiles.pluginTypes.first(where: { $0.name == pluginName }),
                        config: bindingForPluginConfig(localID: localID),
                        availableModels: app.profiles.availableModels,
                        providerLabels: app.profiles.providerLabels,
                        providerTypes: app.profiles.providerTypes,
                        providerPresetIDs: app.profiles.providerPresetIDs
                    )
                case let .longTextEditor(field):
                    LongTextEditorScreen(
                        title: field.title,
                        placeholder: field.placeholder,
                        text: longTextBinding(for: field)
                    )
                }
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
                NavigationLink(value: ProfileSubScreen.pluginConfig(
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
        let draft = DraftPlugin(pluginName: pluginType.name, config: initial)
        pluginsDraft.append(draft)
        // Immediately drill into the new plugin's config screen
        // when it has any per-profile fields. Saves the user a
        // second tap on the row chevron and makes "fill in the
        // required model" the default next action — fewer ways to
        // end up with a saved-but-unconfigured plugin.
        if !pluginType.profileScopedConfigFields.isEmpty {
            navPath.append(.pluginConfig(
                localID: draft.localID,
                pluginName: pluginType.name
            ))
        }
    }

    /// Binding glue for the long-text editor sub-screen. Routes
    /// reads + writes back to the right @State String so dirty-
    /// check + save see the edits live.
    private func longTextBinding(for field: ProfileLongTextField) -> Binding<String> {
        switch field {
        case .systemMessage:
            return Binding(get: { systemMessage },      set: { systemMessage = $0 })
        case .defaultUserMessage:
            return Binding(get: { defaultUserMessage }, set: { defaultUserMessage = $0 })
        case .welcomeMessage:
            return Binding(get: { welcomeMessage },     set: { welcomeMessage = $0 })
        case .compressionGuide:
            return Binding(get: { compressionGuide },   set: { compressionGuide = $0 })
        case .titleGuide:
            return Binding(get: { titleGuide },         set: { titleGuide = $0 })
        }
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
        // Idempotent — once we've populated pluginsDraft from the
        // server, never overwrite it again. Without this guard a
        // late-arriving load (race on .task firing while the user
        // is mid-edit, or a re-task on view re-mount) wipes
        // freshly-added drafts and the plugin "vanishes" from the
        // list after a navigation pop.
        guard !pluginsLoaded else { return }
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

    /// Composite "user has unsaved edits" check — drives the
    /// dismiss-confirmation flow. Errs on the side of false-
    /// positive: a typo in the description that the user
    /// then deletes still trips this on the assumption they
    /// might want to keep editing other things. The cost of
    /// over-warning (one extra tap on Discard) is much smaller
    /// than the cost of under-warning (lost plugin config).
    private var isDirty: Bool {
        // Plugin add / remove / edit is the most expensive thing
        // to lose, so we always check it.
        if pluginsAreDirty { return true }
        // For new profiles, anything typed at all is dirt.
        guard let p = existing else {
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                || !description.isEmpty
                || !systemMessage.isEmpty
                || !defaultUserMessage.isEmpty
                || !welcomeMessage.isEmpty
                || !callSettingsDraft.isEmpty
                || defaultProviderID != nil
                || defaultModelID != nil
                || parentProfileID != nil
                || compressionProviderID != nil
                || compressionModelID != nil
                || titleProviderID != nil
                || titleModelID != nil
                || favorite
                || parentOnly
        }
        // For existing profiles, compare every field that this
        // form lets the user edit.
        return name != p.name
            || description != p.description
            || favorite != p.favorite
            || parentOnly != p.parentOnly
            || parentProfileID != p.parentProfileID
            || systemMessage != (p.systemMessage ?? "")
            || defaultUserMessage != (p.defaultUserMessage ?? "")
            || welcomeMessage != (p.welcomeMessage ?? "")
            || callSettingsDraft != (p.defaultSettings?.callSettings ?? ReeveCallSettings())
            || defaultProviderID != p.defaultSettings?.defaultProviderID
            || defaultModelID != p.defaultSettings?.defaultModelID
            || compressionMode != p.compressionMode
            || compressionProviderID != p.compressionProviderID
            || compressionModelID != p.compressionModelID
            || compressionGuide != (p.compressionGuide ?? "")
            || titleProviderKind != p.titleProviderKind
            || titleProviderID != p.titleProviderID
            || titleModelID != p.titleModelID
            || titleGuide != (p.titleGuide ?? "")
    }

    /// Dismiss the editor — go through the discard-confirm flow
    /// when there's unsaved work, dismiss directly otherwise.
    private func attemptDismiss() {
        if isDirty {
            showingDiscardConfirm = true
        } else {
            dismiss()
        }
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

    /// Resolved-from-below snapshot for the call-settings inherit
    /// previews: parent-profile chain (nearest ancestor wins) layered
    /// over the effective default model's defaults over its provider's
    /// defaults — the same order the server resolves below this
    /// profile at send time. nil when nothing below contributes.
    private var inheritedCallSettings: ReeveCallSettings? {
        var resolved = ReeveCallSettings()
        var ancestorID = parentProfileID
        var hops = 0
        while let id = ancestorID, hops < 10,
              let ancestor = app.profiles.profiles.first(where: { $0.id == id }) {
            if let cs = ancestor.defaultSettings?.callSettings {
                resolved = CallSettingsMerge.merge(higher: resolved, lower: cs)
            }
            ancestorID = ancestor.parentProfileID
            hops += 1
        }
        if let pid = effectiveInheritProviderID, let mid = effectiveInheritModelID {
            if let model = app.profiles.availableModels.first(where: { $0.providerID == pid && $0.modelID == mid }),
               let modelDefaults = model.defaultSettings {
                resolved = CallSettingsMerge.merge(higher: resolved, lower: modelDefaults)
            }
            if let providerDefaults = app.profiles.providerDefaultSettings[pid] {
                resolved = CallSettingsMerge.merge(higher: resolved, lower: providerDefaults)
            }
        }
        return resolved.isEmpty ? nil : resolved
    }

    /// The (provider, model) whose defaults sit under this profile:
    /// the form's picked default model, else the nearest ancestor's.
    private var effectiveInheritProviderID: String? {
        if let pid = defaultProviderID { return pid }
        var ancestorID = parentProfileID
        var hops = 0
        while let id = ancestorID, hops < 10,
              let ancestor = app.profiles.profiles.first(where: { $0.id == id }) {
            if let pid = ancestor.defaultSettings?.defaultProviderID { return pid }
            ancestorID = ancestor.parentProfileID
            hops += 1
        }
        return nil
    }

    private var effectiveInheritModelID: String? {
        if let mid = defaultModelID { return mid }
        var ancestorID = parentProfileID
        var hops = 0
        while let id = ancestorID, hops < 10,
              let ancestor = app.profiles.profiles.first(where: { $0.id == id }) {
            if let mid = ancestor.defaultSettings?.defaultModelID { return mid }
            ancestorID = ancestor.parentProfileID
            hops += 1
        }
        return nil
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
            welcomeMessage = p.welcomeMessage ?? ""
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
        let trimmedWelcome = welcomeMessage.trimmingCharacters(in: .whitespacesAndNewlines)
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
            favorite: favorite,
            welcomeMessage: trimmedWelcome.isEmpty ? nil : trimmedWelcome
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
        if trimmedWelcome.isEmpty          { clearFields.append("welcome_message") }

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

/// All the routes the profile editor's inner NavigationStack can
/// push to. Listed as cases on one enum so a single `navigationDestination(for:)`
/// handler can dispatch (NavigationStack accepts one route type per
/// destination handler).
private enum ProfileSubScreen: Hashable {
    /// Per-plugin config sub-screen. Identifying by `localID` (not
    /// pluginName) so two attachments of the same plugin would
    /// still navigate independently — defensive; the add-flow
    /// filters out already-attached types so this can't happen today.
    case pluginConfig(localID: UUID, pluginName: String)
    /// Long-text field editor (system message, default user
    /// message, compression guide, title guide). Renders a
    /// full-screen TextEditor so multi-paragraph prompts have
    /// real room to breathe instead of a 70–120pt inline box.
    case longTextEditor(field: ProfileLongTextField)
}

/// Identifies which long-text field a `longTextEditor` push is
/// editing. The editor reads + writes through a binding the
/// destination handler builds at push time.
private enum ProfileLongTextField: String, Hashable {
    case systemMessage
    case defaultUserMessage
    case welcomeMessage
    case compressionGuide
    case titleGuide

    var title: String {
        switch self {
        case .systemMessage:      return "System Message"
        case .defaultUserMessage: return "Default User Message"
        case .welcomeMessage:     return "Welcome Message"
        case .compressionGuide:   return "Compression Guide"
        case .titleGuide:         return "Title Guide"
        }
    }

    var placeholder: String {
        switch self {
        case .systemMessage:      return "Optional — sent at the top of every conversation"
        case .defaultUserMessage: return "Optional — pre-fills the first user turn"
        case .welcomeMessage:     return "Optional — shown as the first assistant bubble in new conversations"
        case .compressionGuide:   return "Optional extra instruction for the summariser"
        case .titleGuide:         return "Optional — e.g. \"prefer technical phrasing\""
        }
    }
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

// MARK: - Long-text-editor row + screen

/// Compact row for a long-text field. Shows the label + a single-
/// line preview (or placeholder when empty) and a chevron pushing
/// to the dedicated editor screen. Replaces the inline
/// MultilineEditor for system message / default user message /
/// compression guide / title guide — those got tall enough to
/// dominate the form on long values.
private struct LongTextEditorRow: View {
    let label: String
    let preview: String
    let placeholder: String
    let destination: ProfileSubScreen

    var body: some View {
        NavigationLink(value: destination) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer(minLength: 12)
                Text(preview.isEmpty ? placeholder : preview.replacingOccurrences(of: "\n", with: " "))
                    .font(.callout)
                    .foregroundStyle(preview.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Full-screen TextEditor for one of the long-text profile
/// fields. The bound String is the editor's source of truth; the
/// editor screen has no Save / Cancel of its own — pop-back
/// commits the edit (writes already flowed through the binding).
/// This matches the iOS pattern for "edit a single field" pushes
/// (e.g. Settings.app's Wi-Fi name editor).
private struct LongTextEditorScreen: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
