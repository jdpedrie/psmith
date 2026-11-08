import SwiftUI
import PsmithKit
import PsmithUI

/// The Models pane (boards "Models · …"): providers on the left; a
/// provider's Models, Connection and Defaults tabs on the right; a model
/// drilled into in place; adding a provider or a model inline.
struct ModelsPane: View {
    @Bindable var model: ProvidersViewModel
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        SKSplit(scrollsDetail: false) {
            SKListHeader(text: "Providers")
            ForEach(model.providers, id: \.id) { provider in
                SKListItem(
                    title: provider.label,
                    selected: model.detailMode != .adding && model.selectedID == provider.id,
                    action: { navigator.settingsProviderTab = .models; Task { await model.selectProvider(provider.id) } },
                    lead: { ProviderLogo(slug: Self.logoSlug(provider), size: 16) },
                    trail: { SKDot(color: Self.failing(model.providerTestStatus[provider.id]) ? SK.orange : SK.green) }
                )
            }
            if model.isLoadingProviders, model.providers.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            SKAddItem(title: "Add provider…", selected: model.detailMode == .adding) { model.startAddingCustom() }
        } detail: {
            detail
        }
        .task {
            if !model.hasLoadedOnce { await model.load() }
            if model.templates.isEmpty { await model.loadTemplates() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.detailMode {
        case .adding:
            AddProviderPage(model: model)
        case .addingManualModel:
            if let provider = selectedProvider {
                ModelPage(model: model, provider: provider, existing: nil)
            }
        case .editingModel(let id):
            if let provider = selectedProvider, let m = model.enabledModels.first(where: { $0.modelID == id }) {
                ModelPage(model: model, provider: provider, existing: m).id(id)
            }
        default:
            if let provider = selectedProvider {
                ProviderPage(model: model, provider: provider, tab: Binding(get: { navigator.settingsProviderTab }, set: { navigator.settingsProviderTab = $0 })).id(provider.id)
            } else if model.isLoadingProviders {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SKDetailPage {
                    SKPageHead("No providers yet", subtitle: "Add one from the list to start choosing models.")
                }
            }
        }
    }

    private var selectedProvider: PsmithUserModelProvider? {
        model.providers.first { $0.id == model.selectedID }
    }

    static func failing(_ status: ProviderTestStatus?) -> Bool {
        switch status {
        case .failure: true
        case .success(let r): !r.ok
        default: false
        }
    }

    static func logoSlug(_ p: PsmithUserModelProvider) -> String? {
        switch p.type {
        case "anthropic": "anthropic"
        case "google": "google"
        case "openai-compatible": p.presetID
        default: nil
        }
    }

    static func driverLabel(_ type: String) -> String {
        switch type {
        case "anthropic": "Anthropic"
        case "google": "Google"
        case "openai-compatible": "OpenAI-compatible"
        default: type
        }
    }
}

// MARK: - Provider page

private struct ProviderPage: View {
    @Bindable var model: ProvidersViewModel
    let provider: PsmithUserModelProvider
    @Binding var tab: SettingsProviderTab
    @Environment(AppModel.self) private var app

    @State private var discovered: [PsmithDiscoveredModel] = []
    @State private var discoverError: String?
    @State private var discovering = false

    // Connection drafts.
    @State private var name = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var catalog: String?
    @State private var connectionError: String?
    @State private var savingConnection = false
    @State private var confirmingDelete = false

    // Defaults draft.
    @State private var defaults = PsmithCallSettings()
    @State private var defaultsError: String?
    @State private var savingDefaults = false

    private var isOpenAI: Bool { provider.type == "openai-compatible" }
    private var seededCatalog: String? {
        model.templates.first { $0.presetID != nil && $0.presetID == provider.presetID }?.catalogProviderID
    }

    var body: some View {
        SKDetailPage {
            head
            SKSubtabs(options: [(.models, "Models"), (.connection, "Connection"), (.defaults, "Defaults")], selection: $tab)
            switch tab {
            case .models: ModelsTab(model: model, provider: provider, discovered: discovered, discovering: discovering, discoverError: discoverError)
            case .connection: connection
            case .defaults: defaultsTab
            }
        } bottom: {
            bar
        }
        .task(id: provider.id) {
            name = provider.label
            baseURL = provider.baseURL ?? ""
            catalog = seededCatalog
            defaults = provider.defaultSettings ?? PsmithCallSettings()
            await discover()
        }
    }

    private func discover() async {
        discovering = true
        defer { discovering = false }
        do {
            discovered = try await model.discoverModels(providerID: provider.id)
            discoverError = nil
        } catch {
            discoverError = PsmithError.display(error)
        }
    }

    private var head: some View {
        let on = model.enabledModels.count
        let total = max(discovered.count, on)
        let counts = discovered.isEmpty ? "\(on) model\(on == 1 ? "" : "s") on" : "\(on) of \(total) models on"
        return SKPageHead(title: provider.label, subtitle: "\(ModelsPane.driverLabel(provider.type)) · \(counts)") {
            TestChip(status: model.providerTestStatus[provider.id] ?? .idle) {
                Task { await model.testProvider(provider.id) }
            }
        }
    }

    // MARK: Connection

    private var connectionChanges: [String] {
        var out: [String] = []
        if name.trimmingCharacters(in: .whitespaces) != provider.label { out.append("Name") }
        if !apiKey.isEmpty { out.append("API key") }
        if isOpenAI, baseURL != (provider.baseURL ?? "") { out.append("Base URL") }
        if isOpenAI, catalog != seededCatalog { out.append("Model catalog") }
        return out
    }

    @ViewBuilder
    private var connection: some View {
        if case .success(let r) = model.providerTestStatus[provider.id], !r.ok {
            SKBanner(.warning, "The last test failed: \(r.errorMessage)", message: "The key may have been revoked. Paste a new one and test again.")
        } else if case .failure(let message) = model.providerTestStatus[provider.id] {
            SKBanner(.warning, "The last test failed: \(message)", message: "The key may have been revoked. Paste a new one and test again.")
        }
        if let connectionError { SKBanner(.error, "Couldn't save", message: connectionError) }
        SKGroup("Connection") {
            SKRow("Name") { SKTextField(label: "Name", text: $name, width: 280) }
            SKRow("API key", detail: "Typing a key replaces the saved one when you save.") {
                SKSecretField(isSaved: true, draft: $apiKey, width: 200)
            }
            if isOpenAI {
                SKRow("Base URL") { SKTextField(label: "Base URL", text: $baseURL, placeholder: "https://api.example.com/v1", width: 280, mono: true) }
                SKRow("Model catalog", detail: "Fills in pricing and limits from models.dev.") {
                    SKPopup(value: model.templates.first { $0.catalogProviderID == catalog }?.name ?? "None", minWidth: 160) {
                        Button("None") { catalog = "" }
                        Divider()
                        ForEach(model.templates.filter { $0.driverType == "openai-compatible" }, id: \.id) { t in
                            Button(t.name) { catalog = t.catalogProviderID }
                        }
                    }
                }
            }
        } trailing: {
            SKChip.synced
        }
        SKGroup {
            if confirmingDelete {
                SKRawRow(vertical: 8, horizontal: 8) {
                    let n = model.enabledModels.count
                    SKConfirmStrip(
                        question: "Delete \(provider.label)?",
                        detail: "Its \(n) enabled model\(n == 1 ? "" : "s") go too. Past messages keep their text.",
                        confirmLabel: "Delete Provider",
                        onCancel: { confirmingDelete = false },
                        onConfirm: { confirmingDelete = false; Task { await model.deleteSelected() } }
                    )
                }
            } else {
                SKRow("Delete provider", detail: "Its models go too. Past messages keep their text.") {
                    Button(model.isDeleting ? "Deleting…" : "Delete…") { confirmingDelete = true }
                        .skButton(.destructive)
                        .disabled(model.isDeleting)
                }
            }
        }
    }

    private func saveConnection() async {
        savingConnection = true
        defer { savingConnection = false }
        var dict: [String: String] = [:]
        if !apiKey.isEmpty { dict["api_key"] = apiKey }
        if isOpenAI {
            if baseURL != (provider.baseURL ?? "") { dict["base_url"] = baseURL }
            if catalog != seededCatalog { dict["catalog_provider_id"] = catalog ?? "" }
        }
        do {
            try await model.updateProvider(
                id: provider.id,
                label: name.trimmingCharacters(in: .whitespaces),
                config: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
            )
            apiKey = ""
            connectionError = nil
        } catch {
            connectionError = PsmithError.display(error)
        }
    }

    // MARK: Defaults

    @ViewBuilder
    private var defaultsTab: some View {
        Text("Every model here starts from these. A model's own settings, then the profile's, then the conversation's win over them.")
            .sk(12, SK.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, -6)
            .padding(.bottom, 16)
        if let defaultsError { SKBanner(.error, "Couldn't save", message: defaultsError) }
        SKCallSettings(settings: $defaults, driver: provider.type)
    }

    private var defaultsChanges: [String] {
        CallSettingsDiff.changed(from: provider.defaultSettings ?? PsmithCallSettings(), to: defaults)
    }

    // MARK: Bar

    @ViewBuilder
    private var bar: some View {
        switch tab {
        case .connection where !connectionChanges.isEmpty:
            SKSaveBar(summary: IntegrationsPane.summary(connectionChanges), saving: savingConnection, onDiscard: {
                name = provider.label; apiKey = ""; baseURL = provider.baseURL ?? ""; catalog = seededCatalog
            }, onSave: { Task { await saveConnection() } })
        case .defaults where !defaultsChanges.isEmpty:
            SKSaveBar(summary: IntegrationsPane.summary(defaultsChanges), saving: savingDefaults, onDiscard: {
                defaults = provider.defaultSettings ?? PsmithCallSettings()
            }, onSave: {
                Task {
                    savingDefaults = true
                    defer { savingDefaults = false }
                    do {
                        try await model.updateProviderDefaultSettings(providerID: provider.id, settings: defaults)
                        defaultsError = nil
                    } catch {
                        defaultsError = PsmithError.display(error)
                    }
                }
            })
        default:
            EmptyView()
        }
    }
}

/// The provider test as a button: "Test", then what it found.
private struct TestChip: View {
    let status: ProviderTestStatus
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            HStack(spacing: 6) {
                switch status {
                case .idle:
                    Image(systemName: "bolt").font(.system(size: 11)); Text("Test")
                case .testing:
                    ProgressView().controlSize(.mini); Text("Testing…")
                case .success(let r) where r.ok:
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(SK.green)
                    Text("\(r.modelCount) models · \(r.latencyMs) ms").foregroundStyle(SK.green)
                case .success(let r):
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(SK.orange)
                    Text(Self.short(r.errorMessage)).foregroundStyle(SK.orange)
                case .failure(let m):
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(SK.orange)
                    Text(Self.short(m)).foregroundStyle(SK.orange)
                }
            }
            .fixedSize()
        }
        .skButton()
        .disabled({ if case .testing = status { return true }; return false }())
        .help("Check the key and list the provider's models")
    }

    /// The first line of an error, cut to fit the header.
    static func short(_ m: String) -> String {
        let line = m.split(separator: "\n").first.map(String.init) ?? ""
        if line.isEmpty { return "Failed" }
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}

// MARK: - Models tab

private struct ModelsTab: View {
    @Bindable var model: ProvidersViewModel
    let provider: PsmithUserModelProvider
    let discovered: [PsmithDiscoveredModel]
    let discovering: Bool
    let discoverError: String?
    @Environment(AppModel.self) private var app
    @State private var filter = ""
    @State private var showAll = false
    @State private var expanded: String?

    private struct Row: Identifiable {
        let id: String
        let name: String
        let enabled: PsmithUserModel?
        let discovered: PsmithDiscoveredModel?
        var contextWindow: Int32? { enabled?.contextWindow ?? discovered?.contextWindow }
        var pricing: PsmithModelPricing? { enabled?.pricing ?? discovered?.pricing }
        var capabilities: PsmithModelCapabilities? { enabled?.capabilities ?? discovered?.capabilities }
    }

    private var rows: [Row] {
        var out = model.enabledModels.map { Row(id: $0.modelID, name: $0.displayName, enabled: $0, discovered: nil) }
        if showAll {
            let on = Set(out.map(\.id))
            out += discovered.filter { !on.contains($0.modelID) }.map { Row(id: $0.modelID, name: $0.displayName, enabled: nil, discovered: $0) }
        }
        let q = filter.lowercased()
        return out
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
            .sorted { ($0.enabled != nil ? 0 : 1, $0.name) < ($1.enabled != nil ? 0 : 1, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SKSearchField(placeholder: "Filter models", text: $filter).frame(width: 240)
                SKSegmented(options: [(false, "On"), (true, discovered.isEmpty ? "All" : "All \(max(discovered.count, model.enabledModels.count))")], selection: $showAll)
                Spacer(minLength: 0)
                Button("Add Custom Model…") { model.detailMode = .addingManualModel }.skButton()
            }
            // The boards' search box carries 8 above and 2 below itself.
            .padding(.bottom, 14)
            if showAll, let discoverError {
                SKBanner(.warning, "Couldn't list this provider's models", message: discoverError)
            }
            table
            Text("Turn a model on to use it in conversations and profiles. Prices are per million tokens, from models.dev.")
                .sk(11.5, SK.tertiary)
        }
    }

    private static let columns: [GridItem] = []

    private var table: some View {
        VStack(spacing: 0) {
            header
            if rows.isEmpty {
                Text(discovering && showAll ? "Listing models…" : (filter.isEmpty ? "No models on. Choose All to see what this provider offers." : "No models match."))
                    .sk(13, SK.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12).padding(.horizontal, 12)
                    .overlay(alignment: .top) { Rectangle().fill(SK.hair).frame(height: 1) }
            }
            ForEach(rows) { r in
                rowView(r)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SK.line, lineWidth: 1))
        .padding(.bottom, 12)
    }

    private func grid<A: View, B: View, C: View, D: View, E: View, F: View>(@ViewBuilder _ a: () -> A, @ViewBuilder _ b: () -> B, @ViewBuilder _ c: () -> C, @ViewBuilder _ d: () -> D, @ViewBuilder _ e: () -> E, @ViewBuilder _ f: () -> F) -> some View {
        HStack(spacing: 8) {
            a().frame(width: 24, alignment: .leading)
            b().frame(maxWidth: .infinity, alignment: .leading)
            c().frame(width: 64, alignment: .leading)
            d().frame(width: 104, alignment: .leading)
            e().frame(width: 140, alignment: .leading)
            f().frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, 12)
    }

    private var header: some View {
        grid({ Color.clear }, { Text("Model") }, { Text("Context") }, { Text("Price in / out") }, { Text("Can") }, { Text("On") })
            .sk(11.5, SK.secondary, weight: .semibold)
            .padding(.vertical, 7)
            .background(SK.bar)
    }

    private func subtitle(_ r: Row) -> String {
        let defaults = app.profiles.profiles.filter { $0.defaultSettings?.defaultModelID == r.id && $0.defaultSettings?.defaultProviderID == provider.id }.count
        let compression = app.profiles.profiles.contains { $0.compressionModelID == r.id && $0.compressionProviderID == provider.id }
        var parts = [r.id]
        if defaults > 0 { parts.append("default for \(defaults) profile\(defaults == 1 ? "" : "s")") }
        if compression { parts.append("compression default") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func rowView(_ r: Row) -> some View {
        let on = r.enabled != nil
        let open = expanded == r.id && on
        VStack(alignment: .leading, spacing: 0) {
            grid({
                if let m = r.enabled {
                    Button { Task { await model.toggleModelFavorite(modelID: m.modelID) } } label: {
                        Image(systemName: m.favorite ? "star.fill" : "star")
                            .font(.system(size: 12))
                            .foregroundStyle(m.favorite ? Color(hex: 0xF5C451) : SK.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(m.favorite ? "Unfavorite" : "Mark as favorite")
                }
            }, {
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.name).sk(13, on ? SK.text : SK.secondary, weight: .semibold).skOneLine(13)
                    Text(subtitle(r)).sk(11.5, SK.tertiary).skOneLine(11.5)
                }
            }, {
                Text(r.contextWindow.map(Self.compact) ?? "—").sk(13, on ? SK.text : SK.secondary).monospacedDigit()
            }, {
                price(r.pricing, on: on)
            }, {
                Text(Self.abilities(r.capabilities)).sk(13, on ? SK.link : SK.secondary).lineLimit(1)
            }, {
                Toggle("On", isOn: Binding(get: { on }, set: { v in
                    Task {
                        if v { _ = try? await model.enableModels(providerID: provider.id, modelIDs: [r.id]) }
                        else { await model.disableModel(r.id) }
                    }
                })).skSwitch()
            })
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { if on { withAnimation(.easeOut(duration: 0.15)) { expanded = open ? nil : r.id } } }
            if open, let m = r.enabled { details(m) }
        }
        .overlay(alignment: .top) { Rectangle().fill(SK.hair).frame(height: 1) }
    }

    private func details(_ m: PsmithUserModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                fact("Max output", m.maxOutputTokens.map(Self.compact) ?? "—")
                fact("Cache read / write", m.pricing.flatMap { p in
                    guard p.cacheReadPerMillion != nil || p.cacheWritePerMillion != nil else { return nil }
                    return "\(Self.dollars(p.cacheReadPerMillion, cents: true)) / \(Self.dollars(p.cacheWritePerMillion, cents: true))"
                } ?? "—")
                fact("Knowledge", m.knowledgeCutoff.flatMap(Self.month) ?? "—")
                fact("Takes", m.modalities.isEmpty ? "—" : m.modalities.map(Self.modality).joined(separator: ", "))
            }
            HStack(spacing: 8) {
                testLine(model.modelTestStatus[ModelTestKey(providerID: provider.id, modelID: m.modelID)] ?? .idle)
                Spacer(minLength: 0)
                Button("Test Model") { Task { await model.testModel(providerID: provider.id, modelID: m.modelID) } }.skButton(small: true)
                Button { model.detailMode = .editingModel(m.modelID) } label: {
                    HStack(spacing: 4) { Text("Edit Model"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                }
                .skButton(small: true)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .padding(.leading, 44)
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private func testLine(_ status: ModelTestStatus) -> some View {
        switch status {
        case .success(let r) where r.ok:
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(SK.green)
                Text("Answered in \(r.latencyMs) ms · \(r.outputTokens) tokens").sk(12, SK.green)
            }
        case .success(let r):
            Text(r.errorMessage.isEmpty ? "Test failed" : r.errorMessage).sk(12, SK.red).lineLimit(1)
        case .failure(let m):
            Text(m).sk(12, SK.red).lineLimit(1)
        case .testing:
            ProgressView().controlSize(.mini)
        case .idle:
            EmptyView()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).sk(12, SK.secondary)
            Text(value).sk(12, weight: .semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func price(_ p: PsmithModelPricing?, on: Bool) -> some View {
        if let p, p.inputPerMillion != nil || p.outputPerMillion != nil {
            HStack(spacing: 4) {
                Text("\(Self.dollars(p.inputPerMillion)) / \(Self.dollars(p.outputPerMillion))").sk(13, on ? SK.text : SK.secondary).monospacedDigit()
                if !p.tiers.isEmpty {
                    Text("tiered").sk(11, SK.orange).help("The price changes past a context size")
                }
            }
        } else {
            Text("—").sk(13, SK.secondary)
        }
    }

    static func compact(_ n: Int32) -> String {
        n >= 1_000_000 ? "\(n / 1_000_000)M" : n >= 1_000 ? "\(n / 1_000)K" : "\(n)"
    }

    /// "$15", "$0.25", "—"; with cents always when asked ("$1.50").
    static func dollars(_ v: Double?, cents: Bool = false) -> String {
        guard let v else { return "—" }
        if !cents, v == v.rounded() { return "$\(Int(v))" }
        return String(format: "$%.2f", v)
    }

    static func abilities(_ c: PsmithModelCapabilities?) -> String {
        guard let c else { return "" }
        var words: [String] = []
        if c.thinking { words.append("think") }
        if c.vision { words.append("see") }
        if c.toolUse { words.append("tools") }
        if c.generatesImages { words.append("draw") }
        return words.joined(separator: " · ")
    }

    static func month(_ cutoff: String) -> String? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: cutoff) else { return cutoff }
        let out = DateFormatter()
        out.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return out.string(from: d)
    }

    static func modality(_ m: String) -> String {
        m == "pdf" ? "PDF" : m.prefix(1).uppercased() + m.dropFirst()
    }
}

// MARK: - Model page

/// One model, drilled into (board "Models · one model"), or a new one
/// described by hand (board "Models · adding a model by hand").
private struct ModelPage: View {
    @Bindable var model: ProvidersViewModel
    let provider: PsmithUserModelProvider
    let existing: PsmithUserModel?

    @State private var name = ""
    @State private var modelID = ""
    @State private var context = ""
    @State private var maxOutput = ""
    @State private var cutoff = ""
    @State private var input = ""
    @State private var output = ""
    @State private var cacheRead = ""
    @State private var cacheWrite = ""
    @State private var caps = PsmithModelCapabilities(streaming: true, thinking: false, toolUse: false, vision: false, promptCaching: false)
    @State private var modalities: Set<String> = ["text"]
    @State private var defaults = PsmithCallSettings()
    @State private var saving = false
    @State private var error: String?
    @State private var refreshNote: String?

    private var adding: Bool { existing == nil }
    private var key: ModelTestKey { ModelTestKey(providerID: provider.id, modelID: existing?.modelID ?? "") }

    var body: some View {
        SKDetailPage {
            SKBreadcrumb(parts: [(provider.label, { model.detailMode = .viewing })], current: adding ? "Add a model" : (existing?.displayName ?? ""))
            if adding {
                SKPageHead("Add a model", subtitle: "For a private fine-tune, or a model \(provider.label) doesn't list.")
            } else if let m = existing {
                SKPageHead(title: m.displayName, subtitle: "\(m.modelID) · on") {
                    HStack(spacing: 10) {
                        Button("Test Model") { Task { await model.testModel(providerID: provider.id, modelID: m.modelID) } }.skButton()
                        Toggle("On", isOn: Binding(get: { true }, set: { v in
                            if !v { Task { await model.disableModel(m.modelID); model.detailMode = .viewing } }
                        })).skSwitch()
                    }
                }
            }
            if let error { SKBanner(.error, adding ? "Couldn't add the model" : "Couldn't save", message: error) }
            identity
            pricing
            abilities
            if adding {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { model.detailMode = .viewing }.skButton().keyboardShortcut(.cancelAction)
                    Button(saving ? "Adding…" : "Add Model") { Task { await add() } }
                        .skButton(.primary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || modelID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text("Default settings for this model").sk(12, SK.secondary, weight: .semibold).padding(.horizontal, 2).padding(.top, 4).padding(.bottom, 7)
                Text("Above the provider's defaults, below a profile's and a conversation's. Blue text is what this model inherits.")
                    .sk(11.5, SK.tertiary).padding(.horizontal, 2).padding(.bottom, 10)
                SKCallSettings(settings: $defaults, inherited: provider.defaultSettings, inheritedFrom: provider.label,
                               driver: provider.type, constraints: existing?.constraints)
            }
        } bottom: {
            if !adding, !changes.isEmpty {
                SKSaveBar(summary: IntegrationsPane.summary(changes), saving: saving, onDiscard: seed, onSave: { Task { await save() } })
            }
        }
        .onAppear(perform: seed)
    }

    private var identity: some View {
        SKGroup("Model") {
            SKRow("Name") { SKTextField(label: "Name", text: $name, width: 260) }
            if adding {
                SKRow("Model ID", detail: "Sent to the provider exactly as typed.") {
                    SKTextField(label: "Model ID", text: $modelID, width: 260, mono: true)
                }
            } else {
                SKRow("Model ID", detail: "Sent to the provider. To change it, add the model again.") {
                    Text(modelID).sk(13, SK.secondary, mono: true).textSelection(.enabled)
                }
            }
            SKRow("Context window") {
                HStack(spacing: 8) { SKTextField(label: "Context window", text: $context, placeholder: adding ? "Optional" : "", width: 110, mono: true); Text("tokens").sk(12.5, SK.secondary) }
            }
            SKRow("Max output") {
                HStack(spacing: 8) { SKTextField(label: "Max output", text: $maxOutput, placeholder: "Optional", width: 110, mono: true); Text("tokens").sk(12.5, SK.secondary) }
            }
            SKRow("Knowledge cutoff") {
                HStack(spacing: 8) {
                    SKTextField(label: "Knowledge cutoff", text: $cutoff, placeholder: "YYYY-MM-DD", width: 110, mono: true)
                    if !cutoff.isEmpty, !adding { Button("Clear") { cutoff = "" }.skButton(.plain) }
                }
            }
        } trailing: {
            SKChip.synced
        }
    }

    private var pricing: some View {
        SKGroup("Price per million tokens") {
            SKRawRow(vertical: 12) {
                HStack(spacing: 12) {
                    priceField("Input", $input)
                    priceField("Output", $output)
                    priceField("Cache read", $cacheRead)
                    priceField("Cache write", $cacheWrite)
                }
            }
        } footer: {
            if adding {
                Text("Optional. Leave empty and Usage counts this model as $0.")
            } else {
                HStack(spacing: 4) {
                    Text("From models.dev, refreshed when the catalog changes. Editing a price stops that for this model.")
                    Button("Refresh from catalog") { Task { await refresh() } }.buttonStyle(.plain).foregroundStyle(SK.link)
                    if let refreshNote { Text(refreshNote) }
                }
            }
        }
    }

    private func priceField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).sk(11.5, SK.secondary)
            SKTextField(label: label, text: text, placeholder: adding ? "0.00" : "", width: 110, mono: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var abilities: some View {
        SKGroup("What it can do") {
            SKRawRow(vertical: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 9) {
                    check("Streaming", .streaming)
                    check("Thinking", .thinking)
                    check("Tool use", .toolUse)
                    check("Vision", .vision)
                    check("Prompt caching", .caching)
                    check("Makes images", .images)
                }
            }
            SKRawRow(vertical: 10) {
                HStack(spacing: 14) {
                    Text("Takes").sk(12.5, SK.secondary)
                    ForEach(["text", "image", "pdf", "audio", "video"], id: \.self) { m in
                        SKCheckbox(title: ModelsTab_modality(m), isOn: Binding(
                            get: { modalities.contains(m) },
                            set: { if $0 { modalities.insert(m) } else { modalities.remove(m) } }
                        ))
                    }
                }
            }
            if !adding {
                SKRow("Check with the model", detail: "Runs a few tiny requests. Costs a few tokens. It can turn things on, never off.") {
                    HStack(spacing: 10) {
                        probeStatus
                        Button("Probe") { Task { await model.probeModelCapabilities(providerID: provider.id, modelID: existing!.modelID, apply: true) } }
                            .skButton()
                            .disabled({ if case .probing = model.capabilityProbeStatus[key] { return true }; return false }())
                    }
                }
            }
        } footer: {
            if adding { Text("Once it's added, Check with the model on its page can confirm these.") }
        }
    }

    @ViewBuilder
    private var probeStatus: some View {
        switch model.capabilityProbeStatus[key] ?? .idle {
        case .probing:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking…").sk(12.5, SK.secondary) }
        case .done(let p):
            Text(p.enabled.isEmpty ? "Nothing new" : "Turned on \(p.enabled.joined(separator: ", "))").sk(12.5, p.enabled.isEmpty ? SK.secondary : SK.green)
        case .failure(let m):
            Text(m).sk(12.5, SK.orange).lineLimit(1)
        case .idle:
            EmptyView()
        }
    }

    private enum Cap { case streaming, thinking, toolUse, vision, caching, images }

    private func get(_ c: Cap) -> Bool {
        switch c {
        case .streaming: caps.streaming
        case .thinking: caps.thinking
        case .toolUse: caps.toolUse
        case .vision: caps.vision
        case .caching: caps.promptCaching
        case .images: caps.generatesImages
        }
    }

    private func check(_ title: String, _ c: Cap) -> some View {
        SKCheckbox(title: title, isOn: Binding(get: { get(c) }, set: { v in
            func pick(_ k: Cap) -> Bool { k == c ? v : get(k) }
            caps = PsmithModelCapabilities(streaming: pick(.streaming), thinking: pick(.thinking), toolUse: pick(.toolUse),
                                           vision: pick(.vision), promptCaching: pick(.caching), generatesImages: pick(.images))
        }))
    }

    // MARK: State

    private func seed() {
        guard let m = existing else { return }
        name = m.displayName
        modelID = m.modelID
        context = m.contextWindow.map { $0.formatted() } ?? ""
        maxOutput = m.maxOutputTokens.map { $0.formatted() } ?? ""
        cutoff = m.knowledgeCutoff ?? ""
        input = Self.price(m.pricing?.inputPerMillion)
        output = Self.price(m.pricing?.outputPerMillion)
        cacheRead = Self.price(m.pricing?.cacheReadPerMillion)
        cacheWrite = Self.price(m.pricing?.cacheWritePerMillion)
        caps = m.capabilities ?? caps
        modalities = Set(m.modalities)
        defaults = m.defaultSettings ?? PsmithCallSettings()
    }

    static func price(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "" }
    static func parsePrice(_ s: String) -> Double? { Double(s.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)) }
    static func parseInt(_ s: String) -> Int32? { Int32(s.filter(\.isNumber)) }

    private var newPricing: PsmithModelPricing? {
        let p = PsmithModelPricing(inputPerMillion: Self.parsePrice(input), outputPerMillion: Self.parsePrice(output),
                                   cacheReadPerMillion: Self.parsePrice(cacheRead), cacheWritePerMillion: Self.parsePrice(cacheWrite),
                                   tiers: existing?.pricing?.tiers ?? [])
        return [p.inputPerMillion, p.outputPerMillion, p.cacheReadPerMillion, p.cacheWritePerMillion].allSatisfy { $0 == nil } ? nil : p
    }

    private var changes: [String] {
        guard let m = existing else { return [] }
        var out: [String] = []
        if name != m.displayName { out.append("Name") }
        if Self.parseInt(context) != m.contextWindow { out.append("Context window") }
        if Self.parseInt(maxOutput) != m.maxOutputTokens { out.append("Max output") }
        if cutoff != (m.knowledgeCutoff ?? "") { out.append("Knowledge cutoff") }
        if input != Self.price(m.pricing?.inputPerMillion) || output != Self.price(m.pricing?.outputPerMillion)
            || cacheRead != Self.price(m.pricing?.cacheReadPerMillion) || cacheWrite != Self.price(m.pricing?.cacheWritePerMillion) { out.append("Price") }
        if caps != (m.capabilities ?? caps) { out.append("Capabilities") }
        if modalities != Set(m.modalities) { out.append("Inputs") }
        out += CallSettingsDiff.changed(from: m.defaultSettings ?? PsmithCallSettings(), to: defaults)
        return out
    }

    private func save() async {
        guard let m = existing else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await model.updateModelFull(
                providerID: provider.id, modelID: m.modelID,
                displayName: name,
                contextWindow: Self.parseInt(context), clearContextWindow: context.isEmpty,
                maxOutputTokens: Self.parseInt(maxOutput), clearMaxOutputTokens: maxOutput.isEmpty,
                pricing: newPricing,
                modalities: Array(modalities).sorted(),
                capabilities: caps,
                knowledgeCutoff: cutoff.isEmpty ? nil : cutoff, clearKnowledgeCutoff: cutoff.isEmpty,
                defaultSettings: defaults
            )
            error = nil
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        do {
            let m = try await model.addManualModel(
                providerID: provider.id,
                modelID: modelID.trimmingCharacters(in: .whitespaces),
                displayName: name.trimmingCharacters(in: .whitespaces),
                contextWindow: Self.parseInt(context), maxOutputTokens: Self.parseInt(maxOutput),
                pricing: newPricing, modalities: Array(modalities).sorted(), capabilities: caps,
                knowledgeCutoff: cutoff.isEmpty ? nil : cutoff, defaultSettings: nil
            )
            model.detailMode = .editingModel(m.modelID)
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    private func refresh() async {
        guard let m = existing else { return }
        do {
            let result = try await model.refreshModelMetadata(providerID: provider.id, modelID: m.modelID)
            refreshNote = result.refreshed ? "Updated." : "Already current."
            if result.refreshed { seed() }
        } catch {
            refreshNote = PsmithError.display(error)
        }
    }
}

private func ModelsTab_modality(_ m: String) -> String {
    m == "pdf" ? "PDF" : m.prefix(1).uppercased() + m.dropFirst()
}

/// The boards' checkbox: a 14pt rounded square, accent when on.
struct SKCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? SK.accent : .clear)
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                        } else {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                        }
                    }
                    .frame(width: 14, height: 14)
                Text(title).sk(13)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}

// MARK: - Add provider

private struct AddProviderPage: View {
    @Bindable var model: ProvidersViewModel
    @State private var custom = true
    @State private var template: PsmithProviderTemplate?
    @State private var driver = "openai-compatible"
    @State private var name = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var creating = false
    @State private var error: String?

    private var configured: Set<String> { Set(model.templates.map(\.id)).subtracting(model.unconfiguredTemplates.map(\.id)) }
    private var effectiveDriver: String { custom ? driver : (template?.driverType ?? driver) }

    var body: some View {
        SKDetailPage {
            SKPageHead("Add a provider", subtitle: "Pick a service, paste its key. Psmith lists its models next.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(model.templates, id: \.id) { t in
                    card(t.name, logo: ProviderLogo(slug: t.logoSlug, size: 16), selected: !custom && template?.id == t.id, added: configured.contains(t.id)) { pick(t) }
                }
                card("Custom", logo: RoundedRectangle(cornerRadius: 4).strokeBorder(SK.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 16, height: 16),
                     selected: custom, added: false) { pickCustom() }
            }
            .padding(.bottom, 20)
            if let error { SKBanner(.error, "Couldn't add the provider", message: error) }
            SKGroup(custom ? "Custom" : (template?.name ?? "")) {
                if custom {
                    SKRow("Driver", detail: "How Psmith talks to it.") {
                        SKSegmented(options: [("anthropic", "Anthropic"), ("openai-compatible", "OpenAI-compatible")], selection: $driver)
                    }
                }
                SKRow("Name") { SKTextField(label: "Name", text: $name, width: 280) }
                SKRow("API key", detail: custom ? "Leave empty if the server doesn't ask for one." : template?.envKey.map { "Usually in \($0)." }) {
                    SKTextField(label: "API key", text: $apiKey, placeholder: "Paste key", width: 280, secure: true)
                }
                if effectiveDriver == "openai-compatible" {
                    SKRow("Base URL", detail: custom ? "Required. Usually ends with /v1." : nil) {
                        SKTextField(label: "Base URL", text: $baseURL, placeholder: "https://api.example.com/v1", width: 280, mono: true)
                    }
                }
            } footer: {
                Text(custom ? "Psmith asks the server for its models once it's added."
                     : (effectiveDriver == "openai-compatible" ? "OpenAI-compatible. Pricing and limits come from models.dev." : "Pricing and limits come from models.dev."))
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { model.detailMode = .viewing }.skButton().keyboardShortcut(.cancelAction)
                Button(creating ? "Adding…" : "Add Provider") { Task { await create() } }
                    .skButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (effectiveDriver == "openai-compatible" && baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                              || (!custom && apiKey.isEmpty))
            }
        }
        .onAppear {
            if let preset = model.pendingAddPreset { pick(preset) } else { pickCustom() }
        }
    }

    private func card<L: View>(_ title: String, logo: L, selected: Bool, added: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                logo
                Text(title).sk(12.5).lineLimit(1)
                Spacer(minLength: 0)
                if added { SKChip(text: "Added") }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? SK.accent.opacity(0.12) : SK.card))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? SK.accent : SK.line, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .opacity(added ? 0.55 : 1)
        .disabled(added)
    }

    private func pick(_ t: PsmithProviderTemplate) {
        custom = false
        template = t
        name = t.name
        baseURL = t.apiBase ?? ""
        apiKey = ""
    }

    private func pickCustom() {
        custom = true
        template = nil
        name = "Custom provider"
        baseURL = ""
        apiKey = ""
    }

    private func create() async {
        creating = true
        defer { creating = false }
        var dict: [String: String] = ["api_key": apiKey]
        if effectiveDriver == "openai-compatible" {
            dict["base_url"] = baseURL.trimmingCharacters(in: .whitespaces)
            if let t = template, !custom {
                if !t.catalogProviderID.isEmpty { dict["catalog_provider_id"] = t.catalogProviderID }
                // preset_id picks the openai driver's per-service quirks.
                if let pid = t.presetID, !pid.isEmpty { dict["preset_id"] = pid }
            }
        }
        do {
            let provider = try await model.createProvider(
                type: effectiveDriver,
                label: name.trimmingCharacters(in: .whitespaces),
                config: try JSONSerialization.data(withJSONObject: dict)
            )
            await model.selectProvider(provider.id)
        } catch {
            self.error = PsmithError.display(error)
        }
    }
}

/// Which call-settings fields differ between two layers, by name, for
/// the save bar.
enum CallSettingsDiff {
    static func changed(from a: PsmithCallSettings, to b: PsmithCallSettings) -> [String] {
        var out: [String] = []
        if a.temperature != b.temperature { out.append("Temperature") }
        if a.topP != b.topP { out.append("Top P") }
        if a.maxOutputTokens != b.maxOutputTokens { out.append("Max output tokens") }
        if a.topK != b.topK { out.append("Top K") }
        if a.stopSequences != b.stopSequences { out.append("Stop sequences") }
        if a.thinking != b.thinking { out.append("Thinking effort") }
        if a.explicitCache != b.explicitCache { out.append("Long cache") }
        if a.anthropic != b.anthropic { out.append("Anthropic settings") }
        if a.openai != b.openai { out.append("OpenAI settings") }
        if a.google != b.google { out.append("Google settings") }
        return out
    }
}
