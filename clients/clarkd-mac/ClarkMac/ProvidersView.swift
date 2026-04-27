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
                .listStyle(.sidebar)
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
            case .viewing, .editing, .discovering:
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
    }
}

// MARK: - Provider row

private struct ProviderRow: View {
    let provider: ClarkUserModelProvider
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.label).lineLimit(1)
            Text(provider.type).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
                    .padding()
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
                default:
                    ModelsList(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Full-width tab bar below the header — picks between viewing the
    /// provider's enabled models and discovering new ones.
    @ViewBuilder
    private var tabBar: some View {
        Picker("", selection: tabBinding) {
            Text("Enabled Models").tag(ProvidersDetailMode.viewing)
            Text("Discover Models").tag(ProvidersDetailMode.discovering)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var tabBinding: Binding<ProvidersDetailMode> {
        Binding(
            get: { model.detailMode == .discovering ? .discovering : .viewing },
            set: { model.detailMode = $0 }
        )
    }
}

// MARK: - Provider header (name + type | Edit + Delete buttons)

private struct ProviderHeader: View {
    let provider: ClarkUserModelProvider
    @Bindable var model: ProvidersViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(provider.label)
                    .font(.headline)
                    .lineLimit(1)
                Text(provider.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
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
                ModelRow(model: m) {
                    Task { await model.disableModel(m.modelID) }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct ModelRow: View {
    let model: ClarkUserModel
    let onDisable: () -> Void
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
            }
            Spacer()
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

/// Inline form replacing the old AddProviderSheet. Lives in the providers
/// detail column when `detailMode == .adding`.
private struct AddProviderForm: View {
    @Bindable var model: ProvidersViewModel
    @Environment(AppModel.self) private var app

    @State private var selectedTemplate: ClarkProviderTemplate?
    @State private var label = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var isCreating = false
    @State private var formError: String?

    private var isOpenAI: Bool {
        selectedTemplate?.driverType == "openai-compatible"
    }

    private var canCreate: Bool {
        guard let _ = selectedTemplate else { return false }
        if label.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if apiKey.isEmpty { return false }
        if isOpenAI && baseURL.isEmpty { return false }
        return !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add provider").font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Cancel") {
                    model.detailMode = .viewing
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) }
                    else { Text("Create") }
                }
                .buttonStyle(.glassProminent)
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if selectedTemplate == nil {
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
            }
        }
    }

    /// Full grid shown until a template is picked.
    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Pick a template")
            if model.templates.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                LazyVGrid(columns: [.init(.adaptive(minimum: 200, maximum: 280), spacing: 8)], spacing: 8) {
                    ForEach(model.templates) { t in
                        TemplatePill(template: t, isSelected: false) {
                            selectedTemplate = t
                            if label.isEmpty { label = t.name }
                            if baseURL.isEmpty { baseURL = t.apiBase ?? "" }
                        }
                    }
                }
            }
        }
    }

    /// Compact summary of the chosen template, with a "Change" button to
    /// reopen the picker. Stays at the top of the form so it's immediately
    /// clear what's being added.
    @ViewBuilder
    private var selectedTemplateRow: some View {
        if let t = selectedTemplate {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Template")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).fontWeight(.semibold)
                        Text(t.driverType).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") {
                        selectedTemplate = nil
                    }
                    .buttonStyle(.glass)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.4))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Credentials")
            CredField("Label") {
                TextField("Display name", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            CredField(
                "API key",
                hint: selectedTemplate?.envKey.map { "env: \($0)" }
            ) {
                SecureField("Paste key here", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            if isOpenAI {
                CredField("Base URL") {
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func save() async {
        guard let tmpl = selectedTemplate else { return }
        isCreating = true; formError = nil
        defer { isCreating = false }
        do {
            var dict: [String: String] = ["api_key": apiKey]
            if tmpl.driverType == "openai-compatible" {
                if !baseURL.isEmpty { dict["base_url"] = baseURL }
                if !tmpl.catalogProviderID.isEmpty { dict["catalog_provider_id"] = tmpl.catalogProviderID }
            }
            let config = try JSONSerialization.data(withJSONObject: dict)
            let provider = try await model.createProvider(
                type: tmpl.driverType,
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Edit provider").font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Cancel") {
                    model.detailMode = .viewing
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) }
                    else { Text("Save") }
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }

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
        .onAppear {
            label = provider.label
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
            // Search bar
            if !discovered.isEmpty || !searchText.isEmpty || isLoading {
                HStack {
                    TextField("Search models…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    if isLoading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }

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

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(template.driverType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor.opacity(0.4))
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
