import SwiftUI
import PsmithKit
import PsmithUI

/// Pushed form for a model's user-editable description — one screen,
/// two modes:
///
///  - **Add**: manually describe a model outside the catalog and
///    driver discovery (brand-new releases, fine-tunes, gateway
///    aliases). Commits via `ProvidersViewModel.addManualModel`; the
///    row lands with `metadata_source = 'manual'`.
///  - **Edit**: revise an enabled row's snapshotted metadata. Commits
///    via `updateModelFull` with form-is-truth semantics: every column
///    the form shows is written back exactly as displayed (blank
///    numeric fields clear their columns). Catalog-sourced rows also
///    offer "Refresh from catalog", which re-snapshots the metadata
///    server-side while preserving default settings and favorite.
///
/// Both modes carry the per-model default CallSettings layer behind a
/// pushed subscreen, so add + tune is one pass (Mac parity).
struct ModelFormScreen: View {
    enum Mode {
        case add
        case edit(PsmithUserModel)
    }

    let provider: PsmithUserModelProvider
    let mode: Mode
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var modelID: String
    @State private var displayName: String
    @State private var contextWindowText: String
    @State private var maxOutputTokensText: String
    @State private var inputPriceText: String
    @State private var outputPriceText: String
    @State private var cacheReadPriceText: String
    @State private var cacheWritePriceText: String
    @State private var modalities: Set<String>
    @State private var capStreaming: Bool
    @State private var capThinking: Bool
    @State private var capToolUse: Bool
    @State private var capVision: Bool
    @State private var capPromptCaching: Bool
    @State private var cutoffEnabled: Bool
    @State private var cutoffDate: Date
    @State private var defaultSettings: PsmithCallSettings
    @State private var hasDefaultSettings: Bool
    @State private var saving = false
    @State private var refreshing = false
    @State private var refreshNote: String?
    @State private var error: String?

    init(provider: PsmithUserModelProvider, mode: Mode = .add) {
        self.provider = provider
        self.mode = mode
        let m: PsmithUserModel?
        if case .edit(let existing) = mode { m = existing } else { m = nil }
        _modelID = State(initialValue: m?.modelID ?? "")
        _displayName = State(initialValue: m?.displayName ?? "")
        _contextWindowText = State(initialValue: m?.contextWindow.map(String.init) ?? "")
        _maxOutputTokensText = State(initialValue: m?.maxOutputTokens.map(String.init) ?? "")
        _inputPriceText = State(initialValue: Self.priceText(m?.pricing?.inputPerMillion))
        _outputPriceText = State(initialValue: Self.priceText(m?.pricing?.outputPerMillion))
        _cacheReadPriceText = State(initialValue: Self.priceText(m?.pricing?.cacheReadPerMillion))
        _cacheWritePriceText = State(initialValue: Self.priceText(m?.pricing?.cacheWritePerMillion))
        _modalities = State(initialValue: m.map { Set($0.modalities) } ?? ["text"])
        _capStreaming = State(initialValue: m?.capabilities?.streaming ?? true)
        _capThinking = State(initialValue: m?.capabilities?.thinking ?? false)
        _capToolUse = State(initialValue: m?.capabilities?.toolUse ?? false)
        _capVision = State(initialValue: m?.capabilities?.vision ?? false)
        _capPromptCaching = State(initialValue: m?.capabilities?.promptCaching ?? false)
        let cutoff = m?.knowledgeCutoff.flatMap(Self.parseCutoff)
        _cutoffEnabled = State(initialValue: cutoff != nil)
        _cutoffDate = State(initialValue: cutoff ?? Date())
        _defaultSettings = State(initialValue: m?.defaultSettings ?? PsmithCallSettings())
        _hasDefaultSettings = State(initialValue: m?.defaultSettings != nil)
    }

    private static let modalityChoices: [(key: String, label: String)] = [
        ("text", "Text"), ("image", "Image"), ("audio", "Audio"),
        ("pdf", "PDF"), ("video", "Video"),
    ]

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editedModel: PsmithUserModel? {
        if case .edit(let m) = mode { return m }
        return nil
    }

    private var canSave: Bool {
        !saving && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Model ID (e.g. claude-sonnet-5)", text: $modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .disabled(isEdit)
                    .foregroundStyle(isEdit ? .secondary : .primary)
                TextField("Display name (optional)", text: $displayName)
            } header: {
                Text("Identity")
            } footer: {
                Text(isEdit
                     ? "The model ID is the row's key and can't change — remove the model and re-add it to rename the wire identifier."
                     : "The model ID is the wire identifier the provider expects. Display name defaults to the ID.")
            }

            Section("Limits") {
                LabeledContent("Context window") {
                    TextField("tokens", text: $contextWindowText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Max output") {
                    TextField("tokens", text: $maxOutputTokensText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                LabeledContent("Input") {
                    TextField("USD", text: $inputPriceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Output") {
                    TextField("USD", text: $outputPriceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Cache read") {
                    TextField("USD", text: $cacheReadPriceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Cache write") {
                    TextField("USD", text: $cacheWritePriceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Pricing · per 1M tokens")
            } footer: {
                Text("Used for the cost ledger and the picker's cost badge. Leave blank if unknown.")
            }

            Section("Modalities") {
                ForEach(Self.modalityChoices, id: \.key) { choice in
                    Toggle(choice.label, isOn: Binding(
                        get: { modalities.contains(choice.key) },
                        set: { on in
                            if on { modalities.insert(choice.key) } else { modalities.remove(choice.key) }
                        }
                    ))
                }
            }

            Section {
                Toggle("Streaming", isOn: $capStreaming)
                Toggle("Extended thinking", isOn: $capThinking)
                Toggle("Tool use", isOn: $capToolUse)
                Toggle("Vision", isOn: $capVision)
                Toggle("Prompt caching", isOn: $capPromptCaching)
            } header: {
                Text("Capabilities")
            } footer: {
                Text("Capabilities gate the model picker: profiles that require a capability hide models without it.")
            }

            Section("Knowledge cutoff") {
                Toggle("Set knowledge cutoff", isOn: $cutoffEnabled)
                if cutoffEnabled {
                    DatePicker("Cutoff date", selection: $cutoffDate, displayedComponents: .date)
                }
            }

            // Per-model default CallSettings — the lowest layer of the
            // resolution chain (profile and conversation layers override
            // it). Pushed rather than inline: the full form is a screen
            // of its own.
            Section {
                NavigationLink {
                    ModelDefaultSettingsForm(
                        settings: $defaultSettings,
                        hasSettings: $hasDefaultSettings,
                        driverType: provider.type,
                        capabilities: currentCapabilities,
                        constraints: editedModel?.constraints
                    )
                } label: {
                    LabeledContent("Default call settings") {
                        Text(hasDefaultSettings ? "Configured" : "Not set")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Applied whenever this model runs, below profile and conversation overrides.")
            }

            if isEdit, editedModel?.metadataSource == "catalog" {
                Section {
                    Button {
                        Task { await refreshFromCatalog() }
                    } label: {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh from catalog", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(refreshing || saving)
                    if let refreshNote {
                        Text(refreshNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Re-snapshots the metadata above from the current catalog, discarding hand edits. Default call settings and favorite are kept.")
                }
            }

            if let error {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isEdit ? "Edit Model" : "Add Custom Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isEdit ? "Save" : "Add").fontWeight(.semibold)
                    }
                }
                .disabled(!canSave)
            }
        }
    }

    private var currentCapabilities: PsmithModelCapabilities {
        PsmithModelCapabilities(
            streaming: capStreaming,
            thinking: capThinking,
            toolUse: capToolUse,
            vision: capVision,
            promptCaching: capPromptCaching,
            generatesImages: false
        )
    }

    @MainActor
    private func save() async {
        saving = true
        error = nil
        defer { saving = false }

        let id = modelID.trimmingCharacters(in: .whitespaces)
        var name = displayName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = id }
        let settings: PsmithCallSettings? = hasDefaultSettings ? defaultSettings : nil

        do {
            if isEdit {
                // Form-is-truth: every displayed column writes back
                // exactly as shown. Blank numeric fields clear their
                // columns; the pricing block replaces wholesale (blank
                // subfields clear); modalities/capabilities replace;
                // an empty CallSettings clears the default layer.
                _ = try await app.providers.updateModelFull(
                    providerID: provider.id,
                    modelID: id,
                    displayName: name,
                    contextWindow: parseInt32(contextWindowText),
                    clearContextWindow: parseInt32(contextWindowText) == nil,
                    maxOutputTokens: parseInt32(maxOutputTokensText),
                    clearMaxOutputTokens: parseInt32(maxOutputTokensText) == nil,
                    pricing: pricingFromFields() ?? PsmithModelPricing(
                        inputPerMillion: nil, outputPerMillion: nil,
                        cacheReadPerMillion: nil, cacheWritePerMillion: nil
                    ),
                    modalities: Self.modalityChoices.map(\.key).filter { modalities.contains($0) },
                    capabilities: currentCapabilities,
                    knowledgeCutoff: cutoffFromFields(),
                    clearKnowledgeCutoff: !cutoffEnabled,
                    defaultSettings: settings ?? PsmithCallSettings()
                )
            } else {
                _ = try await app.providers.addManualModel(
                    providerID: provider.id,
                    modelID: id,
                    displayName: name,
                    contextWindow: parseInt32(contextWindowText),
                    maxOutputTokens: parseInt32(maxOutputTokensText),
                    pricing: pricingFromFields(),
                    modalities: Self.modalityChoices.map(\.key).filter { modalities.contains($0) },
                    capabilities: currentCapabilities,
                    knowledgeCutoff: cutoffFromFields(),
                    defaultSettings: settings
                )
            }
            // Refresh the provider's enabled list so the detail screen
            // shows the change immediately on pop.
            await app.providers.selectProvider(provider.id)
            dismiss()
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    @MainActor
    private func refreshFromCatalog() async {
        refreshing = true
        refreshNote = nil
        error = nil
        defer { refreshing = false }
        do {
            let (model, refreshed) = try await app.providers.refreshModelMetadata(
                providerID: provider.id, modelID: modelID
            )
            if refreshed {
                // Re-prefill the form from the fresh snapshot so what's
                // on screen matches what was written.
                displayName = model.displayName
                contextWindowText = model.contextWindow.map(String.init) ?? ""
                maxOutputTokensText = model.maxOutputTokens.map(String.init) ?? ""
                inputPriceText = Self.priceText(model.pricing?.inputPerMillion)
                outputPriceText = Self.priceText(model.pricing?.outputPerMillion)
                cacheReadPriceText = Self.priceText(model.pricing?.cacheReadPerMillion)
                cacheWritePriceText = Self.priceText(model.pricing?.cacheWritePerMillion)
                modalities = Set(model.modalities)
                capStreaming = model.capabilities?.streaming ?? capStreaming
                capThinking = model.capabilities?.thinking ?? capThinking
                capToolUse = model.capabilities?.toolUse ?? capToolUse
                capVision = model.capabilities?.vision ?? capVision
                capPromptCaching = model.capabilities?.promptCaching ?? capPromptCaching
                let cutoff = model.knowledgeCutoff.flatMap(Self.parseCutoff)
                cutoffEnabled = cutoff != nil
                if let cutoff { cutoffDate = cutoff }
                refreshNote = "Metadata refreshed from the catalog."
                await app.providers.selectProvider(provider.id)
            } else {
                refreshNote = "The catalog has no entry for this model; nothing changed."
            }
        } catch {
            self.error = PsmithError.display(error)
        }
    }

    private func pricingFromFields() -> PsmithModelPricing? {
        let input = parseDouble(inputPriceText)
        let output = parseDouble(outputPriceText)
        let cacheRead = parseDouble(cacheReadPriceText)
        let cacheWrite = parseDouble(cacheWritePriceText)
        if input == nil && output == nil && cacheRead == nil && cacheWrite == nil {
            return nil
        }
        return PsmithModelPricing(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheReadPerMillion: cacheRead,
            cacheWritePerMillion: cacheWrite
        )
    }

    private func cutoffFromFields() -> String? {
        guard cutoffEnabled else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: cutoffDate)
    }

    private static func parseCutoff(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: s)
    }

    private static func priceText(_ v: Double?) -> String {
        guard let v else { return "" }
        // %g trims trailing zeros: 3.50 prefills as "3.5", 11.0 as "11".
        return String(format: "%g", v)
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

/// Pushed subscreen hosting the shared CallSettingsForm for the
/// per-model default layer. `hasSettings` distinguishes "not set"
/// (column NULL) from "explicitly empty": editing any control flips it
/// on; Clear resets to not-set.
private struct ModelDefaultSettingsForm: View {
    @Binding var settings: PsmithCallSettings
    @Binding var hasSettings: Bool
    let driverType: String
    let capabilities: PsmithModelCapabilities?
    let constraints: PsmithModelConstraints?

    var body: some View {
        ScrollView {
            CallSettingsForm(
                settings: Binding(
                    get: { settings },
                    set: { newValue in
                        settings = newValue
                        hasSettings = true
                    }
                ),
                inheritedSettings: nil,
                driverType: driverType,
                modelCapabilities: capabilities,
                modelConstraints: constraints
            )
            .padding()
        }
        .navigationTitle("Default Call Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    settings = PsmithCallSettings()
                    hasSettings = false
                }
                .disabled(!hasSettings)
            }
        }
    }
}
