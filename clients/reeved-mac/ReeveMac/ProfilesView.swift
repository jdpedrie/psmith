import SwiftUI
import ReeveKit

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
    let profile: ReeveProfile
    let profiles: [ReeveProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.name).lineLimit(1)
            if !ancestorNames.isEmpty {
                Text(ancestorNames.joined(separator: " ‹ "))
                    .font(.caption2)
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
        .task { await model.loadAvailableModels() }
    }
}

// MARK: - Read-only viewer

private struct ProfileViewer: View {
    let profile: ReeveProfile
    @Bindable var model: ProvidersViewModelHelper
    @Environment(\.theme) private var theme

    init(profile: ReeveProfile, model: ProfilesViewModel) {
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
                            .font(.headline)
                            .lineLimit(1)
                        if profile.parentOnly {
                            Text("PARENT ONLY")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }
                    Text(parentName.map { "Inherits from \($0)" } ?? "Standalone profile")
                        .font(.caption2)
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
                                        Text("Mode:").foregroundStyle(.secondary).font(.caption)
                                        Text(modeLabel(mode)).font(.callout)
                                    }
                                }
                                if profile.compressionProviderID != nil || profile.compressionModelID != nil {
                                    HStack(spacing: 4) {
                                        Text("Model:").foregroundStyle(.secondary).font(.caption)
                                        modelDescription(profile.compressionProviderID, profile.compressionModelID)
                                            .font(.callout)
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
                                if profile.titleProviderKind == ReeveTitleProviderKind.appleFoundation {
                                    HStack(spacing: 6) {
                                        Image(systemName: "apple.logo")
                                            .foregroundStyle(theme.accent)
                                        Text("Apple Foundation Models")
                                            .font(.callout)
                                        Text("ON DEVICE")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(theme.accent.opacity(0.85))
                                            .clipShape(Capsule())
                                    }
                                } else if profile.titleProviderID != nil || profile.titleModelID != nil {
                                    HStack(spacing: 4) {
                                        Text("Model:").foregroundStyle(.secondary).font(.caption)
                                        modelDescription(profile.titleProviderID, profile.titleModelID)
                                            .font(.callout)
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            if let err = model.profilesModel.error {
                PaneFooter {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
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

    private func modeLabel(_ m: ReeveCompressionMode) -> String {
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            body()
        }
    }

    private func multilineText(_ s: String) -> some View {
        Text(s)
            .font(.callout)
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
    let editing: ReeveProfile?

    @Environment(\.theme) private var theme

    @State private var name = ""
    @State private var profileDescription = ""
    @State private var parentOnly = false
    @State private var parentID: String?
    @State private var systemMessage = ""
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
    @State private var callSettingsDraft = ReeveCallSettings()

    // Compression
    @State private var compressionMode: ReeveCompressionMode? = nil
    @State private var compressionProviderID: String?
    @State private var compressionModelID: String?
    @State private var compressionGuide = ""

    // Title generation
    @State private var titleProviderID: String?
    @State private var titleModelID: String?
    @State private var titleGuide = ""
    /// Sentinel naming a non-server titler. Currently only
    /// `ReeveTitleProviderKind.appleFoundation` ("apple_foundation") is
    /// recognized — picks the on-device Apple Foundation Models path on the
    /// Mac. Mutually exclusive with the cloud title model picker below;
    /// selecting one nils the other.
    @State private var titleProviderKind: String?

    @State private var isSaving = false
    @State private var formError: String?

    private var isEdit: Bool { editing != nil }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — same paneHeaderHeight band as ProfileViewer / ProviderHeader
            // for column-to-column visual rhythm.
            HStack(alignment: .center, spacing: 8) {
                Text(isEdit ? "Edit profile" : "Add profile")
                    .font(.headline)
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
                                excludeID: editing?.id
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
                    }

                    formSection("Default model") {
                        formRow(label: "Model",
                                description: "Used for normal turns when the conversation doesn't override.") {
                            modelPicker(slot: .default, provider: $defaultProviderID, model: $defaultModelID)
                        }
                    }

                    formSection("Default call settings") {
                        Text("Per-profile generation knobs (temperature, max tokens, thinking, …). Any unset field inherits from the model and provider layers below at send time.")
                            .font(.caption2)
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
                                Text("(inherit)").tag(ReeveCompressionMode?.none)
                                Text("Replace").tag(ReeveCompressionMode?.some(.replace))
                                Text("Append").tag(ReeveCompressionMode?.some(.append))
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

                    if let editing {
                        PluginsSection(model: model, profileID: editing.id)
                    }

                    formSection("Auto-titling") {
                        formRow(label: "Generator",
                                description: "Apple Foundation Models runs locally on macOS 26+ — free, fast, private. Pick a cloud model below to use a paid LLM instead.") {
                            titleGeneratorPicker
                        }
                        if titleProviderKind != ReeveTitleProviderKind.appleFoundation {
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
                        Text(formError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
                .frame(width: geo.size.width, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { seedFromEditing() }
    }


    /// Width of the left "label" column; used by every formRow so fields line up.
    private static let labelColumnWidth: CGFloat = 130

    @ViewBuilder
    private func formSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.caption)
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
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func multilineEditor(_ binding: Binding<String>) -> some View {
        TextEditor(text: binding)
            .font(.callout)
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
                        Image(systemName: "cpu").font(.caption2)
                    }
                    Text(modelLabel(provider: provider.wrappedValue, model: modelBinding.wrappedValue))
                    Image(systemName: expandedPicker == slot ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .font(.callout)
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
        let isLocal = titleProviderKind == ReeveTitleProviderKind.appleFoundation
        let isCloud = !isLocal && titleProviderID != nil && titleModelID != nil
        let isInherit = !isLocal && !isCloud

        VStack(alignment: .leading, spacing: 6) {
            titleGeneratorCard(
                title: "Apple Foundation Models",
                subtitle: "On-device · free · macOS 26+",
                systemImage: "apple.logo",
                badge: "ON DEVICE",
                isSelected: isLocal,
                tint: theme.accent
            ) {
                titleProviderKind = ReeveTitleProviderKind.appleFoundation
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.callout.weight(.medium))
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(tint.opacity(0.85))
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
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
        }
        .buttonStyle(.plain)
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
        defaultUserMessage = p.defaultUserMessage ?? ""
        defaultProviderID = p.defaultSettings?.defaultProviderID
        defaultModelID    = p.defaultSettings?.defaultModelID
        callSettingsDraft = p.defaultSettings?.callSettings ?? ReeveCallSettings()

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
    private var profileModelCapabilities: ReeveModelCapabilities? {
        guard let pid = defaultProviderID, let mid = defaultModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .capabilities
    }

    /// Inherited (lower-layer) CallSettings preview — the selected default
    /// model's `defaultSettings`. Profile sits one layer above the model in
    /// the resolution chain.
    private var profileInheritedCallSettings: ReeveCallSettings? {
        guard let pid = defaultProviderID, let mid = defaultModelID else { return nil }
        return model.availableModels
            .first(where: { $0.providerID == pid && $0.modelID == mid })?
            .defaultSettings
    }

    private func save() async {
        isSaving = true; formError = nil
        defer { isSaving = false }

        var patch = ReeveProfilePatch()
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

        // Build the ProfileDefaults patch lazily — only set it when at least
        // one of the inner fields is populated, otherwise the server treats
        // an empty defaults blob the same as "preserve".
        let trimmedCallSettings: ReeveCallSettings? = callSettingsDraft.isEmpty ? nil : callSettingsDraft
        let hasAnyDefault = defaultProviderID != nil || defaultModelID != nil || trimmedCallSettings != nil
        if hasAnyDefault {
            patch.defaultSettings = ReeveProfileDefaults(
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
        if titleProviderKind == ReeveTitleProviderKind.appleFoundation {
            patch.titleProviderID = nil
            patch.titleModelID    = nil
            patch.titleProviderKind = ReeveTitleProviderKind.appleFoundation
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
            if let editing {
                _ = try await model.update(id: editing.id, patch: patch, clearFields: clearFields)
            } else {
                let p = try await model.create(patch)
                model.selectedID = p.id
            }
            model.detailMode = .viewing
        } catch {
            formError = error.localizedDescription
        }
    }
}

// MARK: - Plugins section

/// Inline plugins editor lives at the bottom of ProfileForm. Owns its own
/// draft list (so edits don't mutate ProfilesViewModel.profilePlugins until
/// the user clicks Save plugins). Loads from the server on appear.
private struct PluginsSection: View {
    @Bindable var model: ProfilesViewModel
    let profileID: String

    @State private var draft: [DraftPlugin] = []
    @State private var loaded = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var addPopoverShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plugins")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if isDirty {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView().controlSize(.small) }
                        else { Text("Save plugins") }
                    }
                    .controlSize(.small)
                    .buttonStyle(.glassProminent)
                    .disabled(isSaving)
                }
            }

            if !loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading plugins…").font(.caption).foregroundStyle(.secondary)
                }
            } else if draft.isEmpty {
                Text("No plugins. Inherits from parent profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(draft.enumerated()), id: \.element.localID) { index, plugin in
                        pluginRow(index: index, plugin: plugin)
                    }
                }
            }

            addPluginButton
                .disabled(model.pluginTypes.isEmpty)

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
        }
        .task {
            if model.pluginTypes.isEmpty {
                await model.loadPluginTypes()
            }
            await model.loadPlugins(forProfileID: profileID)
            seedDraft()
            loaded = true
        }
    }

    @ViewBuilder
    private func pluginRow(index: Int, plugin: DraftPlugin) -> some View {
        let pluginType = model.pluginTypes.first(where: { $0.name == plugin.pluginName })
        let title = pluginType?.name ?? plugin.pluginName
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    if let desc = pluginType?.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                GlassCircleButton(
                    systemImage: "minus",
                    action: { remove(at: index) },
                    help: "Remove plugin",
                    tint: .red
                )
            }

            if let pluginType, !pluginType.configFields.isEmpty {
                PluginConfigForm(
                    fields: pluginType.configFields,
                    config: Binding(
                        get: { draft[index].config },
                        set: { draft[index].config = $0 }
                    )
                )
                .padding(.leading, 4)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var addPluginButton: some View {
        Button {
            addPopoverShown = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("Add plugin")
            }
            .font(.callout)
        }
        .controlSize(.small)
        .buttonStyle(.glass)
        .popover(isPresented: $addPopoverShown, arrowEdge: .bottom) {
            addPluginPopoverContent
        }
    }

    private var addPluginPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pluginTypes.isEmpty {
                Text("No plugins available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(model.pluginTypes) { pluginType in
                    Button {
                        addPopoverShown = false
                        attach(pluginType)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pluginType.name)
                                .foregroundStyle(.primary)
                                .font(.callout)
                            if !pluginType.description.isEmpty {
                                Text(pluginType.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 260)
        .padding(.vertical, 4)
    }

    // MARK: state helpers

    private func seedDraft() {
        let stored = model.profilePlugins[profileID] ?? []
        draft = stored.map { plugin in
            DraftPlugin(
                pluginName: plugin.pluginName,
                config: decodeConfigDict(plugin.config) ?? [:]
            )
        }
    }

    private func attach(_ pluginType: ReevePluginType) {
        // Initialize the dict from each field's defaultJSON so the row
        // has sensible starting values.
        var initial: [String: Any] = [:]
        for field in pluginType.configFields {
            if !field.defaultJSON.isEmpty,
               let data = field.defaultJSON.data(using: .utf8),
               let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                initial[field.name] = any
            }
        }
        draft.append(DraftPlugin(pluginName: pluginType.name, config: initial))
    }

    private func remove(at index: Int) {
        guard draft.indices.contains(index) else { return }
        draft.remove(at: index)
    }

    private var isDirty: Bool {
        let stored = model.profilePlugins[profileID] ?? []
        guard stored.count == draft.count else { return true }
        for (s, d) in zip(stored, draft) {
            if s.pluginName != d.pluginName { return true }
            let storedDict = decodeConfigDict(s.config) ?? [:]
            if !configsEqual(storedDict, d.config) { return true }
        }
        return false
    }

    private func save() async {
        isSaving = true; saveError = nil
        defer { isSaving = false }
        do {
            let plugins: [ReeveProfilePlugin] = try draft.enumerated().map { ordinal, plugin in
                let data = try JSONSerialization.data(withJSONObject: plugin.config, options: [.sortedKeys])
                return ReeveProfilePlugin(
                    pluginName: plugin.pluginName,
                    ordinal: Int32(ordinal),
                    config: data
                )
            }
            try await model.savePlugins(forProfileID: profileID, plugins: plugins)
            seedDraft()
        } catch {
            saveError = error.localizedDescription
        }
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
