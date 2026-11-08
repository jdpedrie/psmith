import SwiftUI
import AppKit
import PsmithUI

// The Settings window's building blocks. Every measurement here is copied
// from the redesign canvas's board kit (the Settings page of "Psmith Mac
// redesign concepts"); change one and the boards no longer describe the
// app, so change the board kit with it.

// MARK: - Tokens

enum SK {
    static let window = Color(hex: 0x1B2027)
    static let bar = Color(hex: 0x20262E)
    static let side = Color(hex: 0x171B21)
    static let card = Color(hex: 0x20262E)
    static let line = Color.white.opacity(0.07)
    static let hair = Color.white.opacity(0.05)
    static let text = Color(hex: 0xE6EAEE)
    static let secondary = Color(hex: 0x9AA6B2)
    static let tertiary = Color(hex: 0x7F8B97)
    static let accent = Color(hex: 0x4C96D9)
    static let selection = Color(hex: 0x2C65A0)
    static let link = Color(hex: 0x7DB4E6)
    static let green = Color(hex: 0x7FD3A2)
    static let orange = Color(hex: 0xF2A65A)
    static let red = Color(hex: 0xF08A80)
    static let destructiveFill = Color(hex: 0xC2463C)
    static let control = Color.white.opacity(0.09)
    static let controlRing = Color.white.opacity(0.12)
    static let fieldFill = Color.black.opacity(0.28)
    static let fieldRing = Color.white.opacity(0.14)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Text in the boards' sizes: 13 body, 11.5 detail, 12 group header.
extension View {
    func sk(_ size: CGFloat, _ color: Color = SK.text, weight: Font.Weight? = nil, mono: Bool = false) -> some View {
        self
            .scaledFont(size: size, weight: weight, design: mono ? .monospaced : nil)
            .foregroundStyle(color)
    }
}

/// The boards' CSS line-height: SwiftUI lays SF out about 1.28 of its
/// size, so the extra goes between lines and half above and below, as a
/// browser centers text in its line box.
struct SKLineHeight: ViewModifier {
    let size: CGFloat
    let multiple: CGFloat

    func body(content: Content) -> some View {
        let extra = max(0, size * multiple - size * 1.28)
        content
            .lineSpacing(extra)
            .padding(.vertical, extra / 2)
    }
}

extension View {
    func skLineHeight(_ size: CGFloat, _ multiple: CGFloat) -> some View {
        modifier(SKLineHeight(size: size, multiple: multiple))
    }

    /// One line in the boards' "normal" line box (about 1.19 of the size),
    /// a point shorter than SwiftUI's own at 13pt.
    func skOneLine(_ size: CGFloat) -> some View {
        lineLimit(1).frame(height: size * 1.19)
    }
}

// MARK: - Group and rows

/// A titled card of rows with a hairline between each, an optional chip
/// on the header's right, and an optional footnote.
struct SKGroup<Content: View, Trailing: View, Footer: View>: View {
    var title: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title ?? "").sk(12, SK.secondary, weight: .semibold).skOneLine(12)
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 7)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            Rectangle().fill(SK.hair).frame(height: 1)
                        }
                        row
                    }
                }
            }
            .background(SK.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SK.line, lineWidth: 1))
            if Footer.self != EmptyView.self {
                footer
                    .sk(11.5, SK.tertiary)
                    .skLineHeight(11.5, 1.4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    // 7 on the boards; SwiftUI sets the first line a point higher.
                    .padding(.top, 8)
            }
        }
        .padding(.bottom, 22)
    }
}

extension SKGroup where Trailing == EmptyView, Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = EmptyView()
        self.content = content()
        self.footer = EmptyView()
    }
}

extension SKGroup where Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
        self.footer = EmptyView()
    }
}

extension SKGroup where Trailing == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.trailing = EmptyView()
        self.content = content()
        self.footer = footer()
    }
}

extension SKGroup {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
        self.footer = footer()
    }
}

/// A row's title with a line of explanation under it.
struct SKLabel: View {
    let title: String
    var detail: String?
    var titleColor: Color = SK.text
    /// Clamp the detail, for list rows whose full text lives elsewhere.
    var detailLines: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).sk(13, titleColor).skOneLine(13)
            if let detail {
                Text(detail)
                    .sk(11.5, SK.secondary)
                    .lineLimit(detailLines)
                    .skLineHeight(11.5, 1.35)
                    .fixedSize(horizontal: false, vertical: detailLines == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title (and detail) on the left, a control on the right.
struct SKRow<Control: View>: View {
    let title: String
    var detail: String?
    var titleColor: Color = SK.text
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SKLabel(title: title, detail: detail, titleColor: titleColor)
            control
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }
}

extension SKRow where Control == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
        self.control = EmptyView()
    }
}

extension SKRow {
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }
}

/// A row holding anything, with the rows' padding.
struct SKRawRow<Content: View>: View {
    var vertical: CGFloat = 9
    var horizontal: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
    }
}

// MARK: - Small pieces

struct SKChip: View {
    let text: String
    var color: Color = SK.secondary
    var fill: Color = Color.white.opacity(0.08)

    var body: some View {
        Text(text)
            .sk(11, color, weight: .semibold)
            .skOneLine(11)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(fill))
            .fixedSize()
    }

    static var synced: SKChip { SKChip(text: "Synced", color: SK.link, fill: SK.link.opacity(0.12)) }
    static var thisMac: SKChip { SKChip(text: "This Mac") }
}

struct SKDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

// MARK: - Controls

/// The boards' switch: 34×20, a 16pt knob.
struct SKSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? SK.accent : Color.white.opacity(0.16))
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 34, height: 20)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension View {
    func skSwitch() -> some View { toggleStyle(SKSwitchStyle()).labelsHidden() }
}

enum SKButtonKind { case normal, primary, destructive, destructiveFilled, plain, plainQuiet }

struct SKButtonStyle: ButtonStyle {
    var kind: SKButtonKind = .normal
    var small = false
    /// Icon-only: 6pt sides instead of 12.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch kind {
        case .normal: SK.control
        case .primary: SK.accent
        case .destructive: SK.red.opacity(0.16)
        case .destructiveFilled: SK.destructiveFill
        case .plain, .plainQuiet: .clear
        }
        let ink: Color = switch kind {
        case .normal: SK.text
        case .primary, .destructiveFilled: .white
        case .destructive: SK.red
        case .plain: SK.link
        case .plainQuiet: SK.secondary
        }
        configuration.label
            .sk(13, ink, weight: kind == .primary || kind == .destructiveFilled ? .semibold : nil)
            .padding(.horizontal, kind == .plain || kind == .plainQuiet ? 4 : (compact ? 6 : 12))
            .frame(height: small ? 22 : 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay {
                if kind == .normal {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(SK.controlRing, lineWidth: 0.5)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension View {
    func skButton(_ kind: SKButtonKind = .normal, small: Bool = false, compact: Bool = false) -> some View {
        buttonStyle(SKButtonStyle(kind: kind, small: small, compact: compact))
    }
}

/// A chevron drawn the way the boards draw theirs: on a 20-unit grid,
/// from (5,12) to (10,7) to (15,12), scaled to the box.
struct SKChevron: Shape {
    var up = true

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 20
        var p = Path()
        if up {
            p.move(to: CGPoint(x: 5 * s, y: 12 * s)); p.addLine(to: CGPoint(x: 10 * s, y: 7 * s)); p.addLine(to: CGPoint(x: 15 * s, y: 12 * s))
        } else {
            p.move(to: CGPoint(x: 5 * s, y: 8 * s)); p.addLine(to: CGPoint(x: 10 * s, y: 13 * s)); p.addLine(to: CGPoint(x: 15 * s, y: 8 * s))
        }
        return p
    }
}

/// The two stacked chevrons a pop-up button carries: 9pt each, touching.
struct SKUpDown: View {
    var body: some View {
        VStack(spacing: 0) {
            SKChevron(up: true).stroke(SK.secondary, style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)).frame(width: 9, height: 9)
            SKChevron(up: false).stroke(SK.secondary, style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round)).frame(width: 9, height: 9)
        }
    }
}

/// A native menu drawn as the boards' pop-up button.
struct SKPopup<Items: View>: View {
    let value: String
    var minWidth: CGFloat?
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 8) {
                Text(value).sk(13)
                Spacer(minLength: 0)
                SKUpDown()
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(minWidth: minWidth, minHeight: 24, maxHeight: 24)
            .fixedSize()
            .background(RoundedRectangle(cornerRadius: 6).fill(SK.control))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SK.controlRing, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The boards' text field: 24 tall, dark fill, hairline ring. A modifier,
/// not a TextFieldStyle, so SecureField gets it too.
struct SKFieldModifier: ViewModifier {
    var width: CGFloat?
    var mono = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            // Font only: a foreground style here would also color the
            // placeholder, which should stay the system's dimmer gray.
            .scaledFont(size: mono ? 12 : 13, design: mono ? .monospaced : nil)
            .padding(.horizontal, 8)
            .frame(width: width, height: 24)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 6).fill(SK.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SK.fieldRing, lineWidth: 0.5))
    }
}

extension View {
    func skField(width: CGFloat? = 260, mono: Bool = false) -> some View {
        modifier(SKFieldModifier(width: width, mono: mono))
    }
}

/// The boards' text field with its placeholder drawn here: a plain-style
/// TextField on macOS ignores the prompt's color and draws it full white.
struct SKTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var width: CGFloat? = 260
    var mono = false
    var secure = false

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .sk(mono ? 12 : 13, SK.tertiary, mono: mono)
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
            Group {
                // Empty titles: SwiftUI draws a field's title as its own
                // placeholder, over the one above.
                if secure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .labelsHidden()
            .foregroundStyle(SK.text)
        }
        .skField(width: width, mono: mono)
        .accessibilityLabel(label)
    }
}

/// Multiline field with the boards' look.
struct SKTextArea: View {
    @Binding var text: String
    var lines: Int = 4
    var mono = false

    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .sk(mono ? 12 : 13, mono: mono)
            .lineSpacing(3)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(height: CGFloat(lines) * 19 + 14)
            .background(RoundedRectangle(cornerRadius: 6).fill(SK.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SK.fieldRing, lineWidth: 0.5))
    }
}

/// The boards' segmented control.
struct SKSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    /// Stretch to the width offered, segments sharing it equally (the
    /// inspector's tabs); otherwise hug the labels.
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .sk(12.5, on ? .white : SK.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .frame(maxWidth: .infinity)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.white.opacity(0.18))
                                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(SK.control))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .fixedSize(horizontal: !fill, vertical: true)
    }
}

/// The boards' slider: a 4pt track, accent fill, a 16pt knob, optional ticks.
struct SKSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var width: CGFloat = 200
    var ticks = 0

    private var fraction: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.14)).frame(height: 4)
            Capsule().fill(SK.accent).frame(width: width * fraction, height: 4)
            if ticks > 1 {
                ForEach(0..<ticks, id: \.self) { i in
                    Rectangle().fill(SK.tertiary).frame(width: 1, height: 4)
                        .offset(x: width * Double(i) / Double(ticks - 1), y: 5)
                }
            }
            Circle()
                .fill(Color(hex: 0xE9EDF1))
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                .offset(x: width * fraction - 8)
        }
        .frame(width: width, height: 20)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            var v = range.lowerBound + (range.upperBound - range.lowerBound) * min(max(g.location.x / width, 0), 1)
            if let step { v = (v / step).rounded() * step }
            value = min(max(v, range.lowerBound), range.upperBound)
        })
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
    }
}

/// A number field with stacked up/down arrows.
struct SKStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var format: (Int) -> String = { $0.formatted() }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: $value, format: .number)
                .skField(width: 80, mono: true)
            VStack(spacing: 0) {
                Button { value = min(value + step, range.upperBound) } label: {
                    Image(systemName: "chevron.up").frame(width: 15, height: 11)
                }
                .accessibilityLabel("Increase")
                Button { value = max(value - step, range.lowerBound) } label: {
                    Image(systemName: "chevron.down").frame(width: 15, height: 11)
                }
                .accessibilityLabel("Decrease")
            }
            .buttonStyle(.plain)
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(SK.secondary)
            .background(RoundedRectangle(cornerRadius: 5).fill(SK.control))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SK.controlRing, lineWidth: 0.5))
        }
    }
}

// MARK: - Page structure

struct SKPageHead<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).sk(17, weight: .bold)
                if let subtitle {
                    Text(subtitle).sk(12.5, SK.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.bottom, 16)
    }
}

extension SKPageHead where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = EmptyView()
    }
}

/// A single-column pane: a 640pt column centered, scrolling, with an
/// optional bar pinned under it.
struct SKFormPage<Content: View, Bottom: View>: View {
    var width: CGFloat = 640
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(width: width)
                .padding(.top, 22)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            bottom
        }
    }
}

extension SKFormPage where Bottom == EmptyView {
    init(width: CGFloat = 640, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
        self.bottom = EmptyView()
    }
}

/// Confirms a destructive action in place of its button.
struct SKConfirmStrip: View {
    let question: String
    let detail: String
    let confirmLabel: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SK.red)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(question).sk(13, weight: .semibold)
                Text(detail).sk(11.5, SK.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", action: onCancel)
                .skButton()
                .keyboardShortcut(.cancelAction)
            Button(confirmLabel, action: onConfirm)
                .skButton(.destructiveFilled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(SK.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SK.red.opacity(0.35), lineWidth: 1))
    }
}

/// Unsaved changes to a server record: what changed, Discard, Save.
struct SKSaveBar: View {
    let summary: String
    var note: String?
    var saving = false
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SKDot(color: SK.orange)
            Text(summary).sk(12.5)
            if let note { Text(note).sk(11.5, SK.tertiary) }
            Spacer(minLength: 0)
            Button("Discard", action: onDiscard).skButton().disabled(saving)
            Button(saving ? "Saving…" : "Save", action: onSave)
                .skButton(.primary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(saving)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(Color(hex: 0x20262E, opacity: 0.96))
        .overlay(alignment: .top) { Rectangle().fill(SK.line).frame(height: 1) }
    }
}

enum SKBannerKind { case error, warning, ok, info }

struct SKBanner<Action: View>: View {
    let kind: SKBannerKind
    let title: String
    var message: String?
    @ViewBuilder var action: Action

    private var tint: Color {
        switch kind {
        case .error: SK.red
        case .warning: SK.orange
        case .ok: SK.green
        case .info: SK.link
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .ok || kind == .info ? "checkmark" : "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).sk(13, tint, weight: .semibold)
                if let message {
                    Text(message).sk(12, SK.secondary).skLineHeight(12, 1.4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tint.opacity(0.33), lineWidth: 1))
        .padding(.bottom, 16)
    }
}

extension SKBanner where Action == EmptyView {
    init(_ kind: SKBannerKind, _ title: String, message: String? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.action = EmptyView()
    }
}

/// "Saved" with a lock, a field to paste a replacement, and Remove.
struct SKSecretField: View {
    let isSaved: Bool
    @Binding var draft: String
    var placeholder = "Paste to replace"
    var width: CGFloat = 190
    var onRemove: (() -> Void)?
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 8) {
            if isSaved {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(SK.secondary)
                Text("Saved").sk(12.5, SK.secondary)
            }
            SKTextField(label: "Secret", text: $draft, placeholder: isSaved ? placeholder : "Paste key", width: width, secure: !reveal)
            if let onRemove, isSaved {
                Button("Remove", action: onRemove).skButton(.plain)
            }
        }
    }
}
