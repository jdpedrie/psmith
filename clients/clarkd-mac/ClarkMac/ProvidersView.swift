import SwiftUI
import ClarkKit

// MARK: - Sidebar

/// Provider list + add button. Designed to be hosted in the main window's
/// sidebar — sibling to ConversationListView, not a sheet.
struct ProvidersMiddleColumn: View {
    @Bindable var model: ProvidersViewModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsListHeader(
                title: "Providers",
                count: model.providers.count,
                countNoun: "provider",
                onBack: onBack,
                onCreate: {
                    model.detailMode = .adding
                    Task { await model.loadTemplates() }
                },
                createDisabled: model.detailMode == .adding
            )

            if model.isLoadingProviders {
                ProgressView().padding()
                Spacer()
            } else if model.providers.isEmpty {
                EmptyStateView(
                    "No providers yet",
                    systemImage: "server.rack",
                    description: "Tap + to add the first one."
                )
            } else {
                List(model.providers, id: \.id, selection: Binding(
                    get: { model.detailMode == .adding ? nil : model.selectedID },
                    set: { id in if let id { Task { await model.selectProvider(id) } } }
                )) { provider in
                    ProviderRow(provider: provider)
                        .tag(provider.id)
                        .contextMenu {
                            Button("Edit…") {
                                Task {
                                    await model.selectProvider(provider.id)
                                    model.detailMode = .editing
                                }
                            }
                            Button("Discover models") {
                                Task {
                                    await model.selectProvider(provider.id)
                                    model.detailMode = .discovering
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                Task {
                                    await model.selectProvider(provider.id)
                                    model.showDeleteConfirm = true
                                }
                            }
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

// MARK: - Detail

/// Provider detail pane. Hosted in the main window's detail column when the
/// "Providers" settings category is active.
struct ProvidersDetail: View {
    @Bindable var model: ProvidersViewModel

    var body: some View {
        Group {
            switch model.detailMode {
            case .adding:
                AddProviderForm(model: model)
            case .addingManualModel:
                if let id = model.selectedID,
                   let provider = model.providers.first(where: { $0.id == id }) {
                    ModelEditForm(
                        formMode: .adding(provider: provider),
                        providersModel: model
                    )
                }
            case .editingModel(let modelID):
                if let id = model.selectedID,
                   let provider = model.providers.first(where: { $0.id == id }),
                   let m = model.enabledModels.first(where: { $0.modelID == modelID }) {
                    ModelEditForm(
                        formMode: .editing(model: m, provider: provider),
                        providersModel: model
                    )
                }
            case .viewing, .editing, .discovering, .settings:
                if let id = model.selectedID,
                   let provider = model.providers.first(where: { $0.id == id }) {
                    ProviderDetailPanel(provider: provider, model: model)
                } else if model.isLoadingProviders {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.providers.isEmpty {
                    EmptyStateView(
                        "No providers configured",
                        systemImage: "server.rack",
                        description: "Add a provider from the sidebar to start enabling models."
                    )
                } else {
                    EmptyStateView(
                        "No provider selected",
                        systemImage: "server.rack",
                        description: "Pick one from the sidebar."
                    )
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(model.providers.first(where: { $0.id == model.selectedID })?.label ?? "provider")\"?",
            isPresented: $model.showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelected() }
            }
        } message: {
            Text("All enabled models for this provider will also be removed. Historical messages are unaffected.")
        }
        // Surface model.error so server-side failures (e.g. an FK violation
        // when a provider is referenced by a profile/message that hasn't
        // been migrated to ON DELETE SET NULL) are visible. Silent storage
        // in `model.error` was masking failures as "delete didn't do anything".
        .alert(
            "Provider error",
            isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            ),
            presenting: model.error
        ) { _ in
            Button("OK") { model.error = nil }
        } message: { err in
            Text(err)
        }
    }
}

// MARK: - Provider row

private struct ProviderRow: View {
    let provider: ClarkUserModelProvider
    var body: some View {
        HStack(spacing: 8) {
            ProviderLogo(slug: logoSlug, size: 18)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.label).lineLimit(1)
                Text(provider.type).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Native drivers map their type directly to a logo slug; openai-
    /// compatible providers carry the slug in `presetID`. Returns nil
    /// when the provider is custom or otherwise unmapped — ProviderLogo
    /// then renders the generic globe placeholder.
    private var logoSlug: String? {
        switch provider.type {
        case "anthropic": return "anthropic"
        case "google":    return "gemini"
        case "openai-compatible":
            return provider.presetID
        default:
            return nil
        }
    }
}

// MARK: - Provider detail panel (viewing / editing / discovering)

private struct ProviderDetailPanel: View {
    let provider: ClarkUserModelProvider
    @Bindable var model: ProvidersViewModel

    var body: some View {
        panelContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — swaps to the edit form when editing, otherwise renders
            // the provider name, type, Edit + Delete buttons, and the tab bar.
            switch model.detailMode {
            case .editing:
                EditProviderForm(provider: provider, model: model)
                Divider()
            default:
                ProviderHeader(provider: provider, model: model)
                Divider()
                tabBar
                Divider()
            }

            Group {
                switch model.detailMode {
                case .discovering:
                    if let id = model.selectedID,
                       let p = model.providers.first(where: { $0.id == id }) {
                        DiscoverModelsInline(provider: p, model: model)
                    }
                case .settings:
                    ProviderDefaultSettingsTab(provider: provider, model: model)
                default:
                    ModelsList(model: model)
                }
            }
            // Default alignment is .center, which causes the form's leading
            // edge to render off-screen-left when its intrinsic content is
            // wider than the column. .topLeading anchors the form so any
            // overflow extends to the right (clipped properly) instead of
            // bleeding behind the column divider.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Full-width tab bar below the header — picks between viewing the
    /// provider's enabled models, discovering new ones, and editing the
    /// provider-level default call settings.
    @ViewBuilder
    private var tabBar: some View {
        Picker("", selection: tabBinding) {
            Text("Enabled Models").tag(ProvidersDetailMode.viewing)
            Text("Discover Models").tag(ProvidersDetailMode.discovering)
            Text("Default Settings").tag(ProvidersDetailMode.settings)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var tabBinding: Binding<ProvidersDetailMode> {
        Binding(
            get: {
                switch model.detailMode {
                case .discovering: return .discovering
                case .settings:    return .settings
                default:           return .viewing
                }
            },
            set: { model.detailMode = $0 }
        )
    }
}

// MARK: - Provider header (name + type | Test + Edit + Delete buttons)

private struct ProviderHeader: View {
    let provider: ClarkUserModelProvider
    @Bindable var model: ProvidersViewModel

    private var testStatus: ProviderTestStatus {
        model.providerTestStatus[provider.id] ?? .idle
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                // Truncate from the tail so "OpenRouter" stays readable even
                // when the column is narrow (the alternative was the title
                // getting clipped on the leading edge — silently — when the
                // trailing buttons + test chip ate the row's horizontal budget).
                Text(provider.label)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(provider.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Higher layoutPriority keeps the title VStack from being squeezed
            // to zero width by the test-chip + button cluster.
            .layoutPriority(1)
            Spacer(minLength: 8)
            ProviderTestControl(provider: provider, model: model)
            GlassCircleButton(
                systemImage: "pencil",
                action: { model.detailMode = .editing },
                help: "Edit"
            )
            GlassCircleButton(
                systemImage: "trash",
                action: { model.showDeleteConfirm = true },
                help: "Delete provider",
                tint: .red,
                disabled: model.isDeleting
            )
        }
        .padding(.horizontal, 12)
        .frame(height: paneHeaderHeight)
    }
}

/// Test affordance for a provider. Renders a glass button when idle, a
/// spinner-bearing button while testing, and a glass result chip on
/// success/failure. Clicking the chip retests so users can re-verify after
/// editing config without first reaching for a separate "reset" affordance.
private struct ProviderTestControl: View {
    let provider: ClarkUserModelProvider
    @Bindable var model: ProvidersViewModel
    @Environment(\.theme) private var theme

    private var status: ProviderTestStatus {
        model.providerTestStatus[provider.id] ?? .idle
    }

    var body: some View {
        Button(action: runTest) {
            switch status {
            case .idle:
                Label("Test", systemImage: "bolt.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing…").font(.caption)
                }
            case .success(let result) where result.ok:
                Label("\(result.modelCount) models · \(result.latencyMs)ms",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
            case .success(let result):
                // ok=false comes back as .success with the failure body —
                // render orange like other failures.
                Label(failureLabel(result.errorMessage),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .lineLimit(1)
            case .failure(let msg):
                Label(failureLabel(msg), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .controlSize(.small)
        .buttonStyle(.glass)
        .tint(tintForStatus)
        .disabled(isTesting)
        .help(helpText)
    }

    private var isTesting: Bool {
        if case .testing = status { return true }
        return false
    }

    private var tintForStatus: Color {
        switch status {
        case .success(let r) where r.ok: return .green
        case .success: return .orange
        case .failure: return .orange
        default: return theme.accent
        }
    }

    private var helpText: String {
        switch status {
        case .idle:    return "Verify provider auth + reachability"
        case .testing: return "Testing…"
        case .success(let r) where r.ok:
            return "Reachable · \(r.modelCount) models discovered in \(r.latencyMs)ms. Click to re-test."
        case .success(let r):
            return "Test failed: \(r.errorMessage). Click to retry."
        case .failure(let m):
            return "Test failed: \(m). Click to retry."
        }
    }

    private func failureLabel(_ s: String) -> String {
        s.isEmpty ? "Failed" : s
    }

    private func runTest() {
        Task { await model.testProvider(provider.id) }
    }
}

// MARK: - Models list

private struct ModelsList: View {
    @Bindable var model: ProvidersViewModel

    var body: some View {
        if model.isLoadingDetail {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.enabledModels.isEmpty {
            EmptyStateView(
                "No models enabled",
                systemImage: "cpu",
                description: "Switch to **Discover** to find and enable some."
            )
        } else {
            List(model.enabledModels) { m in
                ModelRow(
                    model: m,
                    providersModel: model,
                    onDisable: { Task { await model.disableModel(m.modelID) } },
                    onToggleFavorite: { Task { await model.toggleModelFavorite(modelID: m.modelID) } }
                )
            }
            .listStyle(.inset)
        }
    }
}

private struct ModelRow: View {
    let model: ClarkUserModel
    @Bindable var providersModel: ProvidersViewModel
    let onDisable: () -> Void
    let onToggleFavorite: () -> Void
    @State private var showConfirm = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName).fontWeight(.medium).lineLimit(1)
                ModelMetaStrip(
                    contextWindow: model.contextWindow,
                    pricing: model.pricing,
                    knowledgeCutoff: model.knowledgeCutoff,
                    capabilities: model.capabilities
                )
                // Inline test result chip — sits below the meta strip so it
                // doesn't fight for horizontal real estate. Hidden when idle.
                ModelTestResultChip(
                    status: providersModel.modelTestStatus[
                        ModelTestKey(providerID: model.providerID, modelID: model.modelID)
                    ] ?? .idle
                )
            }
            Spacer()
            // Gear → swap the detail pane to the unified model edit form.
            // Same screen as "Add custom model"; pre-populates from the row.
            Button {
                providersModel.detailMode = .editingModel(model.modelID)
            } label: {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit model")
            ModelTestButton(model: model, providersModel: providersModel)
            Button(action: onToggleFavorite) {
                Image(systemName: model.favorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.favorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(model.favorite ? "Unfavorite" : "Mark as favorite")
            Button {
                showConfirm = true
            } label: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Disable model")
            .confirmationDialog(
                "Disable \"\(model.displayName)\"?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button("Disable", role: .destructive) { onDisable() }
            } message: {
                Text("You can re-enable it via discovery at any time.")
            }
        }
        .padding(.vertical, 3)
    }

    /// Driver type of the parent provider — passed into CallSettingsForm to
    /// pick the right extension block.
    private var providerType: String {
        providersModel.providers.first(where: { $0.id == model.providerID })?.type ?? "anthropic"
    }
}

/// Compact inline trigger for "Test this model". Renders as a small glass
/// play button when idle and a glass spinner while in flight. The result
/// itself is rendered by `ModelTestResultChip` under the model name, so this
/// button stays the same width across states (no layout jitter).
private struct ModelTestButton: View {
    let model: ClarkUserModel
    @Bindable var providersModel: ProvidersViewModel

    private var key: ModelTestKey {
        ModelTestKey(providerID: model.providerID, modelID: model.modelID)
    }

    private var status: ModelTestStatus {
        providersModel.modelTestStatus[key] ?? .idle
    }

    private var isTesting: Bool {
        if case .testing = status { return true }
        return false
    }

    var body: some View {
        Button {
            Task { await providersModel.testModel(providerID: model.providerID, modelID: model.modelID) }
        } label: {
            ZStack {
                Color.clear
                if isTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(isTesting)
        .help(helpText)
    }

    private var helpText: String {
        switch status {
        case .idle:    return "Send a tiny prompt to verify this model responds"
        case .testing: return "Testing…"
        case .success(let r) where r.ok:
            return "Responded in \(r.latencyMs)ms (\(r.outputTokens) output tokens). Click to re-test."
        case .success(let r):
            return "Failed: \(r.errorMessage). Click to retry."
        case .failure(let m):
            return "Failed: \(m). Click to retry."
        }
    }
}

/// Inline result chip for a single model test. Hidden when idle/testing
/// (the button itself communicates those states); shown as a small glass
/// capsule on completion. Same shape on success and failure, only tint and
/// icon differ.
private struct ModelTestResultChip: View {
    let status: ModelTestStatus

    var body: some View {
        switch status {
        case .idle, .testing:
            EmptyView()
        case .success(let r) where r.ok:
            chip(
                icon: "checkmark.circle.fill",
                text: successText(r),
                tint: .green
            )
        case .success(let r):
            chip(
                icon: "exclamationmark.triangle.fill",
                text: r.errorMessage.isEmpty ? "Failed" : r.errorMessage,
                tint: .orange
            )
        case .failure(let m):
            chip(
                icon: "exclamationmark.triangle.fill",
                text: m.isEmpty ? "Failed" : m,
                tint: .orange
            )
        }
    }

    private func successText(_ r: ClarkModelTestResult) -> String {
        var bits: [String] = []
        bits.append("\(r.latencyMs)ms")
        if r.outputTokens > 0 {
            bits.append("\(r.outputTokens) tokens")
        }
        if !r.sampleText.isEmpty {
            bits.append(r.sampleText)
        }
        return bits.joined(separator: " · ")
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .glassEffect(.regular.tint(tint.opacity(0.18)), in: .capsule)
    }
}

/// Maps a model's pricing into [$, $$, $$$, $$$$] based on output cost per
/// million tokens — output dominates real-world spend. Returns nil when
/// pricing isn't known.
private func costBucket(_ pricing: ClarkModelPricing?) -> String? {
    guard let outp = pricing?.outputPerMillion, outp > 0 else { return nil }
    switch outp {
    case ..<3:    return "$"
    case 3..<15:  return "$$"
    case 15..<50: return "$$$"
    default:      return "$$$$"
    }
}

// MARK: - Add provider (inline)

/// Drives the AddProviderForm's "what kind of provider are we creating"
/// state: a catalog template (Anthropic / Groq / etc.) or a fully-custom
/// configuration (user picks the driver type, label, base URL, api key from
/// scratch). The custom case is for self-hosted endpoints, forks of known
/// providers with a different URL, or any openai-compatible service that
/// hasn't been catalogued.
private enum AddProviderSelection: Equatable {
    case template(ClarkProviderTemplate)
    case custom
}

/// Inline form replacing the old AddProviderSheet. Lives in the providers
/// detail column when `detailMode == .adding`.
private struct AddProviderForm: View {
    @Bindable var model: ProvidersViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var selection: AddProviderSelection?
    @State private var label = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    /// Driver type when the user is creating a custom provider. Defaults to
    /// `openai-compatible` since that's the broadest fit.
    @State private var customDriverType: String = "openai-compatible"
    @State private var isCreating = false
    @State private var formError: String?

    private var isOpenAICompatibleSelection: Bool {
        switch selection {
        case .template(let t): return t.driverType == "openai-compatible"
        case .custom:          return customDriverType == "openai-compatible"
        case nil:              return false
        }
    }

    /// The driver type that will actually be submitted. Mirrors `selection` —
    /// for templates it's the template's own driver, for custom it's the
    /// segmented-picker choice.
    private var effectiveDriverType: String {
        switch selection {
        case .template(let t): return t.driverType
        case .custom:          return customDriverType
        case nil:              return ""
        }
    }

    private var canCreate: Bool {
        guard selection != nil else { return false }
        if label.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if apiKey.isEmpty { return false }
        if isOpenAICompatibleSelection && baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("Add provider")
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
                    if isCreating { ProgressView().controlSize(.small) }
                    else { Text("Create") }
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .frame(height: paneHeaderHeight)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if selection == nil {
                        templatePicker
                    } else {
                        selectedTemplateRow
                        credentialsSection
                    }
                    if let formError {
                        Text(formError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Full grid shown until a template is picked. The "Custom" tile is
    /// pinned at the top so users searching for a self-hosted-or-similar
    /// path don't have to scroll past 70+ catalog templates first.
    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Pick a template")
            // Standalone Custom tile — full row width, distinct visual style
            // (dashed border + plus icon) so it doesn't blend in with the
            // catalog grid below.
            CustomProviderTile {
                selection = .custom
                if label.isEmpty { label = "Custom provider" }
                customDriverType = "openai-compatible"
            }
            if model.templates.isEmpty {
                ProgressView().controlSize(.small)
                    .padding(.top, 4)
            } else {
                // VGrid (not LazyVGrid) deliberately — LazyVGrid mis-renders
                // hit areas on the first row when the form first appears
                // (clicks on the upper ~25px land on no button). The catalog
                // is bounded (~70 templates) so non-lazy is fine here, and
                // the eager layout fixes the click-hole reliably.
                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(templateRows, id: \.self) { row in
                        GridRow {
                            ForEach(row, id: \.id) { t in
                                TemplatePill(template: t, isSelected: false) {
                                    selection = .template(t)
                                    if label.isEmpty { label = t.name }
                                    if baseURL.isEmpty { baseURL = t.apiBase ?? "" }
                                }
                            }
                            // Pad the trailing column on the last row so the
                            // single tile doesn't span the full width.
                            if row.count == 1 {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Catalog templates packed into rows of 2. Two columns mirror the prior
    /// LazyVGrid `.adaptive(minimum: 200, maximum: 280)` density — wider columns
    /// would look stretched, narrower columns lose readable label space.
    private var templateRows: [[ClarkProviderTemplate]] {
        let columns = 2
        var rows: [[ClarkProviderTemplate]] = []
        var current: [ClarkProviderTemplate] = []
        for t in model.templates {
            current.append(t)
            if current.count == columns {
                rows.append(current)
                current = []
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// Compact summary of the chosen template (or "Custom"), with a "Change"
    /// button to reopen the picker. Stays at the top of the form so it's
    /// immediately clear what's being added.
    @ViewBuilder
    private var selectedTemplateRow: some View {
        if let sel = selection {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Template")
                HStack(alignment: .center, spacing: 12) {
                    if case .template(let t) = sel {
                        ProviderLogo(slug: t.logoSlug, size: 28)
                            .foregroundStyle(.primary)
                    } else {
                        ProviderLogo(slug: nil, size: 28)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        switch sel {
                        case .template(let t):
                            Text(t.name).fontWeight(.semibold)
                            Text(t.driverType).font(.caption2).foregroundStyle(.secondary)
                        case .custom:
                            Text("Custom provider").fontWeight(.semibold)
                            Text("Pick a driver type and configure manually")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Change") { selection = nil }
                        .buttonStyle(.glass)
                }
                .padding(10)
                .background(theme.accent.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.accent.opacity(0.4))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Credentials")
            // For custom providers the user picks the driver type up-front;
            // for templates the driver is locked-in by the catalog row.
            if case .custom = selection {
                CredField("Driver type") {
                    Picker("", selection: $customDriverType) {
                        Text("Anthropic").tag("anthropic")
                        Text("OpenAI-compatible").tag("openai-compatible")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            CredField("Label") {
                TextField("Display name", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            CredField(
                "API key",
                hint: templateEnvKeyHint
            ) {
                SecureField("Paste key here", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            if isOpenAICompatibleSelection {
                CredField(
                    "Base URL",
                    hint: customBaseURLHint
                ) {
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var templateEnvKeyHint: String? {
        if case .template(let t) = selection {
            return t.envKey.map { "env: \($0)" }
        }
        return nil
    }

    private var customBaseURLHint: String? {
        if case .custom = selection {
            return "Required for OpenAI-compatible drivers (e.g. http://localhost:9999/v1)"
        }
        return nil
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func save() async {
        guard let sel = selection else { return }
        isCreating = true; formError = nil
        defer { isCreating = false }
        do {
            var dict: [String: String] = ["api_key": apiKey]
            let driverType = effectiveDriverType
            if driverType == "openai-compatible" {
                let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { dict["base_url"] = trimmed }
                // Templates carry a catalog hint that enriches discovery;
                // custom providers don't unless the user explicitly picks one
                // (deferred — could add a "catalog enrichment" sub-field later).
                if case .template(let t) = sel, !t.catalogProviderID.isEmpty {
                    dict["catalog_provider_id"] = t.catalogProviderID
                }
                // preset_id pins the openai driver's Quirks overlay
                // (xAI's x-grok-conv-id header, future Ollama /api/tags
                // discovery, etc.). Always present on preset templates;
                // never on Custom or non-openai-compatible templates.
                if case .template(let t) = sel, let pid = t.presetID, !pid.isEmpty {
                    dict["preset_id"] = pid
                }
            }
            let config = try JSONSerialization.data(withJSONObject: dict)
            let provider = try await model.createProvider(
                type: driverType,
                label: label.trimmingCharacters(in: .whitespaces),
                config: config
            )
            await model.selectProvider(provider.id)
            // selectProvider sets detailMode=.viewing; nothing more to do.
        } catch {
            formError = error.localizedDescription
        }
    }
}

/// Pinned tile at the top of the templates picker that opens the form in
/// custom-provider mode. Visual: dashed accent border + plus icon, distinct
/// from the catalog's solid-border tiles so it reads as a different kind of
/// affordance.
private struct CustomProviderTile: View {
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom provider")
                        .fontWeight(.semibold)
                    Text("Configure manually — for self-hosted or uncatalogued endpoints")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // contentShape forces the entire frame (including transparent
            // padding region) to be hittable — without this, hit-testing
            // misses the gaps between the icon and the text.
            .contentShape(Rectangle())
            .background(theme.accent.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        theme.accent.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Edit provider (inline form, replaces header when editing)

private struct EditProviderForm: View {
    let provider: ClarkUserModelProvider
    @Bindable var model: ProvidersViewModel

    @State private var label: String = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    /// nil = "don't touch catalog_provider_id"; "" = clear it; non-empty = set it.
    @State private var catalogChoice: String? = nil
    @State private var isSaving = false
    @State private var formError: String?

    private var isOpenAI: Bool { provider.type == "openai-compatible" }

    private var openAITemplates: [ClarkProviderTemplate] {
        model.templates.filter { $0.driverType == "openai-compatible" }
    }

    private var canSave: Bool {
        !isSaving && !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("Edit provider")
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
                    else { Text("Save") }
                }
                .controlSize(.small)
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .frame(height: paneHeaderHeight)

            Divider()

            VStack(alignment: .leading, spacing: 12) {

            CredField("Label") {
                TextField("Display name", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            CredField("New API key", hint: "Leave blank to keep current key") {
                SecureField("Paste to replace", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            if isOpenAI {
                CredField("Base URL", hint: "Leave blank to keep current URL") {
                    TextField("https://...", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                CredField(
                    "Catalog",
                    hint: "Used to enrich models with pricing & metadata from models.dev. Leave unchanged to preserve."
                ) {
                    Menu {
                        Button("(unchanged)") { catalogChoice = nil }
                        Button("(no catalog)") { catalogChoice = "" }
                        Divider()
                        ForEach(openAITemplates) { t in
                            Button(t.name) { catalogChoice = t.catalogProviderID }
                        }
                    } label: {
                        Text(catalogLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if let formError {
                Text(formError).font(.caption).foregroundStyle(.red)
            }
            }
            .padding(12)
        }
        .onAppear {
            label = provider.label
            // Pre-fill base_url so the user can see the current endpoint
            // and tweak it instead of re-typing from memory. Empty placeholder
            // preserved for non-openai providers (no base_url surfaced).
            baseURL = provider.baseURL ?? ""
            Task { await model.loadTemplates() }
        }
    }

    private var catalogLabel: String {
        switch catalogChoice {
        case nil:    return "(unchanged)"
        case "":     return "(no catalog)"
        case let id?:
            return openAITemplates.first(where: { $0.catalogProviderID == id })?.name ?? id
        }
    }

    private func save() async {
        isSaving = true; formError = nil
        defer { isSaving = false }
        var dict: [String: String] = [:]
        if !apiKey.isEmpty  { dict["api_key"]  = apiKey  }
        if !baseURL.isEmpty { dict["base_url"] = baseURL }
        // catalogChoice == nil means "preserve", so omit. Otherwise we set the
        // value (possibly empty string to clear).
        if let cid = catalogChoice {
            dict["catalog_provider_id"] = cid
        }
        let config = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        do {
            try await model.updateProvider(
                id: provider.id,
                label: label.trimmingCharacters(in: .whitespaces),
                config: config
            )
            model.detailMode = .viewing
        } catch {
            formError = error.localizedDescription
        }
    }
}

// MARK: - Discover models (inline list, replaces models list when discovering)

private struct DiscoverModelsInline: View {
    let provider: ClarkUserModelProvider
    @Bindable var model: ProvidersViewModel

    @State private var discovered: [ClarkDiscoveredModel] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isEnabling = false
    @State private var inlineError: String?
    @State private var searchText = ""

    private var filtered: [ClarkDiscoveredModel] {
        guard !searchText.isEmpty else { return discovered }
        let q = searchText.lowercased()
        return discovered.filter {
            $0.modelID.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar + "Add custom model" affordance — sits in the
            // discover tab header so users who can't find a model in the
            // catalog/discovery list have a clear next step right there.
            HStack {
                TextField("Search models…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                if isLoading { ProgressView().controlSize(.small) }
                Button {
                    model.detailMode = .addingManualModel
                } label: {
                    Label("Add custom model", systemImage: "plus")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .buttonStyle(.glass)
                .help("Add a manually-described model — for private fine-tunes or models the provider doesn't list via /v1/models.")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            // List
            if let inlineError {
                Text(inlineError).foregroundStyle(.red).font(.caption).padding()
            } else if isLoading {
                ProgressView().padding(40)
            } else if filtered.isEmpty {
                EmptyStateView(
                    discovered.isEmpty ? "No models found" : "No results",
                    systemImage: "cpu",
                    description: discovered.isEmpty ? nil : "Try a different search term."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { m in
                            DiscoveredModelRow(
                                model: m,
                                isSelected: selected.contains(m.modelID)
                            ) {
                                if selected.contains(m.modelID) { selected.remove(m.modelID) }
                                else { selected.insert(m.modelID) }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }

            PaneFooter {
                if !discovered.isEmpty {
                    Text("\(selected.count) of \(discovered.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await commit() }
                } label: {
                    if isEnabling { ProgressView().controlSize(.small) }
                    else { Text("Enable selected") }
                }
                .buttonStyle(.glassProminent)
                .disabled(selected.isEmpty || isEnabling)
                .keyboardShortcut(.defaultAction)
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true; inlineError = nil
        do {
            discovered = try await model.discoverModels(providerID: provider.id)
            selected = Set(discovered.filter(\.alreadyEnabled).map(\.modelID))
        } catch {
            inlineError = error.localizedDescription
        }
        isLoading = false
    }

    private func commit() async {
        isEnabling = true
        defer { isEnabling = false }
        do {
            _ = try await model.enableModels(providerID: provider.id, modelIDs: Array(selected))
            model.detailMode = .viewing
        } catch {
            inlineError = error.localizedDescription
        }
    }
}

private struct DiscoveredModelRow: View {
    let model: ClarkDiscoveredModel
    let isSelected: Bool
    let onToggle: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? theme.accent : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName).fontWeight(.medium).lineLimit(1)
                        if model.alreadyEnabled {
                            EnabledBadge()
                        }
                    }
                    ModelMetaStrip(
                        contextWindow: model.contextWindow,
                        pricing: model.pricing,
                        knowledgeCutoff: nil,  // discovery rows don't carry it
                        capabilities: model.capabilities
                    )
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}

private struct EnabledBadge: View {
    var body: some View {
        Text("enabled")
            .font(.caption2)
            .foregroundStyle(.green)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.green.opacity(0.12))
            .clipShape(Capsule())
    }
}

/// Compact metadata strip for a model row: ctx · cost-bucket · cutoff ·
/// capability icons. Each chip is fixed-width-natural so they never wrap;
/// capabilities are condensed to single SF Symbols to keep the strip thin.
/// Every chip and icon has a tooltip with the full detail.
private struct ModelMetaStrip: View {
    let contextWindow: Int32?
    let pricing: ClarkModelPricing?
    let knowledgeCutoff: String?
    let capabilities: ClarkModelCapabilities?

    var body: some View {
        HStack(spacing: 6) {
            if let ctx = contextWindow {
                metaChip(ctxLabel(ctx), help: "Context window: \(ctx.formatted()) tokens")
            }
            if let bucket = costBucket(pricing) {
                metaChip(bucket, .orange, help: pricingTooltip)
            }
            if let cutoff = knowledgeCutoff, !cutoff.isEmpty {
                metaChip(cutoff, help: "Knowledge cutoff: \(cutoff)")
            }
            if let caps = capabilities {
                HStack(spacing: 4) {
                    if caps.thinking      { capabilityIcon("brain",                .purple, "Thinking — model exposes its chain-of-thought.") }
                    if caps.vision        { capabilityIcon("eye",                  .blue,   "Vision — accepts images as input.") }
                    if caps.toolUse       { capabilityIcon("wrench.adjustable",    .teal,   "Tool use — supports function calling.") }
                    if caps.promptCaching { capabilityIcon("tray.full",            .green,  "Prompt caching — reuses cached prefixes for cheaper repeat calls.") }
                }
                .padding(.leading, 2)
            }
        }
    }

    private func ctxLabel(_ n: Int32) -> String {
        n >= 1_000_000 ? "\(n / 1_000_000)M"
            : n >= 1_000 ? "\(n / 1_000)K"
            : "\(n)"
    }

    /// Builds a multi-line tooltip with input/output (and cache) per-million prices.
    private var pricingTooltip: String {
        guard let p = pricing else { return "" }
        var lines: [String] = []
        if let inp = p.inputPerMillion, inp > 0 {
            lines.append("Input: \(formatPrice(inp))/M tokens")
        }
        if let outp = p.outputPerMillion, outp > 0 {
            lines.append("Output: \(formatPrice(outp))/M tokens")
        }
        if let cr = p.cacheReadPerMillion, cr > 0 {
            lines.append("Cache read: \(formatPrice(cr))/M tokens")
        }
        if let cw = p.cacheWritePerMillion, cw > 0 {
            lines.append("Cache write: \(formatPrice(cw))/M tokens")
        }
        return lines.joined(separator: "\n")
    }

    private func formatPrice(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 1   { return String(format: "$%.2f", v) }
        return String(format: "$%.3f", v)
    }

    private func metaChip(_ label: String, _ color: Color = .secondary, help: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .help(help)
    }

    private func capabilityIcon(_ name: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: name)
            .font(.caption2)
            .foregroundStyle(color)
            .help(help)
    }
}

// MARK: - Template pill (used in AddProviderForm)

private struct TemplatePill: View {
    let template: ClarkProviderTemplate
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ProviderLogo(slug: template.logoSlug, size: 22)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(template.driverType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(10)
            // maxWidth: .infinity expands the label to fill the grid cell so
            // the entire visible tile is one hit target. Without it the
            // HStack's intrinsic width stops short of the column boundary
            // and clicks on the right edge land on no view.
            .frame(maxWidth: .infinity, alignment: .leading)
            // contentShape extends hit-testing to the full padded frame
            // including the transparent .background(Color.clear) area.
            // Without this, clicks on the un-text part of the tile (i.e. the
            // padding around "302.AI") pass through to whatever's underneath
            // — which is why the upper edge of first-row tiles read as dead.
            .contentShape(Rectangle())
            .background(isSelected ? theme.accent.opacity(0.10) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected
                            ? AnyShapeStyle(theme.accent.opacity(0.4))
                            : AnyShapeStyle(.separator)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared field row

private struct CredField<Content: View>: View {
    let title: String
    let hint: String?
    let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                content
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 90)
            }
        }
    }
}

// MARK: - Provider default-settings tab

/// "Default Settings" tab on the provider detail pane. Renders the shared
/// `CallSettingsForm` bound to a local draft seeded from the provider's
/// existing `defaultSettings`. Auto-saves on dismiss (when the user
/// switches tabs or selects a different provider) — same pattern as
/// `ConversationSettingsView`.
private struct ProviderDefaultSettingsTab: View {
    let provider: ClarkUserModelProvider
    @Bindable var model: ProvidersViewModel
    @State private var draft = ClarkCallSettings()
    @State private var seeded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerNote
                CallSettingsForm(
                    settings: $draft,
                    inheritedSettings: nil,
                    driverType: provider.type,
                    modelCapabilities: nil
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // Seed once per appearance — re-seeding on every .onAppear would
            // clobber an in-flight edit if the parent re-renders the same
            // provider for unrelated reasons.
            if !seeded {
                draft = provider.defaultSettings ?? ClarkCallSettings()
                seeded = true
            }
        }
        .onDisappear {
            // Auto-save on dismiss. Skip the call when the draft matches what's
            // already persisted — avoids a no-op round-trip every tab switch.
            let original = provider.defaultSettings ?? ClarkCallSettings()
            guard draft != original else { return }
            let providerID = provider.id
            let settings = draft
            let m = model
            Task { try? await m.updateProviderDefaultSettings(providerID: providerID, settings: settings) }
        }
    }

    private var headerNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Provider defaults")
                .font(.headline)
            Text("Bottom layer of the resolution chain — any field set here is used unless a per-model, profile, or conversation override is set. Changes auto-save when you leave this tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Unified model edit form (replaces both popovers)

/// Mode for the unified model edit screen. `.adding` starts blank and
/// commits via AddManualModel; `.editing` pre-populates from an existing
/// row and commits the per-model `default_settings` layer via UpdateUserModel.
/// Metadata fields (id, limits, pricing, capabilities, modalities, cutoff)
/// are read-only when editing — the current backend only exposes
/// `default_settings` as a mutable field on existing rows.
enum ModelEditMode {
    case adding(provider: ClarkUserModelProvider)
    case editing(model: ClarkUserModel, provider: ClarkUserModelProvider)

    var provider: ClarkUserModelProvider {
        switch self {
        case .adding(let p):       return p
        case .editing(_, let p):   return p
        }
    }

    var existingModel: ClarkUserModel? {
        if case .editing(let m, _) = self { return m }
        return nil
    }
}

/// Full-pane add/edit screen for a model row. Replaces the gear-button and
/// "+ Add custom model" popovers with a screen-style flow that mirrors the
/// provider edit/add pattern (header + Cancel/Save right-aligned, body
/// scrolls underneath). Identity/metadata fields are pre-populated and
/// disabled when editing — the existing UpdateUserModel RPC only mutates
/// `default_settings`, so the form is honest about what is editable.
private struct ModelEditForm: View {
    let formMode: ModelEditMode
    @Bindable var providersModel: ProvidersViewModel

    @State private var modelID: String = ""
    @State private var displayName: String = ""
    @State private var contextWindowText: String = ""
    @State private var maxOutputTokensText: String = ""
    @State private var inputPriceText: String = ""
    @State private var outputPriceText: String = ""
    @State private var cacheReadPriceText: String = ""
    @State private var cacheWritePriceText: String = ""
    @State private var modalities: Set<String> = ["text"]
    @State private var capStreaming = true
    @State private var capThinking = false
    @State private var capToolUse = false
    @State private var capVision = false
    @State private var capPromptCaching = false
    @State private var knowledgeCutoffEnabled = false
    @State private var knowledgeCutoffDate = Date()
    @State private var defaultSettings = ClarkCallSettings()
    @State private var defaultSettingsExpanded = false
    @State private var isSaving = false
    @State private var formError: String?
    @State private var seeded = false

    private static let modalityChoices: [(key: String, label: String, systemImage: String)] = [
        ("text",  "Text",  "text.alignleft"),
        ("image", "Image", "photo"),
        ("audio", "Audio", "waveform"),
        ("pdf",   "PDF",   "doc.richtext"),
        ("video", "Video", "video"),
    ]

    private var isEditing: Bool { formMode.existingModel != nil }
    private var providerType: String { formMode.provider.type }
    private var provider: ClarkUserModelProvider { formMode.provider }

    private var canSave: Bool {
        // displayName is required in both modes (it's the row's user-visible
        // label); modelID is required only when adding (it's the row key
        // and pre-populated/locked when editing).
        if isSaving { return false }
        if !isEditing && modelID.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // GeometryReader gives us the column's actual width — without it
            // ScrollView's preferred-size negotiation with wide internal
            // content (segmented pickers in the embedded CallSettingsForm)
            // causes the inner VStack to render at its *intrinsic* width with
            // the column's left edge clipping the leading characters of
            // every label. Constraining the VStack to the geometry width
            // forces it to shrink, so labels (and their padding) are
            // honored relative to the column's left edge.
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        introCaption
                        identitySection
                        limitsSection
                        pricingSection
                        modalitiesSection
                        capabilitiesSection
                        cutoffSection
                        defaultSettingsSection
                        if let formError {
                            Text(formError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                    }
                    .padding(16)
                    .frame(width: geo.size.width, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { seedFromExistingIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(isEditing ? "Edit model" : "Add custom model")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button("Cancel") {
                providersModel.detailMode = .viewing
            }
            .controlSize(.small)
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            Button {
                Task { await save() }
            } label: {
                if isSaving { ProgressView().controlSize(.small) }
                else { Text(isEditing ? "Save" : "Add model") }
            }
            .controlSize(.small)
            .buttonStyle(.glassProminent)
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .frame(height: paneHeaderHeight)
    }

    @ViewBuilder
    private var introCaption: some View {
        if isEditing {
            Text("Edit any field. The model ID is the wire identifier and is locked — change it by removing the row and adding a new one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Manually describe a model on \"\(provider.label)\" — for private fine-tunes, renamed-but-real models, or anything the provider doesn't list via discovery.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        sectionCard("Identity") {
            VStack(alignment: .leading, spacing: 10) {
                CredField("Model ID", hint: isEditing
                          ? "Locked — wire identifier; change it by removing the row and adding a new one"
                          : "Wire identifier sent to the provider — e.g. gpt-mystery") {
                    TextField("gpt-mystery", text: $modelID)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .disabled(isEditing)
                }
                CredField("Display name") {
                    TextField("GPT Mystery", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var limitsSection: some View {
        sectionCard("Limits") {
            HStack(alignment: .top, spacing: 12) {
                CredField("Context window", hint: "Tokens (optional)") {
                    TextField("128000", text: $contextWindowText)
                        .textFieldStyle(.roundedBorder)
                }
                CredField("Max output", hint: "Tokens (optional)") {
                    TextField("8192", text: $maxOutputTokensText)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var pricingSection: some View {
        sectionCard("Pricing — USD per million tokens (all optional)") {
            VStack(alignment: .leading, spacing: 8) {
                pricingRow("Input",       $inputPriceText)
                pricingRow("Output",      $outputPriceText)
                pricingRow("Cache read",  $cacheReadPriceText)
                pricingRow("Cache write", $cacheWritePriceText)
            }
        }
    }

    private func pricingRow(_ title: String, _ binding: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: 100, alignment: .leading)
                .foregroundStyle(.secondary)
            TextField("0.00", text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var modalitiesSection: some View {
        sectionCard("Modalities") {
            HStack(spacing: 6) {
                ForEach(Self.modalityChoices, id: \.key) { choice in
                    ModalityChip(
                        label: choice.label,
                        systemImage: choice.systemImage,
                        isOn: modalities.contains(choice.key)
                    ) {
                        if modalities.contains(choice.key) {
                            modalities.remove(choice.key)
                        } else {
                            modalities.insert(choice.key)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var capabilitiesSection: some View {
        sectionCard("Capabilities") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Streaming",       isOn: $capStreaming)
                Toggle("Thinking",        isOn: $capThinking)
                Toggle("Tool use",        isOn: $capToolUse)
                Toggle("Vision",          isOn: $capVision)
                Toggle("Prompt caching",  isOn: $capPromptCaching)
            }
            .toggleStyle(.checkbox)
        }
    }

    private var cutoffSection: some View {
        sectionCard("Knowledge cutoff") {
            HStack(spacing: 10) {
                Toggle("Set", isOn: $knowledgeCutoffEnabled)
                    .toggleStyle(.checkbox)
                if knowledgeCutoffEnabled {
                    DatePicker("", selection: $knowledgeCutoffDate, displayedComponents: [.date])
                        .labelsHidden()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var defaultSettingsSection: some View {
        sectionCard("Default call settings") {
            VStack(alignment: .leading, spacing: 8) {
                Text(isEditing
                     ? "Resolves above the provider defaults but below profile and conversation overrides. Leave fields unset to inherit."
                     : "Optional — sets the per-model defaults layer of the call-settings chain. Leave collapsed to inherit normally.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isEditing {
                    CallSettingsForm(
                        settings: $defaultSettings,
                        inheritedSettings: nil,
                        driverType: providerType,
                        modelCapabilities: capabilitiesValue
                    )
                    .padding(.top, 8)
                } else {
                    DisclosureGroup(isExpanded: $defaultSettingsExpanded) {
                        CallSettingsForm(
                            settings: $defaultSettings,
                            inheritedSettings: nil,
                            driverType: providerType,
                            modelCapabilities: capabilitiesValue
                        )
                        .padding(.top, 8)
                    } label: {
                        Text(defaultSettingsExpanded ? "Hide defaults" : "Configure defaults…")
                            .font(.caption)
                    }
                }
            }
        }
    }

    /// Builds a ClarkModelPricing from the four price text fields. Returns nil
    /// if all four are empty/unparseable — caller can decide what nil means
    /// (clear-pricing for editing, omit-pricing for adding).
    private func pricingFromFields() -> ClarkModelPricing? {
        let i  = parseDouble(inputPriceText)
        let o  = parseDouble(outputPriceText)
        let cr = parseDouble(cacheReadPriceText)
        let cw = parseDouble(cacheWritePriceText)
        if i == nil && o == nil && cr == nil && cw == nil { return nil }
        return ClarkModelPricing(
            inputPerMillion: i,
            outputPerMillion: o,
            cacheReadPerMillion: cr,
            cacheWritePerMillion: cw
        )
    }

    private func cutoffFromFields() -> String? {
        guard knowledgeCutoffEnabled else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: knowledgeCutoffDate)
    }

    private var capabilitiesValue: ClarkModelCapabilities {
        ClarkModelCapabilities(
            streaming: capStreaming,
            thinking: capThinking,
            toolUse: capToolUse,
            vision: capVision,
            promptCaching: capPromptCaching
        )
    }

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    // MARK: - Seed (edit mode)

    private func seedFromExistingIfNeeded() {
        guard !seeded else { return }
        seeded = true
        guard let m = formMode.existingModel else { return }
        modelID = m.modelID
        displayName = m.displayName
        contextWindowText = m.contextWindow.map { String($0) } ?? ""
        maxOutputTokensText = m.maxOutputTokens.map { String($0) } ?? ""
        if let p = m.pricing {
            inputPriceText      = p.inputPerMillion.map      { String($0) } ?? ""
            outputPriceText     = p.outputPerMillion.map     { String($0) } ?? ""
            cacheReadPriceText  = p.cacheReadPerMillion.map  { String($0) } ?? ""
            cacheWritePriceText = p.cacheWritePerMillion.map { String($0) } ?? ""
        }
        modalities = Set(m.modalities)
        if let c = m.capabilities {
            capStreaming     = c.streaming
            capThinking      = c.thinking
            capToolUse       = c.toolUse
            capVision        = c.vision
            capPromptCaching = c.promptCaching
        }
        if let kc = m.knowledgeCutoff, !kc.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: kc) {
                knowledgeCutoffEnabled = true
                knowledgeCutoffDate = date
            }
        }
        defaultSettings = m.defaultSettings ?? ClarkCallSettings()
    }

    // MARK: - Save

    private func save() async {
        isSaving = true; formError = nil
        defer { isSaving = false }

        let modalitiesArr = Self.modalityChoices.map(\.key).filter { modalities.contains($0) }
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespaces)

        do {
            if let existing = formMode.existingModel {
                let cwText = contextWindowText.trimmingCharacters(in: .whitespaces)
                let moText = maxOutputTokensText.trimmingCharacters(in: .whitespaces)
                _ = try await providersModel.updateModelFull(
                    providerID: provider.id,
                    modelID: existing.modelID,
                    displayName: trimmedDisplayName,
                    contextWindow: parseInt32(contextWindowText),
                    clearContextWindow: cwText.isEmpty,
                    maxOutputTokens: parseInt32(maxOutputTokensText),
                    clearMaxOutputTokens: moText.isEmpty,
                    pricing: pricingFromFields(),
                    modalities: modalitiesArr,
                    capabilities: capabilitiesValue,
                    knowledgeCutoff: cutoffFromFields(),
                    clearKnowledgeCutoff: !knowledgeCutoffEnabled,
                    defaultSettings: defaultSettings
                )
            } else {
                _ = try await providersModel.addManualModel(
                    providerID: provider.id,
                    modelID: modelID.trimmingCharacters(in: .whitespaces),
                    displayName: trimmedDisplayName,
                    contextWindow: parseInt32(contextWindowText),
                    maxOutputTokens: parseInt32(maxOutputTokensText),
                    pricing: pricingFromFields(),
                    modalities: modalitiesArr,
                    capabilities: capabilitiesValue,
                    knowledgeCutoff: cutoffFromFields(),
                    defaultSettings: defaultSettingsExpanded ? defaultSettings : nil
                )
            }
            providersModel.detailMode = .viewing
        } catch {
            formError = error.localizedDescription
        }
    }

    private func parseInt32(_ s: String) -> Int32? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Int32(t) else { return nil }
        return v
    }

    private func parseDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t) else { return nil }
        return v
    }
}

/// Tappable capsule for the modalities multi-select. Distinct from
/// `metaChip` because it carries a Toggle-like state with checkmark tint
/// rather than informational color coding.
private struct ModalityChip: View {
    let label: String
    let systemImage: String
    let isOn: Bool
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 56)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isOn
                ? .regular.tint(theme.accent.opacity(0.45)).interactive()
                : .regular.interactive(),
            in: .capsule
        )
        .foregroundStyle(isOn ? Color.white : Color.primary)
    }
}
