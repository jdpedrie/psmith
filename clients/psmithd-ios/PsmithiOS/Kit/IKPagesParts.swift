import SwiftUI
import PsmithKit
import PsmithUI

// Parts shared by the conversation pages (Info, Model, Call settings) and
// Settings › Models. Measurements come from those boards' CSS.

// MARK: - Pop to root

/// Pops the whole stack back to the chats list. The root sets it; a page
/// that ends its conversation (archive, delete) calls it. Without a root
/// handler it falls back to popping one page.
struct IKPopToRootKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var ikPopToRoot: (@MainActor () -> Void)? {
        get { self[IKPopToRootKey.self] }
        set { self[IKPopToRootKey.self] = newValue }
    }
}

// MARK: - Segmented tabs

/// The boards' 34pt tab strip: a wash track, the selected tab on a
/// brighter wash with semibold ink.
struct IKSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selection
                Button { selection = opt.0 } label: {
                    Text(opt.1)
                        .font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? IK.text : IK.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? IK.wash(0.16) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(IK.wash(0.07)))
    }
}

// MARK: - Search field

struct IKSearchField: View {
    let prompt: String
    @Binding var text: String
    var height: CGFloat = 40
    var radius: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                .foregroundStyle(IK.secondary)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(IK.secondary))
                .font(.system(size: 16))
                .foregroundStyle(IK.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(IK.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius).fill(IK.wash(0.07)))
    }
}

// MARK: - Small marks

/// An 11pt capability tag ("Images", "Thinks", "200K").
struct IKTag: View {
    let text: String
    var color: Color = IK.secondary
    var fill: Color? = nil
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill ?? IK.wash(0.07)))
    }
}

/// A source badge: "Inherited", "This conversation", "Off here".
struct IKBadge: View {
    let text: String
    let color: Color
    let fill: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
    }
}

/// A provider's letter tile: 32pt in lists, 44pt in a header card.
struct IKLetterTile: View {
    let letter: String
    var size: CGFloat = 32
    var body: some View {
        Text(letter)
            .font(.system(size: size > 40 ? 17 : 14, weight: .bold))
            .foregroundStyle(IK.strong)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size > 40 ? 12 : 9).fill(IK.wash(0.08)))
    }
}

/// The 6pt accent dot that marks a field overridden at this layer.
struct IKOverrideDot: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Circle().fill(theme.accent).frame(width: 6, height: 6)
            .accessibilityLabel("Overridden here")
    }
}

/// Up-and-down chevrons after a menu's value.
struct IKMenuChevrons: View {
    var size: CGFloat = 11
    var body: some View {
        Image(systemName: "chevron.up.chevron.down").font(.system(size: size - 1, weight: .semibold))
    }
}

/// A group of rows on a themed page (Info, Model, Call settings): 14pt
/// corners on a faint wash, 1pt hairline separators inset 14.
struct IKPageGroup<Content: View>: View {
    var ground: IKGround = .themed
    @ViewBuilder let content: Content
    var body: some View {
        IKGroup(ground: ground) { content }
    }
}

/// A 48pt themed row (the `.r` class on the conversation boards).
struct IKPageRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var titleColor: Color = IK.text
    var bold = false
    var minHeight: CGFloat = 48
    var fontSize: CGFloat = 15.5
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: fontSize, weight: bold ? .semibold : .regular))
                    .foregroundStyle(titleColor)
                if let detail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(IK.secondary).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        // The boards set two-line rows at 1.17 line height; SF's own is 1.19.
        .padding(.vertical, detail == nil ? 8 : 7.5)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
    }
}

extension IKPageRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, titleColor: Color = IK.text, bold: Bool = false,
         minHeight: CGFloat = 48, fontSize: CGFloat = 15.5) {
        self.init(title: title, detail: detail, titleColor: titleColor, bold: bold, minHeight: minHeight,
                  fontSize: fontSize) { EmptyView() }
    }
}

/// The page section head with an optional trailing link or count.
struct IKPageHead: View {
    let text: String
    var trailing: String?
    var trailingBold = false
    var trailingColor: Color?
    var trailingAction: (() -> Void)?
    var topPadding: CGFloat = 18
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
            Spacer(minLength: 0)
            if let trailing {
                if let trailingAction {
                    Button(trailing, action: trailingAction)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(trailingColor ?? theme.accentInk)
                } else {
                    Text(trailing).font(.system(size: 13, weight: trailingBold ? .semibold : .regular))
                        .foregroundStyle(trailingColor ?? IK.tertiary)
                }
            }
        }
        .padding(EdgeInsets(top: topPadding, leading: 4, bottom: 6, trailing: 4))
    }
}

/// A note under a group: 12.5pt secondary on themed pages, 13pt tertiary
/// in Settings.
struct IKPageNote: View {
    let text: String
    var settings = false
    var top: CGFloat = 6
    init(_ text: String, settings: Bool = false, top: CGFloat = 6) {
        self.text = text
        self.settings = settings
        self.top = top
    }
    var body: some View {
        Text(text)
            .font(.system(size: settings ? 13 : 12.5))
            .ikLineHeight(settings ? 13 : 12.5, settings ? 18 : 17)
            .foregroundStyle(settings ? IK.tertiary : IK.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: top, leading: 4, bottom: 0, trailing: 4))
    }
}

/// A centered wash button inside a card ("Compress into a New Context",
/// "Edit Call Settings").
struct IKWashButton: View {
    let title: String
    let systemImage: String
    var height: CGFloat = 40
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
                Text(title).font(.system(size: 15))
            }
            .foregroundStyle(IK.text)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Capsule().fill(IK.wash(0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Form controls

/// The boards' slider: a 4pt track, an accent fill, a white 26pt thumb.
/// Muted (the inherited preview) it dims and fills with a wash.
struct IKSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    var muted = false
    var thumb: CGFloat = 26
    var onEditingChanged: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let frac = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
            ZStack(alignment: .leading) {
                Capsule().fill(IK.wash(0.12)).frame(height: 4)
                Capsule().fill(muted ? IK.wash(0.35) : theme.accent).frame(width: w * frac, height: 4)
                Circle().fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                    .offset(x: w * frac - thumb / 2)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(max(g.location.x / max(w, 1), 0), 1)
                var v = range.lowerBound + Double(f) * span
                if step > 0 { v = (v / step).rounded() * step }
                value = min(max(v, range.lowerBound), range.upperBound)
                onEditingChanged?()
            })
        }
        .frame(height: 28)
        .opacity(muted ? 0.5 : 1)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
            onEditingChanged?()
        }
    }
}

/// The boards' stepper: two 44pt halves on a 32pt wash.
struct IKStepper: View {
    let label: String
    var segmentWidth: CGFloat = 44
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onDecrement) {
                Image(systemName: "minus").font(.system(size: 13, weight: .semibold))
                    .frame(width: segmentWidth, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Decrease \(label)")
            Rectangle().fill(IK.wash(0.1)).frame(width: 1, height: 32)
            Button(action: onIncrement) {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    .frame(width: segmentWidth, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Increase \(label)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(IK.text)
        .background(RoundedRectangle(cornerRadius: 9).fill(IK.wash(0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// The reset glyph: a 44pt target around a 16pt counter-clockwise arrow.
struct IKResetButton: View {
    let label: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accentInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -8)
        .padding(.leading, -6)
        .padding(.trailing, -12)
        .accessibilityLabel(label)
    }
}

/// A read-only text field look: the boards' 40pt inset well.
struct IKFieldWell<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(IK.fieldWell))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(IK.ring(0.08), lineWidth: 1))
    }
}

extension IK {
    /// Inset text-field ground on Settings cards: black 22% in dark, an
    /// ink wash in light.
    static let fieldWell = Color.dynamic(light: Color(red: 16 / 255, green: 26 / 255, blue: 38 / 255).opacity(0.04),
                                         dark: Color.black.opacity(0.22))
}

// MARK: - Formatting

enum IKFormat {
    /// "200k", "1M", "128k".
    static func window(_ n: Int32?) -> String? {
        guard let n, n > 0 else { return nil }
        if n >= 1_000_000 { return n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : String(format: "%.1fM", Double(n) / 1_000_000) }
        return "\(Int((Double(n) / 1000).rounded()))k"
    }

    /// "$15", "$0.30", "$1.25".
    static func usd(_ v: Double) -> String {
        if v == v.rounded() { return "$\(Int(v))" }
        return String(format: "$%.2f", v)
    }

    /// "$15 / $75", "free", or nil when the model has no prices.
    static func prices(_ p: PsmithModelPricing?) -> String? {
        guard let p, let i = p.inputPerMillion, let o = p.outputPerMillion else { return nil }
        if i == 0 && o == 0 { return "free" }
        return "\(usd(i)) / \(usd(o))"
    }

    static func cost(_ v: Double) -> String { String(format: "$%.2f", v) }

    static func grouped(_ n: Int64) -> String { n.formatted(.number.grouping(.automatic)) }
}

/// The themed pages' disclosure chevron: smaller and lighter than Settings'.
struct IKPageChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(IK.tertiary)
    }
}

/// The save bar with buttons that keep their one-line width ("Add
/// Provider", "Enable Selected"); the summary gives way instead.
struct IKActionBar: View {
    let summary: String
    var secondary: String?
    let primary: String
    var ground: IKGround = .settings
    var canSave = true
    var onSecondary: () -> Void = {}
    let onPrimary: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(summary).font(.system(size: 14)).foregroundStyle(IK.strong).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let secondary {
                Button(secondary, action: onSecondary).ikButton(height: 40).fixedSize()
            }
            Button(primary, action: onPrimary).ikButton(.primary, height: 40).fixedSize().disabled(!canSave)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 60)
        .ikGlass(in: Capsule(), ground: ground)
        .padding(.horizontal, 12)
    }
}

extension View {
    /// A CSS line height: the extra leading goes between lines and, split
    /// in half, above the first and below the last, as a browser sets it.
    func ikLineHeight(_ size: CGFloat, _ lineHeight: CGFloat, weight: UIFont.Weight = .regular) -> some View {
        let extra = max(lineHeight - UIFont.systemFont(ofSize: size, weight: weight).lineHeight, 0)
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}
