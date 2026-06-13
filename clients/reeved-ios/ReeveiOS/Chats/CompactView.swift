import SwiftUI
import ReeveKit
import ReeveUI

/// iOS compact form — sheet (`.large` detent) per
/// `docs/clients/ios-reference.md` Inside: NavigationStack with title
/// "Compact", leading "Cancel" + trailing "Compact" buttons. Body =
/// prompt textarea + model picker (via shared ModelPickerList).
struct CompactView: View {
    @Bindable var model: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.preparingCompactView {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            summaryHeader
                            promptSection
                            modelSection
                            if let err = model.compactError {
                                errorBanner(err)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationTitle("Compact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await model.compact(
                                guide: model.compactPromptDraft,
                                providerID: model.compactProviderID,
                                modelID: model.compactModelID
                            )
                            dismiss()
                        }
                    } label: {
                        Text("Compact")
                            .fontWeight(.semibold)
                    }
                    .disabled(model.compactProviderID == nil
                              || model.compactModelID == nil
                              || model.isCompacting)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await model.prepareCompactView()
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compact this context")
                .font(.headline)
            Text("Summarises the conversation so far. The summary lands as a new message you review and confirm before continuing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compaction prompt")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $model.compactPromptDraft)
                .frame(minHeight: 140)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ModelPickerList(
                models: model.availableModels,
                providerLabels: model.providerLabels,
                providerTypes: model.providerTypes,
                providerPresetIDs: model.providerPresetIDs,
                selectedProviderID: model.compactProviderID,
                selectedModelID: model.compactModelID,
                onSelect: { providerID, modelID in
                    model.compactProviderID = providerID
                    model.compactModelID = modelID
                }
            )
        }
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err)
                .font(.callout)
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
