import SwiftUI
import PsmithKit
import PsmithUI

/// A new conversation before its first message: pick who you're talking
/// to (DraftStart). Nothing exists on the server until you send. With
/// no profiles at all it points to Settings instead (DraftNoProfile).
struct DraftStart: View {
    let model: ConversationViewModel
    let profiles: [PsmithProfile]
    /// The profile of the conversation you touched last.
    var lastUsedProfileID: String?
    let onOpenSettings: () -> Void
    @Environment(\.theme) private var theme

    private var choices: [PsmithProfile] {
        // Last used first, then favorites, otherwise the list's own order.
        let usable = profiles.filter { !$0.parentOnly }
        func rank(_ p: PsmithProfile) -> Int { p.id == lastUsedProfileID ? 0 : (p.favorite ? 1 : 2) }
        return usable.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    var body: some View {
        if choices.isEmpty {
            empty
        } else {
            picker
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Who are you talking to?")
                .font(.system(size: 22, weight: .bold)).tracking(-0.4)
                .foregroundStyle(IK.text)
            Text("A profile sets the system message, the model and the plugins. Nothing is saved until you send.")
                .cssLines(size: 14, lineHeight: 20).foregroundStyle(IK.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { i, p in
                    row(p)
                        .overlay(alignment: .top) {
                            if i > 0 { Rectangle().fill(IK.wash(0.07)).frame(height: 1).padding(.leading, 34) }
                        }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(IK.wash(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.06), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Profile")
            .padding(.top, 18)
            Button(action: onOpenSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                    Text("New profile").font(.system(size: 15))
                }
                .foregroundStyle(theme.accentInk)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }

    private func row(_ p: PsmithProfile) -> some View {
        let selected = model.draftProfile?.id == p.id
        return Button {
            guard !selected else { return }
            Haptics.impact(.light)
            Task { await model.chooseDraftProfile(p) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(ProfileColor.color(for: p.id, theme: theme)).frame(width: 10, height: 10).padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(p.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(IK.text).lineLimit(1)
                        if p.favorite && p.id != lastUsedProfileID {
                            Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(IK.orange)
                        }
                        if p.id == lastUsedProfileID {
                            Text("Last used")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(theme.accentInk)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(Capsule().fill(theme.accent.opacity(0.22)))
                        }
                    }
                    .frame(minHeight: 21)
                    if !p.description.isEmpty {
                        Text(p.description).cssLines(size: 13.5, lineHeight: 18).foregroundStyle(IK.secondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, theme.accent)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 64)
            .background(selected ? theme.accent.opacity(0.16) : .clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(theme.accent).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var empty: some View {
        VStack(spacing: 0) {
            Image(systemName: "person")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(IK.secondary)
                .frame(width: 64, height: 64)
                .background(Circle().fill(IK.wash(0.06)))
            Text("No profiles yet")
                .font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                .foregroundStyle(IK.text)
                .padding(.top, 18)
            Text("A profile sets the system message, the model and the plugins. Make one in Settings, then start here.")
                .cssLines(size: 15, lineHeight: 21).foregroundStyle(IK.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Button(action: onOpenSettings) {
                Text("Open Profiles Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .frame(height: 50)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 26)
        }
        .padding(.horizontal, 16)
        // The boards set the empty state at 250pt on an 844pt phone: 121
        // under the top of the content, less the scroll padding.
        .padding(.top, 121)
        .frame(maxWidth: .infinity)
    }
}
