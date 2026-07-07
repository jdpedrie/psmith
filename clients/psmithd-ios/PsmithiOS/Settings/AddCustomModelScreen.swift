import SwiftUI
import PsmithKit
import PsmithUI

/// Pushed screen for adding a manually-described model to a provider —
/// for models outside the catalog and outside driver discovery (brand-new
/// releases, fine-tunes, aliases on self-hosted gateways). Commits via
/// `ProvidersViewModel.addManualModel`; the resulting row carries
/// `metadata_source = 'manual'`.
///
/// Mirrors the Mac ModelEditForm's add-mode field set. Per-model default
/// call settings are deliberately not part of this form yet (see
/// docs/todo.md); the Mac form remains the place to set those on add.
struct AddCustomModelScreen: View {
    let provider: PsmithUserModelProvider
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var modelID = ""
    @State private var displayName = ""
    @State private var contextWindowText = ""
    @State private var maxOutputTokensText = ""
    @State private var inputPriceText = ""
    @State private var outputPriceText = ""
    @State private var cacheReadPriceText = ""
    @State private var cacheWritePriceText = ""
    @State private var modalities: Set<String> = ["text"]
    @State private var capStreaming = true
    @State private var capThinking = false
    @State private var capToolUse = false
    @State private var capVision = false
    @State private var capPromptCaching = false
    @State private var cutoffEnabled = false
    @State private var cutoffDate = Date()
    @State private var saving = false
    @State private var error: String?

    private static let modalityChoices: [(key: String, label: String)] = [
        ("text", "Text"), ("image", "Image"), ("audio", "Audio"),
        ("pdf", "PDF"), ("video", "Video"),
    ]

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
                TextField("Display name (optional)", text: $displayName)
            } header: {
                Text("Identity")
            } footer: {
                Text("The model ID is the wire identifier the provider expects. Display name defaults to the ID.")
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

            if let error {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add Custom Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add").fontWeight(.semibold)
                    }
                }
                .disabled(!canSave)
            }
        }
    }

    @MainActor
    private func save() async {
        saving = true
        error = nil
        defer { saving = false }

        let id = modelID.trimmingCharacters(in: .whitespaces)
        var name = displayName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = id }

        do {
            _ = try await app.providers.addManualModel(
                providerID: provider.id,
                modelID: id,
                displayName: name,
                contextWindow: parseInt32(contextWindowText),
                maxOutputTokens: parseInt32(maxOutputTokensText),
                pricing: pricingFromFields(),
                modalities: Self.modalityChoices.map(\.key).filter { modalities.contains($0) },
                capabilities: PsmithModelCapabilities(
                    streaming: capStreaming,
                    thinking: capThinking,
                    toolUse: capToolUse,
                    vision: capVision,
                    promptCaching: capPromptCaching,
                    generatesImages: false
                ),
                knowledgeCutoff: cutoffFromFields(),
                defaultSettings: nil
            )
            // Refresh the provider's enabled list so the detail screen
            // shows the new row immediately on pop.
            await app.providers.selectProvider(provider.id)
            dismiss()
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
