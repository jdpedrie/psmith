import SwiftUI
import PsmithKit
import PsmithUI

/// The "Choose a Profile" pane at the top of a new conversation, before
/// its first message. Collapsed it names the chosen profile; expanded it
/// is a horizontal strip of profile cards, and tapping one restarts the
/// draft from that profile (seed preview, default model). The pane goes
/// away with the draft, at the first send.
///
/// Starts expanded when there is no default profile, since nothing can
/// be sent until a profile is picked.
struct DraftProfilePane: View {
    let model: ConversationViewModel
    let profiles: [PsmithProfile]
    @State private var expanded: Bool

    init(model: ConversationViewModel, profiles: [PsmithProfile]) {
        self.model = model
        self.profiles = profiles
        _expanded = State(initialValue: model.draftProfile == nil)
    }

    /// Favorites first, then by name. Parent-only profiles exist to be
    /// inherited from and can't start a conversation.
    private var choices: [PsmithProfile] {
        profiles
            .filter { !$0.parentOnly }
            .sorted {
                if $0.favorite != $1.favorite { return $0.favorite }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(choices) { profile in
                            card(profile)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.secondarySystemBackground).opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .clipped()
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle.stack")
                    .foregroundStyle(.secondary)
                Text("Choose a Profile")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let chosen = model.draftProfile {
                    Text(chosen.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose a profile")
        .accessibilityValue(model.draftProfile?.name ?? "None chosen")
        .accessibilityHint(expanded ? "Collapses the profile list" : "Shows the profile list")
    }

    private func card(_ profile: PsmithProfile) -> some View {
        let selected = model.draftProfile?.id == profile.id
        return Button {
            guard !selected else { return }
            Haptics.impact(.light)
            Task { await model.chooseDraftProfile(profile) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if profile.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                Text(profile.description.isEmpty ? " " : profile.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if profile.isDefault {
                    Text("Default")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 180, height: 104, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color(.systemBackground)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(profile.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
