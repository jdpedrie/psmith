import SwiftUI
import ClarkKit

/// Full-pane "start a new conversation" view that replaces the chats
/// detail when `Navigator.composingNewConversation == true`. Asks for an
/// optional title, a profile (via the card row), and optional model /
/// chat-setting overrides — replaces the old popover.
struct NewConversationView: View {
    @Environment(AppModel.self) private var app
    @Environment(ConversationsModel.self) private var convos
    @Environment(Navigator.self) private var navigator

    @State private var title: String = ""
    @State private var selectedProfileID: String?
    @State private var overrideProviderID: String?
    @State private var overrideModelID: String?
    @State private var includeThinkingOverride: Bool? = nil
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var modelSearch: String = ""

    private var canCreate: Bool {
        !isCreating && selectedProfileID != nil
    }

    private var defaultProfileID: String? {
        app.profiles.sortedForPicker.first(where: { !$0.parentOnly })?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                titleField
                profileSection
                modelOverrideSection
                thinkingSection
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("New conversation")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    cancel()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) }
                    else { Text("Start chat") }
                }
                .buttonStyle(.glassProminent)
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .task {
            await app.profiles.load()
            await app.profiles.loadAvailableModels()
            if selectedProfileID == nil {
                selectedProfileID = defaultProfileID
            }
        }
    }

    // MARK: - Sections

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Title")
            TextField("Auto-generated if left blank", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 440)
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Profile")
            ProfilePickerRow(
                model: app.profiles,
                selectedID: $selectedProfileID
            )
        }
    }

    private var modelOverrideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Model override")
            Text("Use a different model for this conversation than the profile's default.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            modelRowList
        }
    }

    @ViewBuilder
    private var modelRowList: some View {
        let providerLabels = app.profiles.providerLabels
        let all = app.profiles.availableModels
        let needle = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? all : all.filter { m in
            let provider = providerLabels[m.providerID] ?? m.providerID
            return m.displayName.lowercased().contains(needle)
                || m.modelID.lowercased().contains(needle)
                || provider.lowercased().contains(needle)
        }
        // Partition into favorites + the rest. Favorites get their own group at
        // the top; the rest are grouped per-provider as before.
        let favorites = filtered.filter { $0.favorite }.sorted { $0.displayName < $1.displayName }
        let nonFavorites = filtered.filter { !$0.favorite }
        let grouped: [(provider: String, models: [ClarkUserModel])] = Dictionary(grouping: nonFavorites) { $0.providerID }
            .map { (providerLabels[$0.key] ?? $0.key, $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.provider < $1.provider }
        let showProviderHeaders = grouped.count > 1 || !favorites.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            if all.count > 6 {
                TextField("Filter models", text: $modelSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 440)
            }

            ScrollView {
                VStack(spacing: 6) {
                    modelRow(
                        title: "Inherit from profile",
                        subtitle: nil,
                        isSelected: overrideModelID == nil,
                        systemImage: "arrow.turn.down.right",
                        model: nil
                    ) {
                        overrideProviderID = nil
                        overrideModelID = nil
                    }
                    if !favorites.isEmpty {
                        groupHeader("Favorites")
                        ForEach(favorites, id: \.self) { m in
                            modelRow(
                                title: m.displayName,
                                subtitle: providerLabels[m.providerID] ?? m.providerID,
                                isSelected: overrideProviderID == m.providerID && overrideModelID == m.modelID,
                                systemImage: "cpu",
                                model: m
                            ) {
                                overrideProviderID = m.providerID
                                overrideModelID = m.modelID
                            }
                        }
                    }
                    ForEach(grouped, id: \.provider) { group in
                        if showProviderHeaders {
                            groupHeader(group.provider)
                        }
                        ForEach(group.models, id: \.self) { m in
                            modelRow(
                                title: m.displayName,
                                subtitle: showProviderHeaders ? nil : group.provider,
                                isSelected: overrideProviderID == m.providerID && overrideModelID == m.modelID,
                                systemImage: "cpu",
                                model: m
                            ) {
                                overrideProviderID = m.providerID
                                overrideModelID = m.modelID
                            }
                        }
                    }
                    if !needle.isEmpty && filtered.isEmpty {
                        Text("No models match \"\(modelSearch)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: 440)
            .frame(maxHeight: all.count > 6 ? 320 : .infinity)
        }
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.horizontal, 4)
    }

    private func modelRow(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        systemImage: String,
        model: ClarkUserModel?,
        action: @escaping () -> Void
    ) -> some View {
        // Two siblings inside an HStack:
        //   - the row Button (icon + title + subtitle, expands to fill)
        //   - the star Button (only present for real models)
        // No nesting: each Button sees its own taps cleanly.
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.callout)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let model {
                Button {
                    Task { await app.profiles.toggleModelFavorite(providerID: model.providerID, modelID: model.modelID) }
                } label: {
                    Image(systemName: model.favorite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.favorite ? Color.yellow : Color.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.favorite ? "Unfavorite" : "Mark as favorite")
                .padding(.trailing, 6)
            }
        }
        .glassEffect(
            isSelected ? .regular.tint(.accentColor.opacity(0.18)).interactive()
                       : .regular.interactive(),
            in: .rect(cornerRadius: 10)
        )
    }

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Chat settings")
            Text("Include thinking in history")
                .font(.callout)
            Text("Whether assistant chain-of-thought is sent back as context on follow-up turns.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Picker("Include thinking in history", selection: thinkingBinding) {
                Text("Inherit from profile").tag(Bool?.none)
                Text("Include").tag(Bool?.some(true))
                Text("Exclude").tag(Bool?.some(false))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
        }
    }

    private var thinkingBinding: Binding<Bool?> {
        Binding(get: { includeThinkingOverride }, set: { includeThinkingOverride = $0 })
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func cancel() {
        navigator.composingNewConversation = false
    }

    private func create() async {
        guard let profileID = selectedProfileID else { return }
        isCreating = true
        defer { isCreating = false }

        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        var settings = ClarkConversationSettings()
        settings.defaultProviderID = overrideProviderID
        settings.defaultModelID = overrideModelID
        settings.includeThinkingInHistory = includeThinkingOverride

        let convo = await convos.newConversation(
            profileID: profileID,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            settings: settings
        )
        if convo != nil {
            navigator.composingNewConversation = false
        } else {
            errorMessage = convos.loadError ?? "Failed to start conversation."
        }
    }
}
