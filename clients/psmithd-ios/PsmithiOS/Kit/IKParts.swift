import SwiftUI
import PsmithUI

// Shared parts for the redesign. Measurements come from the boards' CSS
// (Tokens and parts on the canvas); a part used on two screens is defined
// here once so the screens can't drift apart.

// MARK: - Glass

/// Where a glass surface sits decides its tint: themed screens tint glass
/// with the theme's chrome, Settings with neutral gray.
enum IKGround { case themed, settings }

struct IKGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var ground: IKGround = .themed
    var prominent: Color?
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.glassEffect(glass, in: shape)
    }

    private var glass: Glass {
        if let prominent { return .regular.tint(prominent).interactive() }
        switch ground {
        case .themed: return .regular.tint(theme.glassTint).interactive()
        case .settings: return .regular.tint(IK.settingsGlassTint).interactive()
        }
    }
}

extension IK {
    static let settingsGlassTint = Color.dynamic(light: Color.white.opacity(0.7),
                                                 dark: Color(red: 40 / 255, green: 46 / 255, blue: 54 / 255).opacity(0.6))
}

extension View {
    func ikGlass<S: Shape>(in shape: S, ground: IKGround = .themed, prominent: Color? = nil) -> some View {
        modifier(IKGlassModifier(shape: shape, ground: ground, prominent: prominent))
    }
}

// MARK: - Navigation

/// A 44pt glass circle: back buttons, the context gauge, select.
struct IKGlassCircle<Label: View>: View {
    var ground: IKGround = .themed
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(IK.text)
        .ikGlass(in: Circle(), ground: ground)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct IKBackButton: View {
    var ground: IKGround = .themed
    var label = "Back"
    let action: () -> Void

    var body: some View {
        IKGlassCircle(ground: ground, accessibilityLabel: label, action: action) {
            Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
        }
    }
}

/// A glass capsule action in a nav row: "Edit", "Call Settings", "Add".
struct IKGlassCapsule: View {
    let title: String
    var ground: IKGround = .themed
    var prominent: Color?
    var weight: Font.Weight = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: weight))
                .foregroundStyle(prominent == nil ? IK.text : .white)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .ikGlass(in: Capsule(), ground: ground, prominent: prominent)
    }
}

/// The pushed-page navigation row: 48pt tall at the top safe area, back at
/// the leading edge, a centered 17pt title, actions at the trailing edge.
struct IKNavRow<Trailing: View>: View {
    let title: String
    var ground: IKGround = .themed
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(IK.text)
                .lineLimit(1)
                .padding(.horizontal, 60)
            HStack(spacing: 8) {
                IKBackButton(ground: ground, action: onBack)
                Spacer(minLength: 0)
                trailing
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 12)
    }
}

extension IKNavRow where Trailing == EmptyView {
    init(title: String, ground: IKGround = .themed, onBack: @escaping () -> Void) {
        self.init(title: title, ground: ground, onBack: onBack) { EmptyView() }
    }
}

/// Root pages' 30pt large title.
struct IKLargeTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.6)
            .foregroundStyle(IK.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

// MARK: - Groups and rows

/// Section head: 13pt semibold tertiary, sentence case.
struct IKSectionHead<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(text)
            Spacer(minLength: 0)
            trailing
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(IK.tertiary)
        .padding(EdgeInsets(top: 18, leading: 4, bottom: 6, trailing: 4))
    }
}

extension IKSectionHead where Trailing == EmptyView {
    init(_ text: String) { self.init(text: text) { EmptyView() } }
}

/// The note under a group.
struct IKFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(IK.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 6, leading: 4, bottom: 0, trailing: 4))
    }
}

/// A rounded group of rows. Settings groups sit on the neutral card;
/// themed ones (conversation info, models) on a faint wash.
struct IKGroup<Content: View>: View {
    var ground: IKGround = .settings
    /// Leading inset of the separators: 14 for plain rows, 52 past an icon.
    var separatorInset: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    row.overlay(alignment: .top) {
                        if i > 0 {
                            Rectangle().fill(IK.wash(ground == .settings ? 0.07 : 0.06)).frame(height: 1)
                                .padding(.leading, separatorInset)
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(ground == .settings ? IK.settingsGroup : IK.wash(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.ring(ground == .settings ? 0.05 : 0.06), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// A Settings row: title on the left, an optional value, an optional
/// chevron. 44pt minimum.
struct IKRow<Accessory: View>: View {
    let title: String
    var detail: String?
    var value: String?
    var chevron = false
    var titleColor: Color = IK.text
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(titleColor)
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(IK.secondary).lineSpacing(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value).font(.system(size: 15)).foregroundStyle(IK.secondary).monospacedDigit().lineLimit(1)
            }
            accessory
            if chevron { IKChevron() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, detail == nil ? 0 : 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension IKRow where Accessory == EmptyView {
    init(_ title: String, detail: String? = nil, value: String? = nil, chevron: Bool = false, titleColor: Color = IK.text) {
        self.init(title: title, detail: detail, value: value, chevron: chevron, titleColor: titleColor) { EmptyView() }
    }
}

struct IKChevron: View {
    var down = false
    var body: some View {
        Image(systemName: down ? "chevron.down" : "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(IK.chevron)
    }
}

/// A Settings row icon: 28pt rounded tile.
struct IKRowIcon: View {
    let systemImage: String
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15))
            .foregroundStyle(IK.strong)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(IK.wash(0.08)))
    }
}

// MARK: - Buttons

enum IKButtonKind { case plain, primary, destructive, text }

struct IKButtonStyle: ButtonStyle {
    var kind: IKButtonKind = .plain
    /// 36pt in confirm cards and rows, 40pt in composer-slot cards.
    var height: CGFloat = 36
    var fill = false
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: kind == .primary || kind == .destructive ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .text ? 8 : (height > 36 ? 18 : 16))
            .frame(height: height)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(Capsule().fill(background))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .plain: IK.text
        case .primary, .destructive: .white
        case .text: theme.accentInk
        }
    }

    private var background: Color {
        switch kind {
        case .plain: IK.wash(0.09)
        case .primary: theme.accent
        case .destructive: IK.destructiveFill
        case .text: .clear
        }
    }
}

extension View {
    func ikButton(_ kind: IKButtonKind = .plain, height: CGFloat = 36, fill: Bool = false) -> some View {
        buttonStyle(IKButtonStyle(kind: kind, height: height, fill: fill))
    }
}

// MARK: - Cards

/// Confirm in place: the thing being deleted turns into its own question.
struct IKConfirmCard: View {
    let question: String
    let detail: String
    var confirmLabel = "Delete"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(question).font(.system(size: 15, weight: .semibold)).foregroundStyle(IK.text)
            Text(detail).font(.system(size: 13)).ikLineHeight(13, 18).foregroundStyle(IK.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).ikButton()
                Button(confirmLabel, action: onConfirm).ikButton(.destructive)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(IK.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IK.red.opacity(0.35), lineWidth: 1))
    }
}

/// A card in the composer's place: compress, review, archived, tool input.
struct IKSlotCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ikGlass(in: RoundedRectangle(cornerRadius: 26))
    }
}

/// An inline banner above the composer or at the top of a list.
struct IKBanner: View {
    let systemImage: String
    let text: String
    var color: Color = IK.orange
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .medium)).foregroundStyle(color)
                .padding(.top, 2)
            Text(text).font(.system(size: 13.5)).ikLineHeight(13.5, 19).foregroundStyle(IK.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(IK.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(IK.wash(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.33), lineWidth: 1))
    }
}

/// Thinking and tool pills: 28pt capsule.
struct IKPill: View {
    let systemImage: String
    let label: String
    var color: Color = IK.secondary
    var chevron: IKPillChevron = .closed

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .medium))
            Text(label).font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1)
            switch chevron {
            case .none: EmptyView()
            case .closed: Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(IK.tertiary)
            case .open: Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(IK.tertiary)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(IK.wash(0.05)))
        .overlay(Capsule().strokeBorder(IK.ring(0.08), lineWidth: 0.5))
    }
}

enum IKPillChevron { case none, closed, open }

/// A filter chip: 32pt, a wash, the accent when on.
struct IKChip: View {
    let title: String
    var dot: Color?
    var systemImage: String?
    var isOn = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                if let systemImage { Image(systemName: systemImage).font(.system(size: 14)) }
                Text(title).font(.system(size: 14))
            }
            .foregroundStyle(isOn ? theme.accentInk : IK.strong)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(isOn ? theme.selection : IK.wash(0.07)))
            .overlay(Capsule().strokeBorder(isOn ? theme.accent.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The unsaved-changes bar: a 60pt glass capsule over the bottom safe area.
struct IKSaveBar: View {
    let summary: String
    var saveLabel = "Save"
    var revertLabel = "Revert"
    var ground: IKGround = .settings
    var canSave = true
    let onRevert: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(summary).font(.system(size: 14)).foregroundStyle(IK.strong)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(revertLabel, action: onRevert).ikButton(height: 40).fixedSize()
            Button(saveLabel, action: onSave).ikButton(.primary, height: 40).disabled(!canSave).fixedSize()
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 60)
        .ikGlass(in: Capsule(), ground: ground)
        .padding(.horizontal, 12)
    }
}

/// A themed 7pt profile dot.
struct IKDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}
