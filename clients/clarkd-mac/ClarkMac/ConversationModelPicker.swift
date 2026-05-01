import SwiftUI
import ClarkKit

/// Full-pane model picker shown when the user taps the model chip in the
/// conversation composer. Replaces the legacy system Menu dropdown which
/// flattened the list and lost the per-model metadata. Sibling to
/// ContextListPane / CompactPane / ConversationSettingsView — same
/// page-replaces-pane pattern, back navigation lives in the toolbar.
///
/// Models are grouped by provider with the provider's logo in each
/// section header. Each row mirrors the providers settings page: model
/// display name + the same clickable ModelMetaStrip (ctx · cost · caps,
/// tap for the full popover). Tapping a row selects + dismisses.
struct ConversationModelPicker: View {
    @Bindable var model: ConversationViewModel

    var body: some View {
        Group {
            if model.availableModels.isEmpty {
                EmptyStateView(
                    "No models available",
                    systemImage: "cpu",
                    description: "Configure a provider in Settings to enable models."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionLabel("\(model.availableModels.count) models across \(grouped.count) provider\(grouped.count == 1 ? "" : "s")")
                            .padding(.horizontal, 4)
                        ForEach(grouped, id: \.providerID) { group in
                            providerSection(group)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 28) // title-bar overlay inset, matches other panes
    }

    private func providerSection(_ group: GroupedProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderLogo(slug: group.logoSlug, size: 18)
                    .foregroundStyle(.secondary)
                Text(group.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 6) {
                ForEach(group.models) { m in
                    PickerModelRow(
                        model: m,
                        providerLabel: group.label,
                        isSelected: m.modelID == model.selectedModelID
                            && m.providerID == model.selectedProviderID,
                        onSelect: {
                            Task {
                                await model.selectModel(providerID: m.providerID, modelID: m.modelID)
                                model.showingModelPicker = false
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Grouping

    /// Provider-grouped slice of `availableModels` for ForEach. Sorted
    /// by provider label so the section order is stable across
    /// reloads. The first group also surfaces the provider's logo
    /// slug (anthropic/google → static; openai-compatible → preset id
    /// from providerPresetIDs).
    private var grouped: [GroupedProvider] {
        let byProvider = Dictionary(grouping: model.availableModels, by: \.providerID)
        return byProvider.keys.sorted { lhs, rhs in
            (model.providerLabels[lhs] ?? lhs) < (model.providerLabels[rhs] ?? rhs)
        }.compactMap { id in
            guard let models = byProvider[id], !models.isEmpty else { return nil }
            return GroupedProvider(
                providerID: id,
                label: model.providerLabels[id] ?? id,
                logoSlug: logoSlug(for: id),
                models: models.sorted { $0.displayName < $1.displayName }
            )
        }
    }

    private func logoSlug(for providerID: String) -> String? {
        switch model.providerTypes[providerID] {
        case "anthropic": return "anthropic"
        case "google":    return "google-color"
        case "openai-compatible":
            return model.providerPresetIDs[providerID]
        default:
            return nil
        }
    }

    private struct GroupedProvider {
        let providerID: String
        let label: String
        let logoSlug: String?
        let models: [ClarkUserModel]
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }
}

// MARK: - Picker row

/// A single model entry in the picker. Tap-to-select; the inner
/// ModelMetaStrip stays interactive (its own popover-on-tap) since it
/// uses a Button — SwiftUI dispatches to the inner button when the
/// click lands on it, falling through to this row's onSelect otherwise.
private struct PickerModelRow: View {
    let model: ClarkUserModel
    let providerLabel: String?
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(.primary)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.accent)
                                .font(.caption)
                        }
                    }
                    ModelMetaStrip(snapshot: model.metaSnapshot(providerLabel: providerLabel))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? theme.accent.opacity(0.10) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(theme.accent.opacity(0.4)) : AnyShapeStyle(.separator),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
