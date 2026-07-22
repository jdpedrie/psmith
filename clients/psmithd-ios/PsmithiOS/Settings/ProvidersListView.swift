import SwiftUI
import PsmithKit
import PsmithUI

/// iOS Providers list. Push from SettingsRoot. Per
/// `docs/clients/ios-reference.md`: Configured + Available sections,
/// `+` toolbar opens a custom AddProviderSheet.
///
/// Phase 7b ships the moderate scope: list + per-provider detail with
/// enabled models, swipe-to-delete, add-via-template flow. The
/// Discover / Default Settings detail tabs from Mac are deferred to a
/// follow-up sub-phase — the iPhone surface ships with model browsing
/// + delete + add only.
struct ProvidersListView: View {
    @Environment(AppModel.self) private var app
    @State private var deleteCandidate: PsmithUserModelProvider?
    @State private var addingTemplate: PsmithProviderTemplate?
    @State private var addingCustom: Bool = false

    var body: some View {
        @Bindable var providers = app.providers
        Group {
            if providers.isLoadingProviders && providers.providers.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Configured") {
                        if providers.providers.isEmpty {
                            Text("No providers yet. Tap + to add one.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(providers.providers) { provider in
                                NavigationLink {
                                    ProviderDetailView(provider: provider)
                                } label: {
                                    configuredRow(provider)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteCandidate = provider
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    if !availableTemplates.isEmpty {
                        Section("Available") {
                            ForEach(availableTemplates) { template in
                                Button {
                                    addingTemplate = template
                                } label: {
                                    availableRow(template)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addingCustom = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add custom provider")
            }
        }
        .task {
            if providers.providers.isEmpty {
                await providers.load()
            }
        }
        .sheet(item: $addingTemplate) { template in
            AddProviderSheet(template: template)
        }
        .sheet(isPresented: $addingCustom) {
            AddProviderSheet(template: nil)
        }
        .alert(
            "Provider error",
            isPresented: Binding(
                get: { providers.error != nil },
                set: { if !$0 { providers.error = nil } }
            ),
            presenting: providers.error
        ) { _ in
            Button("OK") { providers.error = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            "Delete provider?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            presenting: deleteCandidate
        ) { provider in
            Button("Delete", role: .destructive) {
                Haptics.notify(.warning)
                providers.selectedID = provider.id
                Task { await providers.deleteSelected() }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { provider in
            Text("This will delete \"\(provider.label)\" and disable every model under it. Conversations using these models won't be able to send.")
        }
    }

    // MARK: - Available templates (filter out already-configured)

    private var availableTemplates: [PsmithProviderTemplate] {
        // PsmithUserModelProvider doesn't store catalogProviderID
        // directly — derive a comparable key per provider:
        //   - native drivers ("anthropic", "google") → type
        //   - openai-compatible → presetID (xai, groq, …)
        // A template is "available" if no configured provider matches.
        let configuredKeys = Set(app.providers.providers.map(catalogKey(for:)))
        return app.providers.templates
            .filter { !configuredKeys.contains($0.catalogProviderID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func catalogKey(for provider: PsmithUserModelProvider) -> String {
        if provider.type == "openai-compatible", let preset = provider.presetID, !preset.isEmpty {
            return preset
        }
        return provider.type
    }

    // MARK: - Row builders

    @ViewBuilder
    private func configuredRow(_ provider: PsmithUserModelProvider) -> some View {
        HStack(spacing: 10) {
            ProviderLogo(slug: logoSlug(for: provider), size: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.label)
                Text(provider.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func availableRow(_ template: PsmithProviderTemplate) -> some View {
        HStack(spacing: 10) {
            ProviderLogo(slug: template.logoSlug, size: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(template.name)
                    .foregroundStyle(.primary)
                Text(template.driverType)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle")
                .foregroundStyle(.tint)
        }
    }

    private func logoSlug(for provider: PsmithUserModelProvider) -> String? {
        switch provider.type {
        case "anthropic": return "anthropic"
        case "google":    return "google"
        case "openai-compatible":
            return app.providers.templates
                .first(where: { $0.catalogProviderID == catalogKey(for: provider) })?
                .logoSlug
        default: return nil
        }
    }
}

// MARK: - Provider detail (push)

private struct ProviderDetailView: View {
    /// Push-time snapshot — used only as a fallback while the live
    /// row loads. Always read `provider` (the live lookup) below.
    let initialProvider: PsmithUserModelProvider
    @Environment(AppModel.self) private var app

    init(provider: PsmithUserModelProvider) {
        self.initialProvider = provider
    }

    /// Live row from the shared providers list — reflects label /
    /// base-URL / default-settings edits made while this screen is
    /// up. The frozen push-time value caused the Default Settings
    /// screen to re-seed from stale data and auto-save it back,
    /// silently reverting just-saved provider defaults.
    private var provider: PsmithUserModelProvider {
        app.providers.providers.first(where: { $0.id == initialProvider.id }) ?? initialProvider
    }
    @State private var editing: Bool = false
    @State private var modelSettingsTarget: PsmithUserModel?
    @State private var modelEditTarget: PsmithUserModel?
    @State private var testResultMessage: String?
    @State private var disableCandidate: PsmithUserModel?

    var body: some View {
        @Bindable var providers = app.providers
        List {
            Section {
                NavigationLink {
                    ProviderDefaultSettingsScreen(provider: provider)
                } label: {
                    Label("Default call settings", systemImage: "slider.horizontal.3")
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("Provider-level overrides applied below profile + model defaults.")
            }

            Section {
                if providers.enabledModels.isEmpty {
                    Text("No enabled models. Tap Discover to fetch the upstream catalog.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providers.enabledModels) { m in
                        modelRow(m)
                    }
                }
                NavigationLink {
                    ModelFormScreen(provider: provider)
                } label: {
                    Label("Add Custom Model", systemImage: "plus")
                        .foregroundStyle(.tint)
                }
            } header: {
                Text("Enabled models")
            } footer: {
                Text("Add a model by ID when it isn't in Discover yet — new releases, fine-tunes, or gateway aliases.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(provider.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    NavigationLink {
                        DiscoverModelsScreen(provider: provider)
                    } label: {
                        Label("Discover models", systemImage: "magnifyingglass")
                    }
                    NavigationLink {
                        ModelFormScreen(provider: provider)
                    } label: {
                        Label("Add custom model", systemImage: "plus")
                    }
                    Button {
                        Task { await runProviderTest() }
                    } label: {
                        Label("Test connection", systemImage: "checkmark.seal")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Provider actions")
            }
        }
        .sheet(isPresented: $editing) {
            EditProviderSheet(provider: provider)
        }
        .sheet(item: $modelSettingsTarget) { model in
            ModelDefaultSettingsSheet(provider: provider, model: model)
        }
        // Push, not a sheet: metadata editing is a full form (the
        // no-popup convention for routine flows).
        .navigationDestination(item: $modelEditTarget) { model in
            ModelFormScreen(provider: provider, mode: .edit(model))
        }
        .alert(
            "Test result",
            isPresented: Binding(
                get: { testResultMessage != nil },
                set: { if !$0 { testResultMessage = nil } }
            ),
            presenting: testResultMessage
        ) { _ in
            Button("OK") { testResultMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            "Disable model?",
            isPresented: Binding(
                get: { disableCandidate != nil },
                set: { if !$0 { disableCandidate = nil } }
            ),
            presenting: disableCandidate
        ) { m in
            Button("Disable", role: .destructive) {
                Task { await app.providers.disableModel(m.modelID) }
                disableCandidate = nil
            }
            Button("Cancel", role: .cancel) { disableCandidate = nil }
        } message: { m in
            Text("\"\(m.displayName)\" will be removed from this provider's enabled list. Conversations using it won't be able to send until you re-enable it from Discover.")
        }
        .task {
            providers.selectedID = provider.id
            await providers.selectProvider(provider.id)
        }
    }

    @ViewBuilder
    private func modelRow(_ m: PsmithUserModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.displayName)
                        .font(.callout.weight(.semibold))
                    Text(m.modelID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await app.providers.toggleModelFavorite(modelID: m.modelID) }
                } label: {
                    Image(systemName: m.favorite ? "star.fill" : "star")
                        .foregroundStyle(m.favorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m.favorite ? "Unfavorite model" : "Favorite model")
            }
            ModelMetaStrip(snapshot: m.metaSnapshot(providerLabel: provider.label))
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                disableCandidate = m
            } label: {
                Label("Disable", systemImage: "minus.circle")
            }
            Button {
                modelEditTarget = m
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.orange)
            Button {
                modelSettingsTarget = m
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .tint(.blue)
            Button {
                Task { await runModelTest(modelID: m.modelID) }
            } label: {
                Label("Test", systemImage: "checkmark.seal")
            }
            .tint(.purple)
        }
        .contextMenu {
            Button {
                modelSettingsTarget = m
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            Button {
                Task { await app.providers.toggleModelFavorite(modelID: m.modelID) }
            } label: {
                Label(m.favorite ? "Unfavorite" : "Favorite", systemImage: m.favorite ? "star.slash" : "star")
            }
            Button {
                Task { await runModelTest(modelID: m.modelID) }
            } label: {
                Label("Test", systemImage: "checkmark.seal")
            }
            Button(role: .destructive) {
                disableCandidate = m
            } label: {
                Label("Disable", systemImage: "minus.circle")
            }
        }
    }

    @MainActor
    private func runProviderTest() async {
        await app.providers.testProvider(provider.id)
        switch app.providers.providerTestStatus[provider.id] {
        case .success(let r):
            testResultMessage = r.ok
                ? "OK · discovered \(r.modelCount) model(s) in \(r.latencyMs) ms."
                : "Failed: \(r.errorMessage)"
        case .failure(let msg):
            testResultMessage = "Failed: \(msg)"
        case .testing, .idle, .none:
            testResultMessage = "Test didn't return a status."
        }
    }

    @MainActor
    private func runModelTest(modelID: String) async {
        await app.providers.testModel(providerID: provider.id, modelID: modelID)
        let key = ModelTestKey(providerID: provider.id, modelID: modelID)
        switch app.providers.modelTestStatus[key] {
        case .success(let r):
            if r.ok {
                let preview = r.sampleText.isEmpty ? "" : "\n\nReply: \(r.sampleText.prefix(200))"
                testResultMessage = "OK · \(r.latencyMs) ms · in: \(r.inputTokens) · out: \(r.outputTokens)\(preview)"
            } else {
                testResultMessage = "Failed: \(r.errorMessage)"
            }
        case .failure(let msg):
            testResultMessage = "Failed: \(msg)"
        case .testing, .idle, .none:
            testResultMessage = "Test didn't return a status."
        }
    }
}

// MARK: - Provider default-settings screen

private struct ProviderDefaultSettingsScreen: View {
    let initialProvider: PsmithUserModelProvider
    @Environment(AppModel.self) private var app

    init(provider: PsmithUserModelProvider) {
        self.initialProvider = provider
    }

    private var provider: PsmithUserModelProvider {
        app.providers.providers.first(where: { $0.id == initialProvider.id }) ?? initialProvider
    }
    @State private var draft: PsmithCallSettings = PsmithCallSettings()
    @State private var seeded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Provider-layer defaults applied at the bottom of the resolution chain. Conversations / profiles / models override field-by-field at send time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                CallSettingsForm(
                    settings: $draft,
                    inheritedSettings: nil,
                    driverType: provider.type,
                    modelCapabilities: nil,
                    showAllProviderSections: false
                )

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .navigationTitle("Default Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !seeded {
                draft = provider.defaultSettings ?? PsmithCallSettings()
                seeded = true
            }
        }
        .onDisappear {
            Task { await save() }
        }
    }

    @MainActor
    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await app.providers.updateProviderDefaultSettings(
                providerID: provider.id,
                settings: draft
            )
        } catch let err {
            // This save fires on disappear — the local error label is
            // already off-screen. Surface through the shared VM error
            // so the providers list's alert shows it.
            app.providers.error = "Saving provider defaults failed: \(PsmithError.display(err))"
        }
    }
}

// MARK: - Per-model default-settings sheet

private struct ModelDefaultSettingsSheet: View {
    let initialProvider: PsmithUserModelProvider
    let model: PsmithUserModel
    @Environment(AppModel.self) private var app

    init(provider: PsmithUserModelProvider, model: PsmithUserModel) {
        self.initialProvider = provider
        self.model = model
    }

    private var provider: PsmithUserModelProvider {
        app.providers.providers.first(where: { $0.id == initialProvider.id }) ?? initialProvider
    }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PsmithCallSettings = PsmithCallSettings()
    @State private var seeded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.displayName)
                                .font(.headline)
                            Text(model.modelID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text("Model-layer defaults applied between provider and profile in the resolution chain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    CallSettingsForm(
                        settings: $draft,
                        inheritedSettings: provider.defaultSettings,
                        driverType: provider.type,
                        modelCapabilities: model.capabilities,
                        showAllProviderSections: false
                    )

                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Model Settings")
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
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(saving)
                }
            }
            .onAppear {
                if !seeded {
                    draft = model.defaultSettings ?? PsmithCallSettings()
                    seeded = true
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @MainActor
    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await app.providers.updateModelDefaultSettings(
                providerID: provider.id,
                modelID: model.modelID,
                settings: draft
            )
            dismiss()
        } catch let err {
            error = PsmithError.display(err)
        }
    }
}

// MARK: - Edit provider sheet

private struct EditProviderSheet: View {
    let provider: PsmithUserModelProvider
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var apiKey: String = ""
    @State private var replaceAPIKey: Bool = false
    @State private var baseURL: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var seeded = false

    private var isOpenAICompatible: Bool {
        provider.type == "openai-compatible"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        ProviderLogo(slug: logoSlug, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.label)
                                .font(.callout.weight(.semibold))
                            Text(provider.type)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    TextField("Label", text: $label)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Display name shown in pickers and lists.")
                }

                Section {
                    Toggle("Replace API key", isOn: $replaceAPIKey)
                    if replaceAPIKey {
                        SecureField("New API key", text: $apiKey)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Credentials")
                } footer: {
                    Text(replaceAPIKey
                         ? "The new key replaces the existing one."
                         : "Existing API key stays in place. Toggle on to enter a new one.")
                }

                if isOpenAICompatible {
                    Section {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("API base URL")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .onAppear { seedFromProvider() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var canSave: Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        if trimmedLabel.isEmpty { return false }
        if replaceAPIKey && apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if isOpenAICompatible && baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private var logoSlug: String? {
        switch provider.type {
        case "anthropic": return "anthropic"
        case "google":    return "google"
        case "openai-compatible":
            // Match against the configured providers' templates by
            // preset id (the catalog identifier for openai-compatible).
            if let preset = provider.presetID, !preset.isEmpty {
                return app.providers.templates
                    .first(where: { $0.catalogProviderID == preset })?
                    .logoSlug
            }
            return nil
        default: return nil
        }
    }

    private func seedFromProvider() {
        guard !seeded else { return }
        label = provider.label
        baseURL = provider.baseURL ?? ""
        seeded = true
    }

    @MainActor
    private func save() async {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let labelChanged = trimmedLabel != provider.label

        // Build new config blob ONLY if the user opted into replacing
        // credentials. Sending nil for `config` leaves the stored
        // api_key alone; sending a fresh blob fully replaces it.
        var newConfig: Data?
        if replaceAPIKey || (isOpenAICompatible && baseURL != (provider.baseURL ?? "")) {
            var dict: [String: String] = [:]
            // Always include api_key — either the new one or signal
            // empty (no — empty would clear it; defensive: when only
            // base_url changed, send api_key as a sentinel "keep"
            // value via partial update path).
            if replaceAPIKey {
                dict["api_key"] = apiKey
            }
            if isOpenAICompatible {
                dict["base_url"] = baseURL
            }
            if let presetID = provider.presetID, !presetID.isEmpty {
                dict["preset_id"] = presetID
            }
            do {
                newConfig = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            } catch {
                errorMessage = "Failed to encode credentials: \(error)"
                return
            }
        }

        do {
            try await app.providers.updateProviderPartial(
                id: provider.id,
                label: labelChanged ? trimmedLabel : nil,
                config: newConfig
            )
            await app.providers.load()
            dismiss()
        } catch {
            errorMessage = PsmithError.display(error)
        }
    }
}

// MARK: - Discover models screen

private struct DiscoverModelsScreen: View {
    let provider: PsmithUserModelProvider
    @Environment(AppModel.self) private var app
    @State private var discovered: [PsmithDiscoveredModel] = []
    @State private var loading: Bool = true
    @State private var error: String?
    @State private var enabling: Set<String> = []

    var body: some View {
        // The List must stay mounted through a pull-to-refresh: swapping
        // it for a ProgressView destroys the view that owns the
        // refreshable task, which cancels the in-flight RPC and surfaces
        // "canceled" as an error. The blocking states only render when
        // there's nothing to show yet.
        Group {
            if discovered.isEmpty, loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if discovered.isEmpty, let error {
                EmptyStateView(
                    "Couldn't load models",
                    systemImage: "exclamationmark.triangle",
                    description: "\(error)"
                )
            } else if discovered.isEmpty {
                EmptyStateView(
                    "No models",
                    systemImage: "cpu",
                    description: "The provider returned no models. Check credentials or refresh."
                )
            } else {
                List {
                    if let error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    ForEach(discovered) { m in
                        let isEnabled = app.providers.enabledModels.contains { $0.modelID == m.modelID }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(m.displayName)
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                if enabling.contains(m.modelID) {
                                    ProgressView().controlSize(.small)
                                } else if isEnabled {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Button {
                                        Task { await enableOne(m) }
                                    } label: {
                                        Image(systemName: "plus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Enable model")
                                }
                            }
                            Text(m.modelID)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            ModelMetaStrip(snapshot: m.metaSnapshot(providerLabel: provider.label))
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Discover Models")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .accessibilityLabel("Refresh models")
            }
        }
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            discovered = try await app.providers.discoverModels(providerID: provider.id)
        } catch let err {
            // Cancellation isn't a failure: the view left the hierarchy or
            // the refresh gesture was superseded. Keep the current list.
            if PsmithError.isCancellation(err) { return }
            error = PsmithError.display(err)
        }
    }

    @MainActor
    private func enableOne(_ m: PsmithDiscoveredModel) async {
        enabling.insert(m.modelID)
        defer { enabling.remove(m.modelID) }
        do {
            _ = try await app.providers.enableModels(
                providerID: provider.id,
                modelIDs: [m.modelID]
            )
            // Force the enabledModels list to refresh so the row's
            // checkmark updates without needing a manual refresh.
            await app.providers.selectProvider(provider.id)
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}

// MARK: - Add provider sheet

private struct AddProviderSheet: View {
    /// Pre-selected template (from "Available" row). nil = custom
    /// openai-compatible provider — user supplies label + base URL.
    let template: PsmithProviderTemplate?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var apiKey: String = ""
    @State private var baseURL: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isOpenAICompatible: Bool {
        if let t = template { return t.driverType == "openai-compatible" }
        return true  // custom defaults to openai-compatible
    }

    private var driverType: String {
        template?.driverType ?? "openai-compatible"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let t = template {
                    Section {
                        HStack(spacing: 10) {
                            ProviderLogo(slug: t.logoSlug, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.name)
                                    .font(.callout.weight(.semibold))
                                Text(t.driverType)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    TextField("Label", text: $label)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Display name shown in pickers and lists.")
                }

                Section {
                    SecureField("API key", text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Credentials")
                } footer: {
                    if let envKey = template?.envKey {
                        Text("Sometimes set via the \(envKey) environment variable on the server.")
                    }
                }

                if isOpenAICompatible {
                    Section {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("API base URL")
                    } footer: {
                        Text("Required for openai-compatible providers.")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(template?.name ?? "Custom Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Add").fontWeight(.semibold)
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .onAppear {
                if label.isEmpty, let t = template {
                    label = t.name
                }
                if baseURL.isEmpty, let t = template, let api = t.apiBase {
                    baseURL = api
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var canSave: Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if isOpenAICompatible && baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    @MainActor
    private func save() async {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        var config: [String: String] = ["api_key": apiKey]
        if isOpenAICompatible {
            config["base_url"] = baseURL
        }
        if let presetID = template?.presetID {
            config["preset_id"] = presetID
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        } catch {
            errorMessage = "Failed to encode credentials: \(error)"
            return
        }

        do {
            _ = try await app.providers.createProvider(
                type: driverType,
                label: label,
                config: data
            )
            await app.providers.load()
            dismiss()
        } catch {
            errorMessage = PsmithError.display(error)
        }
    }
}
