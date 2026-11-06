import SwiftUI
import PsmithKit
import PsmithUI

/// The "Choose a Profile" pane at the top of a new conversation, before
/// its first message. Collapsed it names the chosen profile; expanded it
/// is a row of profile cards, and clicking one restarts the draft from
/// that profile (seed preview, default model). The pane goes away with
/// the draft, at the first send. Same design as the iOS pane.
///
/// Starts expanded when there's no default profile, since nothing can be
/// sent until one is picked.
struct DraftProfilePaneMac: View {
    @Environment(\.theme) private var theme
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
                        ForEach(choices) { card($0) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle.stack")
                    .foregroundStyle(theme.accent)
                Text("Choose a Profile")
                    .scaledFont(.callout, weight: .semibold)
                if let chosen = model.draftProfile {
                    Text(chosen.name)
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .scaledFont(.caption, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide profiles" : "Show profiles")
    }

    private func card(_ profile: PsmithProfile) -> some View {
        let selected = model.draftProfile?.id == profile.id
        return Button {
            guard !selected else { return }
            Task { await model.chooseDraftProfile(profile) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .scaledFont(.callout, weight: .semibold)
                        .lineLimit(1)
                    if profile.favorite {
                        Image(systemName: "star.fill")
                            .scaledFont(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accent)
                    }
                }
                Text(profile.description.isEmpty ? " " : profile.description)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if profile.isDefault {
                    Text("Default")
                        .scaledFont(.caption2, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 190, height: 100, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? AnyShapeStyle(theme.accent.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? theme.accent.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(profile.description.isEmpty ? profile.name : profile.description)
    }
}
