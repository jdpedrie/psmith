import SwiftUI
import PsmithKit
import PsmithUI

/// A new conversation before its first message (board AppDraft): who
/// you're talking to, as a grid of profiles, over the composer.
struct DraftStartView: View {
    let model: ConversationViewModel
    let profiles: [PsmithProfile]
    @Environment(\.theme) private var theme
    @Environment(Navigator.self) private var navigator
    @State private var visibleHeight: CGFloat = 0

    private var choices: [PsmithProfile] {
        profiles
            .filter { !$0.parentOnly }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                if $0.favorite != $1.favorite { return $0.favorite }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        // Centered when the profiles fit, scrolling when they don't: the
        // column is at least the visible height (inside the title bar's
        // inset), never exactly it.
        ScrollView {
            MKColumn {
                VStack(spacing: 0) {
                    Text("Who are you talking to?").sk(20, weight: .bold)
                    Text("A profile sets the system message, the model and the plugins. Nothing is saved until you send.")
                        .sk(12.5, SK.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 5)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                        ForEach(choices) { card($0) }
                        Button {
                            navigator.showSettings(.profiles)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                                Text("New Profile").sk(13, SK.secondary)
                            }
                            .foregroundStyle(SK.secondary)
                            .frame(maxWidth: .infinity, minHeight: 84)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 20)
                }
            }
            .padding(.vertical, 24)
            .frame(minHeight: visibleHeight, alignment: .center)
        }
        .onScrollGeometryChange(for: CGFloat.self) { g in
            g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom
        } action: { _, h in
            visibleHeight = max(0, h)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectHidden(true, for: .top)
    }

    private func card(_ profile: PsmithProfile) -> some View {
        let selected = model.draftProfile?.id == profile.id
        return Button {
            guard !selected else { return }
            Task { await model.chooseDraftProfile(profile) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle().fill(ProfileColor.of(profile.id)).frame(width: 8, height: 8)
                    Text(profile.name).sk(13, weight: .semibold).lineLimit(1)
                    Spacer(minLength: 0)
                    if profile.isDefault {
                        SKChip(text: "Default", color: selected ? theme.accentInk : SK.secondary)
                    } else if profile.favorite {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color(hex: 0xF5C451))
                    }
                }
                Text(profile.description.isEmpty ? "No description." : profile.description)
                    .sk(12, SK.secondary)
                    .skLineHeight(12, 16.0 / 12)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? theme.accent.opacity(0.18) : MK.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? theme.accent : SK.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(profile.description.isEmpty ? profile.name : profile.description)
    }
}

enum ProfileColor {
    static let palette: [Color] = [
        Color(red: 0.30, green: 0.59, blue: 0.85),
        Color(red: 0.24, green: 0.64, blue: 0.43),
        Color(red: 0.72, green: 0.49, blue: 0.79),
        Color(red: 0.89, green: 0.44, blue: 0.23),
        Color(red: 0.78, green: 0.64, blue: 0.23),
        Color(red: 0.16, green: 0.61, blue: 0.76),
        Color(red: 0.85, green: 0.42, blue: 0.55),
    ]

    static func of(_ id: String) -> Color {
        // FNV-1a: stable across launches, unlike hashValue.
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return palette[Int(h % UInt64(palette.count))]
    }
}
