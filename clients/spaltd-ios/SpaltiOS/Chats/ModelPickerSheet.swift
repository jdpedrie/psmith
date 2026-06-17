import SwiftUI
import SpaltKit
import SpaltUI

/// iOS model picker — sheet (`.medium`/`.large` detents) per
/// `docs/clients/ios-reference.md` Wraps the shared `ModelPickerList`.
/// Tapping a model selects it on the view-model and dismisses.
struct ModelPickerSheet: View {
    @Bindable var model: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.availableModels.isEmpty {
                        sectionLabel("\(model.availableModels.count) models across \(providerCount) provider\(providerCount == 1 ? "" : "s")")
                            .padding(.horizontal, 4)
                    }
                    ModelPickerList(
                        models: model.availableModels,
                        providerLabels: model.providerLabels,
                        providerTypes: model.providerTypes,
                        providerPresetIDs: model.providerPresetIDs,
                        selectedProviderID: model.selectedProviderID,
                        selectedModelID: model.selectedModelID,
                        requiredCapabilities: model.activeProfileRequiredCapabilities,
                        onSelect: { providerID, modelID in
                            Task {
                                await model.selectModel(providerID: providerID, modelID: modelID)
                                dismiss()
                            }
                        }
                    )
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var providerCount: Int {
        Set(model.availableModels.map(\.providerID)).count
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }
}
