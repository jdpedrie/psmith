import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › Appearance (board SettingsAppearance): a swipeable row of
/// theme cards, each drawn in its own theme, then the transcript and text
/// options. Picking a card applies the theme at once.
struct SettingsAppearance: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        SettingsAppearanceScreen(current: themeStore.current,
                                 select: { themeStore.current = $0 },
                                 showTurnDetails: $prefs.showTurnDetails)
    }
}

struct SettingsAppearanceScreen: View {
    let current: Theme
    let select: (Theme) -> Void
    @Binding var showTurnDetails: Bool

    @State private var offset: CGFloat = 0
    @State private var viewport: CGFloat = 1
    @State private var contentWidth: CGFloat = 1

    var body: some View {
        IKSettingsPage(title: "Appearance") {
            IKSHead("Theme").padding(.top, -4)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Theme.allThemes) { theme in
                            ThemeTile(theme: theme, selected: theme.id == current.id) { select(theme) }
                                .id(theme.id)
                        }
                    }
                    .padding(.trailing, 16)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .onScrollGeometryChange(for: [CGFloat].self) { g in
                    [g.contentOffset.x, g.containerSize.width, g.contentSize.width]
                } action: { _, v in
                    offset = v[0]; viewport = max(v[1], 1); contentWidth = max(v[2], 1)
                }
                .onAppear { proxy.scrollTo(current.id, anchor: .leading) }
            }
            .padding(.trailing, -16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Theme")
            pageDots.padding(.top, 10)

            IKSFooter("Sets the accent, your bubbles, the highlight and the app icon. \(current.blurb)", top: 59)

            IKSHead("Transcript")
            IKGroup {
                IKSRow(vertical: 10) {
                    IKSToggle(title: "Show turn details", isOn: $showTurnDetails) {
                        IKSTitleNote(title: "Show turn details",
                                     note: "Role labels, the model on every reply, token counts and times.")
                    }
                }
            }
            IKSFooter("Off, the transcript keeps what’s worth noticing: a model change, a poor cache on a big prompt, a reply that stopped early.")

            IKSHead("Text")
            IKGroup {
                IKSRow(vertical: 10) {
                    Text("Text size").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Follows iOS").font(.system(size: 15)).foregroundStyle(IK.secondary)
                }
            }
            IKSFooter("Psmith uses Dynamic Type. Change it in iOS Settings › Display.")
        }
    }

    private var pages: Int { max(1, Int((contentWidth / viewport).rounded(.up))) }
    private var page: Int { min(pages - 1, max(0, Int((offset / viewport).rounded()))) }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pages, id: \.self) { i in
                Circle().fill(i == page ? IK.strong : IK.wash(0.25)).frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// One theme, drawn in its own colors: a sample exchange, its swatches and
/// its name.
private struct ThemeTile: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Capital of Japan?")
                    .font(.system(size: 12))
                    .foregroundStyle(IK.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.bubble))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("Tokyo.").font(.system(size: 12)).foregroundStyle(IK.text).opacity(0.85)
                HStack(spacing: 4) {
                    Capsule().fill(theme.accent)
                    Capsule().fill(theme.bubble)
                    Capsule().fill(theme.highlight)
                }
                .frame(height: 8)
                HStack {
                    Text(theme.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(IK.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(theme.accent)
                    } else {
                        Circle().strokeBorder(IK.wash(0.25), lineWidth: 1.5).frame(width: 18, height: 18)
                    }
                }
            }
            .padding(10)
            .frame(width: 148)
            .background(RoundedRectangle(cornerRadius: 16).fill(theme.chrome))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? theme.accent : IK.wash(0.08), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .environment(\.theme, theme)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
