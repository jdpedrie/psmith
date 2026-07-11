import SwiftUI
import PsmithKit
import PsmithUI

/// Identifies which of the three profile-form model pickers is
/// currently expanded for inline selection. Only one is open at a
/// time; nil means all collapsed.
private enum ModelPickerSlot {
    case `default`     // The profile's main default model
    case compression   // Per-profile compression model override
    case title         // Per-profile auto-title model override
}

// MARK: - Sidebar

struct ProfilesMiddleColumn: View {
    @Bindable var model: ProfilesViewModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsListHeader(
                title: "Profiles",
                count: model.profiles.count,
                countNoun: "profile",
                onBack: onBack,
                onCreate: { model.detailMode = .adding },
                createDisabled: model.detailMode == .adding
            )

            if model.isLoading {
                ProgressView().padding()
                Spacer()
            } else if model.profiles.isEmpty {
                EmptyStateView(
                    "No profiles yet",
                    systemImage: "person.crop.rectangle",
                    description: "Tap + to add the first one."
                )
            } else {
                List(model.profiles, id: \.id, selection: Binding(
                    get: { model.detailMode == .adding ? nil : model.selectedID },
                    set: { id in if let id { model.select(id) } }
                )) { profile in
                    ProfileRow(profile: profile, profiles: model.profiles)
                        .tag(profile.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: PsmithProfile
    let profiles: [PsmithProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.name).lineLimit(1)
            if !ancestorNames.isEmpty {
                Text(ancestorNames.joined(separator: " ‹ "))
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var ancestorNames: [String] {
        var out: [String] = []
        var current = profile.parentProfileID
        var seen: Set<String> = [profile.id]
        var depth = 0
        while let pid = current, !seen.contains(pid), depth < 8 {
            seen.insert(pid)
            depth += 1
            guard let p = profiles.first(where: { $0.id == pid }) else { break }
            out.append(p.name)
            current = p.parentProfileID
        }
        return out
    }
}

// MARK: - Detail

struct ProfilesDetail: View {
    @Bindable var model: ProfilesViewModel

    var body: some View {
        Group {
            switch model.detailMode {
            case .adding:
                ProfileForm(model: model, editing: nil)
            case .viewing, .editing:
                if let profile = model.selected() {
                    if model.detailMode == .editing {
                        ProfileForm(model: model, editing: profile)
                    } else {
                        ProfileViewer(profile: profile, model: model)
                    }
                } else if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.profiles.isEmpty {
                    EmptyStateView(
                        "No profiles configured",
                        systemImage: "person.crop.rectangle",
                        description: "Add a profile from the sidebar."
                    )
                } else {
                    EmptyStateView(
                        "No profile selected",
                        systemImage: "person.crop.rectangle",
                        description: "Pick one from the sidebar."
                    )
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(model.selected()?.name ?? "profile")\"?",
            isPresented: $model.showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelected() }
            }
        } message: {
            Text("Conversations using this profile will keep working but lose its inheritance source.")
        }
        // Re-fetch on every appear so server-side edits — by another
        // client, by MCP, by direct DB tweak — show up next time the
        // user opens this pane instead of being locked into the
        // launch-time snapshot.
        .task {
            await model.load()
            await model.loadAvailableModels()
        }
    }
}

// MARK: - Read-only viewer

private struct ProfileViewer: View {
    let profile: PsmithProfile
    @Bindable var model: ProvidersViewModelHelper
    @Environment(\.theme) private var theme

    init(profile: PsmithProfile, model: ProfilesViewModel) {
        self.profile = profile
        self.model = ProvidersViewModelHelper(model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — mirrors ProviderHeader so the two settings panes share
            // a row of glass circle buttons in the same paneHeaderHeight band.
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .scaledFont(.headline)
                            .lineLimit(1)
                        if profile.parentOnly {
                            Text("PARENT ONLY")
                                .scaledFont(.caption2, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }
                    Text(parentName.map { "Inherits from \($0)" } ?? "Standalone profile")
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                GlassCircleButton(
                    systemImage: "pencil",
                    action: { model.profilesModel.detailMode = .editing },
                    help: "Edit"
                )
                GlassCircleButton(
                    systemImage: "trash",
                    action: { model.profilesModel.showDeleteConfirm = true },
                    help: hasChildren
                        ? "Has \(childCount) child profile\(childCount == 1 ? "" : "s") — delete those first"
                        : "Delete profile",
                    tint: .red,
                    disabled: model.profilesModel.isDeleting || hasChildren
                )
            }
            .padding(.horizontal, 12)
            .frame(height: paneHeaderHeight)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !profile.description.isEmpty {
                        section("Description") {
                            multilineText(profile.description)
                        }
                    }
                    if let sm = profile.systemMessage, !sm.isEmpty {
                        section("System message") {
                            multilineText(sm)
                        }
                    }
                    if let dum = profile.defaultUserMessage, !dum.isEmpty {
                        section("Default user message") {
                            multilineText(dum)
                        }
                    }
                    if let d = profile.defaultSettings,
                       (d.defaultProviderID != nil || d.defaultModelID != nil) {
                        section("Default model") {
                            modelDescription(d.defaultProviderID, d.defaultModelID)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if hasCompressionOverrides {
                        section("Compression") {
                            VStack(alignment: .leading, spacing: 4) {
                                if let mode = profile.compressionMode {
                                    HStack(spacing: 4) {
                                        Text("Mode:").foregroundStyle(.secondary).scaledFont(.caption)
                                        Text(modeLabel(mode)).scaledFont(.callout)
                                    }
                                }
                                if profile.compressionProviderID != nil || profile.compressionModelID != nil {
                                    HStack(spacing: 4) {
                                        Text("Model:").foregroundStyle(.secondary).scaledFont(.caption)
                                        modelDescription(profile.compressionProviderID, profile.compressionModelID)
                                            .scaledFont(.callout)
                                    }
                                }
                                if let g = profile.compressionGuide, !g.isEmpty {
                                    multilineText(g)
                                }
                            }
                        }
                    }

                    if hasTitleOverrides {
                        section("Auto-titling") {
                            VStack(alignment: .leading, spacing: 4) {
                                if profile.titleProviderKind == PsmithTitleProviderKind.appleFoundation {
                                    HStack(spacing: 6) {
                                        Image(systemName: "apple.logo")
                                            .foregroundStyle(theme.accent)
                                        Text("Apple Foundation Models")
                                            .scaledFont(.callout)
                                        Text("ON DEVICE")
                                            .scaledFont(.caption2, weight: .semibold)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(theme.accent.opacity(0.85))
                                            .clipShape(Capsule())
                                    }
                                } else if profile.titleProviderID != nil || profile.titleModelID != nil {
                                    HStack(spacing: 4) {
                                        Text("Model:").foregroundStyle(.secondary).scaledFont(.caption)
                                        modelDescription(profile.titleProviderID, profile.titleModelID)
                                            .scaledFont(.callout)
                                    }
                                }
                                if let g = profile.titleGuide, !g.isEmpty {
                                    multilineText(g)
                                }
                            }
                        }
                    }

                    if isFullyInherited {
                        Text("This profile inherits everything from \(parentName ?? "the default").")
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            if let err = model.profilesModel.error {
                PaneFooter {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var hasChildren: Bool { model.profilesModel.hasChildren(profile.id) }
    private var childCount: Int {
        model.profilesModel.profiles.filter { $0.parentProfileID == profile.id }.count
    }

    private var parentName: String? {
        guard let pid = profile.parentProfileID else { return nil }
        return model.profilesModel.profiles.first(where: { $0.id == pid })?.name
    }

    private var hasCompressionOverrides: Bool {
        profile.compressionMode != nil
            || profile.compressionProviderID != nil
            || profile.compressionModelID != nil
            || (profile.compressionGuide?.isEmpty == false)
    }

    private var hasTitleOverrides: Bool {
        profile.titleProviderID != nil
            || profile.titleModelID != nil
            || (profile.titleGuide?.isEmpty == false)
            || (profile.titleProviderKind?.isEmpty == false)
    }

    private var isFullyInherited: Bool {
        profile.systemMessage == nil
            && profile.defaultUserMessage == nil
            && profile.defaultSettings == nil
            && !hasCompressionOverrides
            && !hasTitleOverrides
    }

    private func modeLabel(_ m: PsmithCompressionMode) -> String {
        switch m {
        case .replace:     return "Replace"
        case .append:      return "Append"
        case .unspecified: return "Unspecified"
        }
    }

    @ViewBuilder
    private func modelDescription(_ providerID: String?, _ modelID: String?) -> some View {
        if let providerID, let modelID {
            let providerLabel = model.profilesModel.providerLabels[providerID] ?? "\(providerID.prefix(8))…"
            let displayName = model.profilesModel.availableModels
                .first(where: { $0.providerID == providerID && $0.modelID == modelID })?
                .displayName ?? modelID
            HStack(spacing: 4) {
                Text(displayName)
                Text("·").foregroundStyle(.tertiary)
                Text(providerLabel).foregroundStyle(.tertiary)
            }
        } else {
            Text("(partial)")
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            body()
        }
    }

    private func multilineText(_ s: String) -> some View {
        Text(s)
            .scaledFont(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Holds a `ProfilesViewModel` reference so SwiftUI's `@Bindable`
/// requirement-via-`@Observable` is satisfied without leaking the model
/// type all over the viewer's signatures.
@Observable
@MainActor
private final class ProvidersViewModelHelper {
    let profilesModel: ProfilesViewModel
    init(_ m: ProfilesViewModel) { self.profilesModel = m }
}

// MARK: - Form (Add / Edit)

private struct ProfileForm: View {
    @Bindable var model: ProfilesViewModel
    let editing: PsmithProfile?

    @Environment(\.theme) private var theme

    @State private var name = ""
    @State private var profileDescription = ""
    @State private var parentOnly = false
    @State private var parentID: String?
    @State private var systemMessage = ""
    @State private var welcomeMessage = ""
    @State private var defaultUserMessage = ""
    @State private var defaultProviderID: String?
    @State private var defaultModelID: String?

    /// Which model-picker row is currently expanded (showing the
    /// inline ModelPickerList). Only one open at a time; nil means
    /// all collapsed. Three sites: .default / .compression / .title.
    /// Inline expansion (not a popover or sheet) keeps the form's
    /// "no popups" rule intact.
    @State private var expandedPicker: ModelPickerSlot? = nil
    /// Editable per-profile default CallSettings. Inherits from the model
    /// layer below at SendMessage time on the server — the form renders
    /// "(inherited)" placeholders for unset fields.
    @State private var callSettingsDraft = PsmithCallSettings()

    // Compression
    @State private var compressionMode: PsmithCompressionMode? = nil
    @State private var compressionProviderID: String?
    @State private var compressionModelID: String?
    @State private var compressionGuide = ""

    // Title generation
    @State private var titleProviderID: String?
    @State private var titleModelID: String?
    @State private var titleGuide = ""
    /// Sentinel naming a non-server titler. Currently only
    /// `PsmithTitleProviderKind.appleFoundation` ("apple_foundation") is
    /// recognized — picks the on-device Apple Foundation Models path on the
    /// Mac. Mutually exclusive with the cloud title model picker below;
    /// selecting one nils the other.
    @State private var titleProviderKind: String?

    @State private var isSaving = false
    @State private var formError: String?

    // Plugins live on the profile but are persisted via a separate RPC
    // (SetProfilePlugins). We hoist their draft into ProfileForm so the
    // main Save button can flush both atomically — the user no longer
    // sees "Save plugins" as a separate affordance.
    @State private var pluginsDraft: [DraftPlugin] = []
    @State private var pluginsBaseline: [PsmithProfilePlugin] = []
    @State private var pluginsLoaded = false
    @State private var configuringPluginLocalID: UUID?
    @State private var showingAddPluginPicker = false

    private var isEdit: Bool { editing != nil }

    private var canSave: Bool {
        !isSaving
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && pluginsAreValid
    }

    /// True when every required PROFILE-SCOPED field on every attached
    /// plugin is satisfied. Globals are validated on the Plugin Settings
    /// surface — leaving a global blank only triggers a warning chip
    /// on the plugin card, not a Save block (the user might still want
    /// to save the profile and configure the global later).
    private var pluginsAreValid: Bool {
        for plugin in pluginsDraft {
            guard let pluginType = model.pluginTypes.first(where: { $0.name == plugin.pluginName }) else {
                continue // unknown type — let the server reject
            }
            for field in pluginType.profileScopedConfigFields where field.isUnsatisfied(by: plugin.config[field.name]) {
                return false
            }
        }
        return true
    }

    var body: some View {
        if let id = configuringPluginLocalID,
           let index = pluginsDraft.firstIndex(where: { $0.localID == id }) {
            pluginSettingsSubScreen(index: index)
        } else {
            mainForm
        }
    }

    private var mainForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — same paneHeaderHeight band as ProfileViewer / ProviderHeader
            // for column-to-column visual rhythm.
            HStack(alignment: .center, spacing: 8) {
                Text(isEdit ? "Edit profile" : "Add profile")
                    .scaledFont(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") {
                    model.detailMode = .viewing
                }
                .controlSize(.small)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text(isEdit ? "Save" : "Create") }
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .frame(height: paneHeaderHeight)

            Divider()

            // GeometryReader pins the inner VStack's width to the column's
            // actual width — without it, the embedded CallSettingsForm's
            // wide segmented pickers force the VStack's intrinsic size
            // above the column, so the column's left edge clips the
            // leading characters of every label. Same fix applied to
            // ModelEditForm in ProvidersView.
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        formSection("Basic") {
                        formRow(label: "Name",
                                description: "Short, memorable. Shown in the conversation list.") {
                            TextField("e.g. Default, Coding, Brainstorm", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                        formRow(label: "Description",
                                description: "Optional. A sentence about when to reach for this profile.") {
                            TextField("e.g. \"Concise, code-first answers\"", text: $profileDescription)
                                .textFieldStyle(.roundedBorder)
                        }
                        formRow(label: "Inherits from",
                                description: "Any field left blank below falls back to this parent. Templates (parent-only profiles) are eligible.") {
                            ProfilePickerRow(
                                model: model,
                                selectedID: $parentID,
                                includeNoneOption: true,
                                allowParentOnly: true,
                                excludeID: editing?.id,
                                onOpenSettings: { id in sharedNavigator.openProfileSettings(id: id) }
                            )
                        }
                        formRow(label: "Parent only",
                                description: "When on, this profile is hidden from the new-conversation picker — only usable as a parent for inheritance.") {
                            Toggle("", isOn: $parentOnly)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }

                    formSection("Prompt") {
                        formRow(label: "System message",
                                description: "Sent as the system prompt at the top of every request.") {
                            multilineEditor($systemMessage).frame(minHeight: 80)
                        }
                        formRow(label: "Default user message",
                                description: "Pre-filled into the composer when a new conversation is started.") {
                            multilineEditor($defaultUserMessage).frame(minHeight: 60)
                        }
                        formRow(label: "Welcome message",
                                description: "Shown as the assistant's first message in every new conversation — a greeting, not a prompt; it isn't sent to the model as an instruction.") {
                            multilineEditor($welcomeMessage).frame(minHeight: 60)
                        }
                    }

                    formSection("Default model") {
                        formRow(label: "Model",
                                description: "Used for normal turns when the conversation doesn't override.") {
                            modelPicker(slot: .default, provider: $defaultProviderID, model: $defaultModelID)
                        }
                    }

                    formSection("Default call settings") {
                        Text("Per-profile generation knobs (temperature, max tokens, thinking, …). Any unset field inherits from the model and provider layers below at send time.")
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        CallSettingsForm(
                            settings: $callSettingsDraft,
                            inheritedSettings: profileInheritedCallSettings,
                            driverType: profileDriverType,
                            modelCapabilities: profileModelCapabilities
                        )
                    }

                    formSection("Compression") {
                        formRow(label: "Mode",
                                description: "Replace replaces the context with a summary; Append keeps both.") {
                            Picker("", selection: $compressionMode) {
                                Text("(inherit)").tag(PsmithCompressionMode?.none)
                                Text("Replace").tag(PsmithCompressionMode?.some(.replace))
                                Text("Append").tag(PsmithCompressionMode?.some(.append))
                            }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                        }
                        formRow(label: "Model",
                                description: "Model used to write the summary.") {
                            modelPicker(slot: .compression, provider: $compressionProviderID, model: $compressionModelID)
                        }
                        formRow(label: "Guide",
                                description: "Optional extra instruction for the summariser.") {
                            multilineEditor($compressionGuide).frame(minHeight: 60)
                        }
                    }

                    pluginsSection

                    formSection("Auto-titling") {
                        formRow(label: "Generator",
                                description: "Apple Foundation Models runs locally on macOS 26+ — free, fast, private. Pick a cloud model below to use a paid LLM instead.") {
                            titleGeneratorPicker
                        }
                        if titleProviderKind != PsmithTitleProviderKind.appleFoundation {
                            formRow(label: "Cloud model",
                                    description: "Used when the local generator is unavailable or you want a specific model.") {
                                modelPicker(slot: .title, provider: $titleProviderID, model: $titleModelID)
                            }
                        }
                        formRow(label: "Guide",
                                description: "Optional extra instruction for the titler — e.g. \"prefer technical phrasing\".") {
                            multilineEditor($titleGuide).frame(minHeight: 50)
                        }
                    }

                    if let formError {
                        Text(formError).scaledFont(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
                .frame(width: geo.size.width, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { seedFromEditing() }
        .task {
            // Plugin types descriptor (display name, fields, capabilities)
            // — needed regardless of edit/add mode so the Add Plugin
            // picker has something to render.
            if model.pluginTypes.isEmpty {
                await model.loadPluginTypes()
            }
            // User-scoped global plugin settings power the per-card
            // "global setup needed" badge.
            await model.loadUserPluginSettings()
            // Existing-profile plugins seed the draft baseline. New
            // profiles start with an empty draft.
            if let editing {
                await model.loadPlugins(forProfileID: editing.id)
                let stored = model.profilePlugins[editing.id] ?? []
                pluginsBaseline = stored
                pluginsDraft = stored.map { plugin in
                    DraftPlugin(
                        pluginName: plugin.pluginName,
                        config: decodeConfigDict(plugin.config) ?? [:]
                    )
                }
            }
            pluginsLoaded = true
        }
    }


    /// Width of the left "label" column; used by every formRow so fields line up.
    private static let labelColumnWidth: CGFloat = 130

    @ViewBuilder
    private func formSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .scaledFont(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    /// One labelled row: Label column on the left, the field on the right,
    /// description hint underneath the field.
    @ViewBuilder
    private func formRow<Content: View>(
        label: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                content()
                Text(description)
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func multilineEditor(_ binding: Binding<String>) -> some View {
        TextEditor(text: binding)
            .scaledFont(.callout)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Reusable provider+model picker. Renders a chip showing the
    /// currently-selected provider's logo + model name. Tapping toggles
    /// an inline expansion below the row containing the full
    /// ModelPickerList (provider sections, per-row metadata strip).
    /// Selecting a row collapses + sets both bindings; the "(unset —
    /// inherit)" affordance at the top of the list clears them.
    /// Inline (no popover or sheet) per the project's "no popups" rule.
    @ViewBuilder
    private func modelPicker(
        slot: ModelPickerSlot,
        provider: Binding<String?>,
        model modelBinding: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedPicker = (expandedPicker == slot ? nil : slot)
            } label: {
                HStack(spacing: 6) {
                    if let slug = selectedLogoSlug(provider: provider.wrappedValue) {
                        ProviderLogo(slug: slug, size: 14)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "cpu").scaledFont(.caption2)
                    }
                    Text(modelLabel(provider: provider.wrappedValue, model: modelBinding.wrappedValue))
                    Image(systemName: expandedPicker == slot ? "chevron.up" : "chevron.down")
                        .scaledFont(.caption2)
                }
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                // contentShape forces the entire HStack frame
                // (including the chevron and any padding) to be hit-
                // testable. Without it SwiftUI's Button only registers
                // taps on opaque content — taps that landed on the
                // chevron's inter-glyph space (the most natural place
                // to click "open the dropdown") fell through and the
                // chip never toggled.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose model")

            if expandedPicker == slot {
                // Cap the inline expansion at ~360pt so a 30-model
                // list doesn't push the rest of the form off-screen.
                // Internal ScrollView handles overflow; the form's
                // outer scroll keeps working below the picker.
                ScrollView {
                    ModelPickerList(
                        models: model.availableModels,
                        providerLabels: model.providerLabels,
                        providerTypes: model.providerTypes,
                        providerPresetIDs: model.providerPresetIDs,
                        selectedProviderID: provider.wrappedValue,
                        selectedModelID: modelBinding.wrappedValue,
                        onUnset: {
                            provider.wrappedValue = nil
                            modelBinding.wrappedValue = nil
                            expandedPicker = nil
                        },
                        unsetDescription: unsetDescription(for: slot),
                        onSelect: { pid, mid in
                            provider.wrappedValue = pid
                            modelBinding.wrappedValue = mid
                            expandedPicker = nil
                        }
                    )
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Per-slot description for the picker's "Unset — inherit" row.
    /// Each profile-form slot wants different copy: the title slot
    /// mentions auto-titling, default/compression talk about parent
    /// inheritance only.
    private func unsetDescription(for slot: ModelPickerSlot) -> String {
        switch slot {
        case .default:
            return "Use parent profile's default model."
        case .compression:
            return "Use parent profile's compression model (or skip compression)."
        case .title:
            return "Use parent profile's setting (or skip auto-titling)."
        }
    }

    /// Resolve a logo slug for the chip from the picker's currently-set
    /// providerID. Mirrors ConversationView's helper — anthropic/google
    /// have static slugs, openai-compatible carry the slug in their
    /// preset id, custom configs return nil → cpu glyph fallback.
    private func selectedLogoSlug(provider providerID: String?) -> String? {
        guard let providerID else { return nil }
        switch model.providerTypes[providerID] {
        case "anthropic": return "anthropic"
        case "google":    return "google-color"
        case "openai-compatible":
            return model.providerPresetIDs[providerID]
        default:
            return nil
        }
    }

    /// Two inline glass cards — Apple Foundation Models (on-device) vs.
    /// Cloud model. Tapping a card sets `titleProviderKind` and clears the
    /// other side's selection. Inline rows are used instead of a Menu per
    /// the project's known SwiftUI macOS Menu bug — see
    /// feedback_swiftui_menu_macos_bug.md.
    @ViewBuilder
    private var titleGeneratorPicker: some View {
        let isLocal = titleProviderKind == PsmithTitleProviderKind.appleFoundation
        let isCloud = !isLocal && titleProviderID != nil && titleModelID != nil
        let isInherit = !isLocal && !isCloud

        VStack(alignment: .leading, spacing: 6) {
            titleGeneratorCard(
                title: "Apple Foundation Models",
                subtitle: AppleFoundation.isAvailable
                    ? "On-device · free · macOS 26+"
                    : (AppleFoundation.unavailabilityMessage ?? "Not available on this device"),
                systemImage: "apple.logo",
                badge: "ON DEVICE",
                isSelected: isLocal,
                tint: theme.accent,
                disabled: !AppleFoundation.isAvailable
            ) {
                titleProviderKind = PsmithTitleProviderKind.appleFoundation
                titleProviderID = nil
                titleModelID = nil
            }

            titleGeneratorCard(
                title: "Cloud model",
                subtitle: cloudSubtitle,
                systemImage: "cloud",
                badge: nil,
                isSelected: isCloud,
                tint: theme.accent
            ) {
                titleProviderKind = nil
                // Leave (provider/model) as-is so the picker below opens
                // pre-selected. The user can then change them.
            }

            titleGeneratorCard(
                title: "Inherit / disabled",
                subtitle: "Use parent profile's setting (or skip auto-titling).",
                systemImage: "arrow.up.right",
                badge: nil,
                isSelected: isInherit,
                tint: .secondary
            ) {
                titleProviderKind = nil
                titleProviderID = nil
                titleModelID = nil
            }
        }
        .frame(maxWidth: 460)
    }

    private var cloudSubtitle: String {
        if let pid = titleProviderID, let mid = titleModelID,
           let m = model.availableModels.first(where: { $0.providerID == pid && $0.modelID == mid }) {
            return m.displayName
        }
        return "Pick a model below."
    }

    @ViewBuilder
    private func titleGeneratorCard(
        title: String,
        subtitle: String,
        systemImage: String,
        badge: String?,
        isSelected: Bool,
        tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .scaledFont(.title3)
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).scaledFont(.callout, weight: .medium)
                        if let badge {
                            Text(badge)
                                .scaledFont(.caption2, weight: .semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(tint.opacity(0.85))
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? tint.opacity(0.10) : Color.primary.opacity(0.04))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(tint.opacity(0.55)) : AnyShapeStyle(Color.primary.opacity(0.06)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .opacity(disabled ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? (AppleFoundation.unavailabilityMessage ?? "Not available") : "")
    }

    private func modelLabel(provider: String?, model modelID: String?) -> String {
        guard let pid = provider, let mid = modelID else {
            return "(unset — inherit)"
        }
        if let m = model.availableModels.first(where: { $0.providerID == pid && $0.modelID == mid }) {
            return m.displayName
        }
        return mid
    }

    // MARK: Save

    private func seedFromEditing() {
        guard let p = editing else { return }
        name = p.name
        profileDescription = p.description
        parentOnly = p.parentOnly
        parentID = p.parentProfileID
        systemMessage = p.systemMessage ?? ""
        welcomeMessage = p.welcomeMessage ?? ""
        defaultUserMessage = p.defaultUserMessage ?? ""
        defaultProviderID = p.defaultSettings?.defaultProviderID
        defaultModelID    = p.defaultSettings?.defaultModelID
        callSettingsDraft = p.defaultSettings?.callSettings ?? PsmithCallSettings()

        compressionMode       = p.compressionMode
        compressionProviderID = p.compressionProviderID
        compressionModelID    = p.compressionModelID
        compressionGuide      = p.compressionGuide ?? ""

        titleProviderID   = p.titleProviderID
        titleModelID      = p.titleModelID
        titleGuide        = p.titleGuide ?? ""
        titleProviderKind = p.titleProviderKind
    }

    /// Driver type to render for the CallSettingsForm. Picks from the
    /// profile's currently-selected default model so swapping the model
    /// flips the driver-specific extension block.
    private var profileDriverType: String {
        guard let pid = defaultProviderID,
              let type = model.providerTypes[pid] else {
            return "anthropic"
        }
        return type
    }

    /// Capabilities for the profile's selected default model. Surfaces the
    /// thinking section only when the model supports it.
    private var profileModelCapabilities: PsmithModelCapabilities? {
        guard let pid = defaultProviderID, let mid = defaultModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .capabilities
    }

    /// Inherited (lower-layer) CallSettings preview — the selected default
    /// model's `defaultSettings`. Profile sits one layer above the model in
    /// the resolution chain.
    private var profileInheritedCallSettings: PsmithCallSettings? {
        guard let pid = defaultProviderID, let mid = defaultModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .defaultSettings
    }

    private func save() async {
        isSaving = true; formError = nil
        defer { isSaving = false }

        var patch = PsmithProfilePatch()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedSystem = systemMessage.trimmingCharacters(in: .whitespaces)
        let trimmedDefault = defaultUserMessage.trimmingCharacters(in: .whitespaces)
        let trimmedCompGuide = compressionGuide.trimmingCharacters(in: .whitespaces)
        let trimmedTitleGuide = titleGuide.trimmingCharacters(in: .whitespaces)

        patch.name = trimmedName
        patch.description = profileDescription.trimmingCharacters(in: .whitespaces)
        patch.parentOnly = parentOnly
        patch.parentProfileID = parentID
        patch.systemMessage = trimmedSystem.isEmpty ? nil : trimmedSystem
        patch.defaultUserMessage = trimmedDefault.isEmpty ? nil : trimmedDefault
        let trimmedWelcome = welcomeMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        patch.welcomeMessage = trimmedWelcome.isEmpty ? nil : trimmedWelcome

        // Build the ProfileDefaults patch lazily — only set it when at least
        // one of the inner fields is populated, otherwise the server treats
        // an empty defaults blob the same as "preserve".
        let trimmedCallSettings: PsmithCallSettings? = callSettingsDraft.isEmpty ? nil : callSettingsDraft
        let hasAnyDefault = defaultProviderID != nil || defaultModelID != nil || trimmedCallSettings != nil
        if hasAnyDefault {
            patch.defaultSettings = PsmithProfileDefaults(
                defaultProviderID: defaultProviderID,
                defaultModelID: defaultModelID,
                callSettings: trimmedCallSettings
            )
        }

        patch.compressionMode       = compressionMode
        patch.compressionProviderID = compressionProviderID
        patch.compressionModelID    = compressionModelID
        patch.compressionGuide      = trimmedCompGuide.isEmpty ? nil : trimmedCompGuide

        // Mutually exclusive: when "Apple Foundation Models" is selected we
        // null out the cloud (provider, model) pair so the kind sentinel is
        // unambiguous on the server.
        if titleProviderKind == PsmithTitleProviderKind.appleFoundation {
            patch.titleProviderID = nil
            patch.titleModelID    = nil
            patch.titleProviderKind = PsmithTitleProviderKind.appleFoundation
        } else {
            patch.titleProviderID = titleProviderID
            patch.titleModelID    = titleModelID
            patch.titleProviderKind = nil
        }
        patch.titleGuide = trimmedTitleGuide.isEmpty ? nil : trimmedTitleGuide

        var clearFields: [String] = []
        if isEdit {
            // On edit, explicitly clear fields the user blanked out so the
            // server reverts them to inherit-from-parent semantics.
            if patch.systemMessage == nil         { clearFields.append("system_message") }
            if patch.defaultUserMessage == nil    { clearFields.append("default_user_message") }
            if patch.welcomeMessage == nil        { clearFields.append("welcome_message") }
            if patch.defaultSettings == nil       { clearFields.append("default_settings") }
            if patch.parentProfileID == nil       { clearFields.append("parent_profile_id") }
            if patch.compressionMode == nil       { clearFields.append("compression_mode") }
            if patch.compressionProviderID == nil { clearFields.append("compression_provider_id") }
            if patch.compressionModelID == nil    { clearFields.append("compression_model_id") }
            if patch.compressionGuide == nil      { clearFields.append("compression_guide") }
            if patch.titleProviderID == nil       { clearFields.append("title_provider_id") }
            if patch.titleModelID == nil          { clearFields.append("title_model_id") }
            if patch.titleGuide == nil            { clearFields.append("title_guide") }
            if patch.titleProviderKind == nil     { clearFields.append("title_provider_kind") }
        }

        do {
            // Step 1: profile fields.
            let profileID: String
            if let editing {
                _ = try await model.update(id: editing.id, patch: patch, clearFields: clearFields)
                profileID = editing.id
            } else {
                let p = try await model.create(patch)
                model.selectedID = p.id
                profileID = p.id
            }

            // Step 2: plugins (when dirty). On Add mode the baseline is
            // empty so any attached draft plugins flush to the
            // freshly-created profile id. On Edit mode we diff against
            // the loaded baseline; equality skips the round-trip.
            if pluginsAreDirty {
                let plugins: [PsmithProfilePlugin] = try pluginsDraft.enumerated().map { ordinal, plugin in
                    let data = try JSONSerialization.data(withJSONObject: plugin.config, options: [.sortedKeys])
                    return PsmithProfilePlugin(
                        pluginName: plugin.pluginName,
                        ordinal: Int32(ordinal),
                        config: data
                    )
                }
                try await model.savePlugins(forProfileID: profileID, plugins: plugins)
            }

            model.detailMode = .viewing
        } catch {
            formError = error.localizedDescription
        }
    }

    /// True when the plugin draft differs from the baseline loaded on
    /// `.task`. Drives both the dirty-indicator and the conditional
    /// `setProfilePlugins` call inside `save()`.
    private var pluginsAreDirty: Bool {
        guard pluginsBaseline.count == pluginsDraft.count else { return true }
        for (b, d) in zip(pluginsBaseline, pluginsDraft) {
            if b.pluginName != d.pluginName { return true }
            let baselineDict = decodeConfigDict(b.config) ?? [:]
            if !configsEqual(baselineDict, d.config) { return true }
        }
        return false
    }

    // MARK: - Plugins UI

    /// Inline plugins section that lives inside the main profile form.
    /// Lists attached plugins as tappable cards; tapping a card pushes
    /// the per-plugin settings sub-screen. New plugins are added via an
    /// inline-expanding picker (no popover — see no-popups rule).
    @ViewBuilder
    private var pluginsSection: some View {
        formSection("Plugins") {
            if !pluginsLoaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading plugins…").scaledFont(.caption).foregroundStyle(.secondary)
                }
            } else {
                if pluginsDraft.isEmpty {
                    Text(isEdit
                         ? "No plugins. Inherits from parent profile."
                         : "No plugins yet. Add one below.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(pluginsDraft.enumerated()), id: \.element.localID) { idx, plugin in
                            pluginCard(at: idx, plugin: plugin)
                        }
                    }
                }
                addPluginPickerInline
            }
        }
    }

    @ViewBuilder
    private func pluginCard(at index: Int, plugin: DraftPlugin) -> some View {
        let pluginType = model.pluginTypes.first(where: { $0.name == plugin.pluginName })
        let title = pluginType?.displayName ?? plugin.pluginName
        let description = pluginType?.description ?? ""
        // Profile-scoped fields drive the drill-down; if a plugin only
        // exposes global fields, the card is non-drillable (settings
        // live on the Plugin Settings surface, not in the profile form).
        let profileScopedFields = pluginType?.profileScopedConfigFields ?? []
        let drillable = !profileScopedFields.isEmpty
        let unsatisfiedCount = profileScopedFields
            .filter { $0.isUnsatisfied(by: plugin.config[$0.name]) }
            .count
        let globalUnsatisfiedCount = (pluginType?.globalConfigFields ?? []).filter { field in
            field.required && globalConfigValue(plugin: plugin.pluginName, key: field.name) == nil
        }.count

        Button {
            if drillable {
                configuringPluginLocalID = plugin.localID
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).scaledFont(.callout, weight: .medium)
                        if unsatisfiedCount > 0 {
                            warningChip(text: "\(unsatisfiedCount) required")
                        }
                        if globalUnsatisfiedCount > 0 {
                            warningChip(text: "global setup needed")
                                .help("This plugin's global settings have unsatisfied required fields. Open Plugin Settings to configure.")
                        }
                    }
                    if !description.isEmpty {
                        Text(description)
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    capabilityChips(pluginType?.capabilities)
                }
                Spacer(minLength: 4)
                GlassCircleButton(
                    systemImage: "minus",
                    action: { removePlugin(at: index) },
                    help: "Remove plugin",
                    tint: .red
                )
                if drillable {
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption2, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.04))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        (unsatisfiedCount + globalUnsatisfiedCount) > 0
                            ? AnyShapeStyle(Color.orange.opacity(0.45))
                            : AnyShapeStyle(Color.primary.opacity(0.06)),
                        lineWidth: (unsatisfiedCount + globalUnsatisfiedCount) > 0 ? 1.2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!drillable && pluginType != nil)
    }

    private func warningChip(text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 9, weight: .semibold)
            Text(text)
                .scaledFont(.caption2, weight: .medium)
        }
        .foregroundStyle(.orange)
    }

    /// Lookup helper for the per-card "global setup needed" check.
    /// Decodes the cached blob from the view-model on the fly; safe to
    /// call before the loadUserPluginSettings task completes (returns
    /// nil for missing rows).
    private func globalConfigValue(plugin: String, key: String) -> Any? {
        let blob = model.globalSettings(for: plugin).config
        guard !blob.isEmpty,
              let dict = try? JSONSerialization.jsonObject(with: blob, options: []) as? [String: Any]
        else { return nil }
        let value = dict[key]
        if let s = value as? String, s.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return value
    }

    @ViewBuilder
    private func capabilityChips(_ caps: PsmithPluginCapabilities?) -> some View {
        if let caps {
            HStack(spacing: 4) {
                if caps.toolProvider                 { miniChip("Tool") }
                if caps.systemPrompter               { miniChip("System") }
                if caps.outgoingUserTransformer      { miniChip("Outgoing") }
                if caps.assistantContentTransformer  { miniChip("Assistant") }
                if caps.historyTransformer           { miniChip("History") }
                if caps.chunkTransformer             { miniChip("Chunks") }
                if caps.displayTransformer           { miniChip("Display") }
                if caps.messageLifecycleHook         { miniChip("Lifecycle") }
            }
        }
    }

    private func miniChip(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 9, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    /// Inline-expanding plugin picker (mirrors the model picker's UX
    /// pattern — no popover, no Menu, scrollable card list inline).
    @ViewBuilder
    private var addPluginPickerInline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showingAddPluginPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingAddPluginPicker ? "chevron.up" : "plus")
                    Text(showingAddPluginPicker ? "Cancel" : "Add plugin")
                }
                .scaledFont(.callout)
            }
            .controlSize(.small)
            .buttonStyle(.glass)
            .disabled(model.pluginTypes.isEmpty)

            if showingAddPluginPicker {
                let attachedNames = Set(pluginsDraft.map { $0.pluginName })
                let available = model.pluginTypes.filter { !attachedNames.contains($0.name) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if available.isEmpty {
                            Text("Every available plugin is already attached.")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(available) { pluginType in
                                pluginTypeCard(pluginType)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 240)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.12), value: showingAddPluginPicker)
    }

    private func pluginTypeCard(_ pluginType: PsmithPluginType) -> some View {
        Button {
            attachPlugin(pluginType)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pluginType.displayName).scaledFont(.callout, weight: .medium)
                    Spacer()
                    Image(systemName: "plus.circle")
                        .scaledFont(.callout)
                        .foregroundStyle(.tertiary)
                }
                if !pluginType.description.isEmpty {
                    Text(pluginType.description)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                capabilityChips(pluginType.capabilities)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.03))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func attachPlugin(_ pluginType: PsmithPluginType) {
        // Initialise the dict from each field's defaultJSON so the row
        // has sensible starting values; required fields stay missing
        // (they have no default) and surface as the warning chip until
        // the user enters a value.
        var initial: [String: Any] = [:]
        for field in pluginType.configFields {
            if !field.defaultJSON.isEmpty,
               let data = field.defaultJSON.data(using: .utf8),
               let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                initial[field.name] = any
            }
        }
        let draft = DraftPlugin(pluginName: pluginType.name, config: initial)
        pluginsDraft.append(draft)
        showingAddPluginPicker = false
        // Drill into settings immediately when the plugin has any
        // profile-scoped config to fill in. Plugins exposing only
        // global fields land back on the profile form (the user
        // configures them on the Plugin Settings surface instead).
        if !pluginType.profileScopedConfigFields.isEmpty {
            configuringPluginLocalID = draft.localID
        }
    }

    private func removePlugin(at index: Int) {
        guard pluginsDraft.indices.contains(index) else { return }
        pluginsDraft.remove(at: index)
    }

    /// Sub-screen that fully replaces the profile form pane with the
    /// per-plugin config form. Edits flow into the parent draft via
    /// Binding; Back returns to the main form preserving in-flight
    /// state. No Save button on this screen — the parent profile-form
    /// Save persists everything atomically.
    @ViewBuilder
    private func pluginSettingsSubScreen(index: Int) -> some View {
        let plugin = pluginsDraft[index]
        let pluginType = model.pluginTypes.first(where: { $0.name == plugin.pluginName })
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    configuringPluginLocalID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .scaledFont(.callout)
                }
                .controlSize(.small)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)

                Text(pluginType?.displayName ?? plugin.pluginName)
                    .scaledFont(.headline)
                    .lineLimit(1)
                Spacer()
                Text("Edits flow into the parent profile draft. Save on the profile screen to persist.")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: paneHeaderHeight)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let pluginType, !pluginType.description.isEmpty {
                        Text(pluginType.description)
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let pluginType {
                        let profileFields = pluginType.profileScopedConfigFields
                        let globalFields = pluginType.globalConfigFields
                        if profileFields.isEmpty && globalFields.isEmpty {
                            Text("This plugin has no settings.")
                                .foregroundStyle(.secondary)
                        } else if profileFields.isEmpty {
                            // Pure global plugin — drill-down has nothing
                            // to render; nudge the user to the right
                            // surface.
                            VStack(alignment: .leading, spacing: 6) {
                                Text("All of this plugin's settings live at user scope.")
                                    .foregroundStyle(.secondary)
                                Text("Open Plugin Settings (in the app's main settings) to configure them once across every profile that uses this plugin.")
                                    .scaledFont(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            PluginConfigEditor(
                                pluginName: plugin.pluginName,
                                fields: profileFields,
                                config: Binding(
                                    get: { pluginsDraft[index].config },
                                    set: { pluginsDraft[index].config = $0 }
                                ),
                                availableModels: model.availableModels,
                                providerLabels: model.providerLabels,
                                providerTypes: model.providerTypes,
                                providerPresetIDs: model.providerPresetIDs
                            )
                            if !globalFields.isEmpty {
                                Divider().padding(.vertical, 6)
                                Text("Other settings for this plugin (such as credentials) live at user scope. Edit them in the app's Plugin Settings — they apply to every profile that uses this plugin.")
                                    .scaledFont(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        Text("This plugin has no settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}


private struct DraftPlugin {
    let localID = UUID()
    var pluginName: String
    var config: [String: Any]
}

private func decodeConfigDict(_ data: Data) -> [String: Any]? {
    guard !data.isEmpty else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
}

/// Shallow equality on the JSON-serializable subset we ever write into
/// these dicts (Bool / Int / Double / String + nested dicts/arrays of the
/// same). Used to drive the dirty indicator on the Plugins section.
private func configsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    guard a.count == b.count else { return false }
    for (k, v) in a {
        guard let other = b[k] else { return false }
        if !anyEqual(v, other) { return false }
    }
    return true
}

private func anyEqual(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case let (a as Bool, b as Bool):     return a == b
    case let (a as Int, b as Int):       return a == b
    case let (a as Double, b as Double): return a == b
    case let (a as Int, b as Double):    return Double(a) == b
    case let (a as Double, b as Int):    return a == Double(b)
    case let (a as String, b as String): return a == b
    case let (a as [Any], b as [Any]):
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { anyEqual($0, $1) }
    case let (a as [String: Any], b as [String: Any]):
        return configsEqual(a, b)
    default:
        return false
    }
}
