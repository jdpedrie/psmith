import SwiftUI
import ClarkKit

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
                .listStyle(.sidebar)
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: ClarkProfile
    let profiles: [ClarkProfile]

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
    let profile: ClarkProfile
    @Bindable var model: ProvidersViewModelHelper

    init(profile: ClarkProfile, model: ProfilesViewModel) {
        self.profile = profile
        self.model = ProvidersViewModelHelper(model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.title3).fontWeight(.semibold)
                    if let parent = parentName {
                        Text("Inherits from \(parent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Edit") { model.profilesModel.detailMode = .editing }
                    .buttonStyle(.glass)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                                if profile.titleProviderID != nil || profile.titleModelID != nil {
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

            PaneFooter {
                if let err = model.profilesModel.error {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                if hasChildren {
                    Text("Has \(childCount) child profile\(childCount == 1 ? "" : "s") — delete those first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Delete profile", role: .destructive) {
                    model.profilesModel.showDeleteConfirm = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(model.profilesModel.isDeleting || hasChildren)
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
    }

    private var isFullyInherited: Bool {
        profile.systemMessage == nil
            && profile.defaultUserMessage == nil
            && profile.defaultSettings == nil
            && !hasCompressionOverrides
            && !hasTitleOverrides
    }

    private func modeLabel(_ m: ClarkCompressionMode) -> String {
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
    let editing: ClarkProfile?

    @State private var name = ""
    @State private var parentID: String?
    @State private var systemMessage = ""
    @State private var defaultUserMessage = ""
    @State private var defaultProviderID: String?
    @State private var defaultModelID: String?

    // Compression
    @State private var compressionMode: ClarkCompressionMode? = nil
    @State private var compressionProviderID: String?
    @State private var compressionModelID: String?
    @State private var compressionGuide = ""

    // Title generation
    @State private var titleProviderID: String?
    @State private var titleModelID: String?
    @State private var titleGuide = ""

    @State private var isSaving = false
    @State private var formError: String?

    private var isEdit: Bool { editing != nil }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text(isEdit ? "Edit profile" : "Add profile")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") {
                    model.detailMode = .viewing
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text(isEdit ? "Save" : "Create") }
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    formSection("Basic") {
                        formRow(label: "Name",
                                description: "Short, memorable. Shown in the conversation list.") {
                            TextField("e.g. Default, Coding, Brainstorm", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                        formRow(label: "Inherits from",
                                description: "Any field left blank below falls back to this parent.") {
                            Picker("", selection: $parentID) {
                                Text("(none)").tag(String?.none)
                                ForEach(otherProfiles, id: \.id) { p in
                                    Text(p.name).tag(Optional(p.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 280)
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
                            modelPicker(provider: $defaultProviderID, model: $defaultModelID)
                        }
                    }

                    formSection("Compression") {
                        formRow(label: "Mode",
                                description: "Replace replaces the context with a summary; Append keeps both.") {
                            Picker("", selection: $compressionMode) {
                                Text("(inherit)").tag(ClarkCompressionMode?.none)
                                Text("Replace").tag(ClarkCompressionMode?.some(.replace))
                                Text("Append").tag(ClarkCompressionMode?.some(.append))
                            }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                        }
                        formRow(label: "Model",
                                description: "Model used to write the summary.") {
                            modelPicker(provider: $compressionProviderID, model: $compressionModelID)
                        }
                        formRow(label: "Guide",
                                description: "Optional extra instruction for the summariser.") {
                            multilineEditor($compressionGuide).frame(minHeight: 60)
                        }
                    }

                    formSection("Auto-titling") {
                        formRow(label: "Model",
                                description: "Model used to invent a 2–5 word title after the first assistant turn. Auto-titling only fires when both this and a title guide resolve.") {
                            modelPicker(provider: $titleProviderID, model: $titleModelID)
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
            }
        }
        .onAppear { seedFromEditing() }
    }

    private var otherProfiles: [ClarkProfile] {
        model.profiles.filter { $0.id != editing?.id }
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

    /// Reusable provider+model picker. Sets both bindings together; (nil, nil)
    /// means "inherit" / "unset". Grouped by provider in the menu.
    private func modelPicker(
        provider: Binding<String?>,
        model modelBinding: Binding<String?>
    ) -> some View {
        Menu {
            Button("(unset — inherit)") {
                provider.wrappedValue = nil
                modelBinding.wrappedValue = nil
            }
            Divider()
            let grouped = Dictionary(grouping: model.availableModels, by: \.providerID)
            ForEach(grouped.keys.sorted(), id: \.self) { pid in
                Section(model.providerLabels[pid] ?? pid) {
                    ForEach(grouped[pid] ?? []) { m in
                        Button {
                            provider.wrappedValue = m.providerID
                            modelBinding.wrappedValue = m.modelID
                        } label: {
                            if m.providerID == provider.wrappedValue && m.modelID == modelBinding.wrappedValue {
                                Label(m.displayName, systemImage: "checkmark")
                            } else {
                                Text(m.displayName)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.caption2)
                Text(modelLabel(provider: provider.wrappedValue, model: modelBinding.wrappedValue))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
        parentID = p.parentProfileID
        systemMessage = p.systemMessage ?? ""
        defaultUserMessage = p.defaultUserMessage ?? ""
        defaultProviderID = p.defaultSettings?.defaultProviderID
        defaultModelID    = p.defaultSettings?.defaultModelID

        compressionMode       = p.compressionMode
        compressionProviderID = p.compressionProviderID
        compressionModelID    = p.compressionModelID
        compressionGuide      = p.compressionGuide ?? ""

        titleProviderID = p.titleProviderID
        titleModelID    = p.titleModelID
        titleGuide      = p.titleGuide ?? ""
    }

    private func save() async {
        isSaving = true; formError = nil
        defer { isSaving = false }

        var patch = ClarkProfilePatch()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedSystem = systemMessage.trimmingCharacters(in: .whitespaces)
        let trimmedDefault = defaultUserMessage.trimmingCharacters(in: .whitespaces)
        let trimmedCompGuide = compressionGuide.trimmingCharacters(in: .whitespaces)
        let trimmedTitleGuide = titleGuide.trimmingCharacters(in: .whitespaces)

        patch.name = trimmedName
        patch.parentProfileID = parentID
        patch.systemMessage = trimmedSystem.isEmpty ? nil : trimmedSystem
        patch.defaultUserMessage = trimmedDefault.isEmpty ? nil : trimmedDefault

        if let pid = defaultProviderID, let mid = defaultModelID {
            patch.defaultSettings = ClarkProfileDefaults(
                defaultProviderID: pid,
                defaultModelID: mid
            )
        }

        patch.compressionMode       = compressionMode
        patch.compressionProviderID = compressionProviderID
        patch.compressionModelID    = compressionModelID
        patch.compressionGuide      = trimmedCompGuide.isEmpty ? nil : trimmedCompGuide

        patch.titleProviderID = titleProviderID
        patch.titleModelID    = titleModelID
        patch.titleGuide      = trimmedTitleGuide.isEmpty ? nil : trimmedTitleGuide

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
