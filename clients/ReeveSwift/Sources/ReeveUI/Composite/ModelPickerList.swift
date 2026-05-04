import SwiftUI
import ReeveKit

// MARK: - Reusable model picker list
//
// The view that does the actual rendering — provider sections with
// logo headers, sorted model rows with the per-model metadata strip
// (clickable for the popover), accent-bordered selected row.
// Stateless, layout-only — both the full-pane composer-target on
// macOS/iOS and ProfileForm's inline expansion (one of three
// default-model fields) embed this.

public struct ModelPickerList: View {
    let models: [ReeveUserModel]
    let providerLabels: [String: String]
    let providerTypes: [String: String]
    let providerPresetIDs: [String: String]
    /// Currently-selected (providerID, modelID). Either nil → no row
    /// gets the accent border (used by ProfileForm where "unset"
    /// means inherit from parent).
    let selectedProviderID: String?
    let selectedModelID: String?
    /// Optional "(unset — inherit)" affordance shown above the list.
    /// When non-nil, the embedding form uses it to clear both
    /// bindings. `unsetDescription` overrides the row's caption — each
    /// caller wants different copy (default model: "use parent
    /// profile's", title: "use parent or skip auto-titling",
    /// compression: "use parent compression model").
    let onUnset: (() -> Void)?
    let unsetDescription: String?
    let onSelect: (_ providerID: String, _ modelID: String) -> Void

    @Environment(\.theme) private var theme

    public init(
        models: [ReeveUserModel],
        providerLabels: [String: String],
        providerTypes: [String: String],
        providerPresetIDs: [String: String],
        selectedProviderID: String?,
        selectedModelID: String?,
        onUnset: (() -> Void)? = nil,
        unsetDescription: String? = nil,
        onSelect: @escaping (_ providerID: String, _ modelID: String) -> Void
    ) {
        self.models = models
        self.providerLabels = providerLabels
        self.providerTypes = providerTypes
        self.providerPresetIDs = providerPresetIDs
        self.selectedProviderID = selectedProviderID
        self.selectedModelID = selectedModelID
        self.onUnset = onUnset
        self.unsetDescription = unsetDescription
        self.onSelect = onSelect
    }

    public var body: some View {
        if models.isEmpty {
            EmptyStateView(
                "No models available",
                systemImage: "cpu",
                description: "Configure a provider in Settings to enable models."
            )
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let onUnset {
                    UnsetRow(isSelected: selectedProviderID == nil && selectedModelID == nil,
                             description: unsetDescription ?? "Use parent profile's setting.",
                             accent: theme.accent,
                             onSelect: onUnset)
                }
                ForEach(grouped, id: \.providerID) { group in
                    providerSection(group)
                }
            }
        }
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
                        isSelected: m.modelID == selectedModelID
                            && m.providerID == selectedProviderID,
                        onSelect: { onSelect(m.providerID, m.modelID) }
                    )
                }
            }
        }
    }

    private var grouped: [GroupedProvider] {
        let byProvider = Dictionary(grouping: models, by: \.providerID)
        return byProvider.keys.sorted { lhs, rhs in
            (providerLabels[lhs] ?? lhs) < (providerLabels[rhs] ?? rhs)
        }.compactMap { id in
            guard let ms = byProvider[id], !ms.isEmpty else { return nil }
            return GroupedProvider(
                providerID: id,
                label: providerLabels[id] ?? id,
                logoSlug: logoSlug(for: id),
                models: ms.sorted { $0.displayName < $1.displayName }
            )
        }
    }

    private func logoSlug(for providerID: String) -> String? {
        switch providerTypes[providerID] {
        case "anthropic": return "anthropic"
        case "google":    return "google-color"
        case "openai-compatible":
            return providerPresetIDs[providerID]
        default:
            return nil
        }
    }

    private struct GroupedProvider {
        let providerID: String
        let label: String
        let logoSlug: String?
        let models: [ReeveUserModel]
    }
}

// MARK: - Picker row (used by ModelPickerList)

private struct PickerModelRow: View {
    let model: ReeveUserModel
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

/// "(unset — inherit)" affordance shown at the top of the list when
/// the embedding form supports clearing the selection (profile form's
/// default/compression/title pickers — selecting nothing means inherit
/// from parent profile or skip the action). Hidden in the conversation
/// picker, where you must always have an explicit model.
private struct UnsetRow: View {
    let isSelected: Bool
    let description: String
    let accent: Color
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unset — inherit")
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? accent.opacity(0.10) : Color.primary.opacity(0.025))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(accent.opacity(0.4)) : AnyShapeStyle(.separator),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
