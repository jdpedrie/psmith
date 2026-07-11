import SwiftUI
import PsmithKit
import PsmithUI

// MARK: - Conversation full-pane wrapper

/// Full-pane model picker shown when the user taps the model chip in the
/// conversation composer. Sibling to ContextListPane / CompactPane /
/// ConversationSettingsView — page-replaces-pane pattern, back navigation
/// in the toolbar.
///
/// The reusable list rendering lives in `PsmithUI/ModelPickerList`; this
/// file only contains the Mac-specific page wrapper (title-bar inset,
/// header label, dismiss-on-pick wiring through the conversation VM).
struct ConversationModelPicker: View {
    @Bindable var model: ConversationViewModel

    var body: some View {
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
                            model.showingModelPicker = false
                        }
                    }
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 28) // title-bar overlay inset, matches other panes
    }

    private var providerCount: Int {
        Set(model.availableModels.map(\.providerID)).count
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(.caption, weight: .semibold)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }
}
