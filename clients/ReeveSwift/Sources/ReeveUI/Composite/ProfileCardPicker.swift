import SwiftUI
import ReeveKit

// MARK: - ProfileCard

/// Compact card representation of a profile. Shows the name, the parent
/// chain, the description, and two small affordances: favorite (yellow
/// star) and "open in settings" (gear). The card itself is a button that
/// drives selection — the embedded buttons stop event propagation so they
/// don't double as a select.
///
/// Used inside `ProfilePickerRow` and (eventually) the new-conversation
/// page; sized to feel comfortable in a single-row horizontal scroller.
public struct ProfileCard: View {
    let profile: ReeveProfile
    /// Pre-resolved `parentChainName(for:)` from ProfilesViewModel.
    let parentChain: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.theme) private var theme

    public init(
        profile: ReeveProfile,
        parentChain: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.profile = profile
        self.parentChain = parentChain
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                if !parentChain.isEmpty {
                    Text(parentChain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !profile.description.isEmpty {
                    Text(profile.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 260, height: 116, alignment: .topLeading)
            .background(cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : Color.white.opacity(0.06),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(profile.name)
                .font(.headline)
                .lineLimit(1)
            if profile.parentOnly {
                Text("PARENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }
            Spacer(minLength: 4)
            Button(action: onToggleFavorite) {
                Image(systemName: profile.favorite ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(profile.favorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(profile.favorite ? "Unfavorite" : "Mark as favorite")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open in Settings")
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isSelected {
            theme.accent.opacity(0.18)
        } else {
            Color.white.opacity(0.04)
        }
    }
}

// MARK: - "(none)" sentinel card for the parent picker

/// Used by the "Inherits from" picker to represent the no-parent option.
public struct NoneProfileCard: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.theme) private var theme

    public init(isSelected: Bool, onSelect: @escaping () -> Void) {
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Standalone")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("No parent profile.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 200, height: 116, alignment: .topLeading)
            .background(isSelected ? theme.accent.opacity(0.18) : Color.white.opacity(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accent : Color.white.opacity(0.06),
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [4])
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ProfilePickerRow

/// Horizontal-scroll card picker that replaces the old `Picker` dropdowns
/// for selecting profiles. Favorites bubble to the front; an optional
/// filter field appears once the list grows past a small threshold.
public struct ProfilePickerRow: View {
    @Bindable var model: ProfilesViewModel
    @Binding var selectedID: String?

    /// When true, includes the special "(none)" card for parent-of pickers
    /// and binds it to a nil selection. The user-visible selection target
    /// is `String?`, so nil means "no parent."
    var includeNoneOption: Bool = false

    /// When false (default), profiles with `parentOnly = true` are hidden.
    /// Set true for the parent picker, where templates are exactly what we
    /// want to surface.
    var allowParentOnly: Bool = false

    /// Profile to exclude from the list (used by the parent picker to drop
    /// the profile being edited so it can't pick itself as a parent).
    var excludeID: String? = nil

    /// Caller-provided "open this profile in settings" handler. Mac wires
    /// this through its `Navigator`; iOS will route via `NavigationStack`
    /// or a sheet. Either way, the card view doesn't need to know.
    var onOpenSettings: (String) -> Void

    @State private var filterText: String = ""

    public init(
        model: ProfilesViewModel,
        selectedID: Binding<String?>,
        includeNoneOption: Bool = false,
        allowParentOnly: Bool = false,
        excludeID: String? = nil,
        onOpenSettings: @escaping (String) -> Void
    ) {
        self.model = model
        self._selectedID = selectedID
        self.includeNoneOption = includeNoneOption
        self.allowParentOnly = allowParentOnly
        self.excludeID = excludeID
        self.onOpenSettings = onOpenSettings
    }

    private var filtered: [ReeveProfile] {
        let base = model.sortedForPicker
            .filter { allowParentOnly || !$0.parentOnly }
            .filter { excludeID == nil || $0.id != excludeID }
        guard !filterText.isEmpty else { return base }
        let q = filterText.lowercased()
        return base.filter {
            $0.name.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
        }
    }

    /// Filter input shows up once the list is big enough that scanning
    /// becomes work. Cheaper to leave hidden when there are only a few.
    private var showsFilter: Bool {
        let pickable = model.profiles
            .filter { allowParentOnly || !$0.parentOnly }
            .filter { excludeID == nil || $0.id != excludeID }
        return pickable.count > 4
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsFilter {
                TextField("Filter profiles…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if includeNoneOption {
                        NoneProfileCard(
                            isSelected: selectedID == nil,
                            onSelect: { selectedID = nil }
                        )
                    }
                    ForEach(filtered) { p in
                        ProfileCard(
                            profile: p,
                            parentChain: model.parentChainName(for: p),
                            isSelected: selectedID == p.id,
                            onSelect: { selectedID = p.id },
                            onToggleFavorite: { Task { await model.toggleFavorite(p.id) } },
                            onOpenSettings: { onOpenSettings(p.id) }
                        )
                    }
                    if filtered.isEmpty && !includeNoneOption {
                        Text("No profiles match.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 2) // keep selected outline from clipping
                .padding(.vertical, 2)
            }
        }
    }
}
