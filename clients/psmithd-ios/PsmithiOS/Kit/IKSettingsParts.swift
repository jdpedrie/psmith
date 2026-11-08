import SwiftUI
import PsmithUI

// Parts the Settings boards share beyond IKParts: the page scaffold, the
// 51x31 switch, inline and stacked text fields, the segmented control, the
// two-button stepper and the small status pieces. Measurements come from the
// Settings* boards' CSS.

enum IKS {
    /// Text field well: `rgba(0,0,0,.22)` dark, `rgba(16,32,52,.088)` light.
    static let field = Color.dynamic(light: Color(red: 16 / 255, green: 32 / 255, blue: 52 / 255).opacity(0.088),
                                     dark: Color.black.opacity(0.22))
    /// A parent-only profile's dot: not a palette color, so it never reads as a chat profile.
    static let parentGray = Color.dynamic(light: .hex("#7D8894"), dark: .hex("#8C98A4"))
    static let mono = Font.system(size: 13.5, design: .monospaced)
}

// MARK: - Page

/// A pushed Settings page: neutral ground, system bar with an inline title,
/// a scrolling 16pt-gutter column starting 8pt under the bar, and an
/// optional save bar floating over the bottom safe area.
struct IKSettingsPage<Content: View, Bar: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var bar: Bar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                // The system bar's scroll inset already sits 10pt below the
                // boards' 103, so the boards' 8pt gap is -2 here.
                .padding(.top, -2)
                .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(IK.settingsGround.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
    }
}

extension IKSettingsPage where Bar == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content) { EmptyView() }
    }
}

/// The boards' section head: 13pt semibold, with an optional plain-weight
/// note at the trailing edge ("All devices", "This iPhone").
struct IKSHead: View {
    let text: String
    var note: String?
    var first = false
    init(_ text: String, note: String? = nil, first: Bool = false) {
        self.text = text
        self.note = note
        self.first = first
    }
    var body: some View {
        HStack {
            Text(text)
            Spacer(minLength: 0)
            if let note { Text(note).fontWeight(.regular) }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(IK.tertiary)
        .padding(EdgeInsets(top: first ? 4 : 18, leading: 4, bottom: 6, trailing: 4))
    }
}

/// A footer with the boards' 18pt line height.
struct IKSFooter: View {
    let text: String
    var top: CGFloat = 6
    init(_ text: String, top: CGFloat = 6) {
        self.text = text
        self.top = top
    }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(18 - 15.5)
            .foregroundStyle(IK.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // CSS centers each 18pt line; SwiftUI puts the extra leading
            // below, so the half above is added here.
            .padding(EdgeInsets(top: top + 1.25, leading: 4, bottom: 1.25, trailing: 4))
    }
}

/// A Settings row: 44pt minimum, 8pt vertical padding, 14pt sides.
struct IKSRow<Content: View>: View {
    var vertical: CGFloat = 8
    var leading: CGFloat = 14
    var color: Color = IK.text
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 12) { content }
            .font(.system(size: 16))
            .foregroundStyle(color)
            .padding(.vertical, vertical)
            .padding(.leading, leading)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// A row that pushes: title, value, chevron.
struct IKSLinkRow<Destination: View>: View {
    let title: String
    var value: String?
    var valueColor: Color = IK.secondary
    var mono = false
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            IKSRow {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                if let value {
                    Text(value)
                        .font(mono ? .system(size: 14, design: .monospaced) : .system(size: 15))
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                IKChevron()
            }
        }
        .buttonStyle(.plain)
    }
}

/// A row-shaped button in the link color ("Add Account", "Open iOS Settings").
struct IKSActionRow: View {
    let title: String
    var systemImage: String?
    var color: Color?
    var centered = false
    /// Leaves the app (iOS Settings): an outbound arrow instead of a chevron.
    var chevron = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            IKSRow(color: color ?? theme.accentInk) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 17)).frame(width: 18)
                }
                Text(title).frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                if chevron {
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold)).foregroundStyle(IK.chevron)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Key-value row with a plain value.
struct IKSValueRow: View {
    let title: String
    let value: String
    var color: Color = IK.secondary
    var dot: Color?
    var mono = false
    var body: some View {
        IKSRow {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let dot { IKDot(color: dot, size: 7) }
                Text(value)
                    .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 15))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(color)
        }
    }
}

/// Title over a 13pt note, for rows with a switch or a button.
struct IKSTitleNote: View {
    let title: String
    var note: String?
    var titleColor: Color = IK.text
    var noteSize: CGFloat = 13
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(titleColor)
            if let note {
                Text(note).font(.system(size: noteSize)).foregroundStyle(IK.secondary)
                    .lineSpacing(noteSize == 13 ? 2.5 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Switch

/// The boards' 51x31 switch: the accent when on, a wash when off. Its own
/// button, not a ToggleStyle, so a tap and VoiceOver run the same code.
struct IKSwitch: View {
    @Binding var isOn: Bool
    let accessibilityLabel: String
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? theme.accent : IK.wash(0.16))
                Circle().fill(.white).frame(width: 27, height: 27).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .frame(width: 51, height: 31)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A label with the switch at its trailing edge.
struct IKSToggle<Label: View>: View {
    let title: String
    @Binding var isOn: Bool
    @ViewBuilder var label: Label

    var body: some View {
        HStack(spacing: 12) {
            label.frame(maxWidth: .infinity, alignment: .leading).accessibilityHidden(true)
            IKSwitch(isOn: $isOn, accessibilityLabel: title)
        }
    }
}

extension IKSToggle where Label == Text {
    init(_ title: String, isOn: Binding<Bool>) {
        self.init(title: title, isOn: isOn) { Text(title) }
    }
}

/// A switch row: label (and an optional note) with the switch trailing.
struct IKSSwitchRow: View {
    let title: String
    var note: String?
    var titleColor: Color = IK.text
    @Binding var isOn: Bool

    var body: some View {
        IKSRow {
            IKSToggle(title: title, isOn: $isOn) { IKSTitleNote(title: title, note: note, titleColor: titleColor, noteSize: 13) }
        }
    }
}

// MARK: - Fields

/// A label over a 40pt well, with an optional caption ("Name", "URL").
struct IKSStackedField: View {
    let label: String
    var required = false
    @Binding var text: String
    var placeholder = ""
    var caption: String?
    var mono = false
    var secure = false
    var monoSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(label)
                if required { Text("*").foregroundStyle(IK.red) }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(IK.tertiary)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(mono ? .system(size: monoSize, design: .monospaced) : .system(size: 16))
            .foregroundStyle(IK.text)
            .textInputAutocapitalization(mono ? .never : .sentences)
            .autocorrectionDisabled(mono)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(IKS.field))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(IK.ring(0.08), lineWidth: 1))
            .padding(.top, 6)
            .accessibilityLabel(label)
            if let caption {
                Text(caption).font(.system(size: 12.5)).lineSpacing(17 - 15).foregroundStyle(IK.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
                    .padding(.bottom, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A multi-line well (headers, env, arguments).
struct IKSTextArea: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var caption: String?
    var minHeight: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(IK.tertiary)
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(size: 13.5, design: .monospaced))
                .lineSpacing(19 - 16)
                .foregroundStyle(IK.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...12)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: minHeight, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(IKS.field))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(IK.ring(0.08), lineWidth: 1))
                .padding(.top, 6)
                .accessibilityLabel(label)
            if let caption {
                Text(caption).font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(IK.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
                    .padding(.bottom, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row with the label at the leading edge and a right-aligned monospaced
/// field ("Host", "Public key"). Secure fields get a reveal button.
struct IKSInlineField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    @State private var reveal = false

    var body: some View {
        IKSRow {
            Text(label).fixedSize()
            Group {
                if secure && !reveal {
                    SecureField(text: $text, prompt: Text(placeholder).foregroundStyle(IK.tertiary)) { Text(label) }
                } else {
                    TextField(text: $text, prompt: Text(placeholder).foregroundStyle(IK.tertiary)) { Text(label) }
                }
            }
            .font(IKS.mono)
            .foregroundStyle(IK.secondary)
            .multilineTextAlignment(.trailing)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(label)
            if secure {
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(IK.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .padding(.trailing, -6)
                .accessibilityLabel(reveal ? "Hide what you’re typing" : "Show what you’re typing")
            }
        }
    }
}

// MARK: - Controls

/// The boards' segmented control: a 2pt-inset wash track, the selected
/// segment a stronger wash.
struct IKSSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 34
    var inset = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? IK.text : IK.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? IK.wash(inset ? 0.14 : 0.16) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 10).fill(inset ? IKS.field : IK.wash(0.07)))
        .overlay {
            if inset { RoundedRectangle(cornerRadius: 10).strokeBorder(IK.ring(0.08), lineWidth: 1) }
        }
    }
}

/// Minus and plus in one 32pt wash capsule.
struct IKSStepper: View {
    let lowerLabel: String
    let raiseLabel: String
    var segment: CGFloat = 46
    var divided = false
    var canLower = true
    var canRaise = true
    let lower: () -> Void
    let raise: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: lower) {
                Image(systemName: "minus").frame(width: segment, height: 32).contentShape(Rectangle())
            }
            .disabled(!canLower)
            .accessibilityLabel(lowerLabel)
            Rectangle().fill(IK.wash(divided ? 0.14 : 0.12)).frame(width: 1).padding(.vertical, divided ? 7 : 0)
            Button(action: raise) {
                Image(systemName: "plus").frame(width: segment, height: 32).contentShape(Rectangle())
            }
            .disabled(!canRaise)
            .accessibilityLabel(raiseLabel)
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(IK.text)
        .background(RoundedRectangle(cornerRadius: 9).fill(IK.wash(divided ? 0.08 : 0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// A small 20pt chip ("Tool", "Global setup needed").
struct IKSChip: View {
    let text: String
    var warning = false
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(warning ? IK.orange : IK.strong)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(warning ? IK.orange.opacity(0.14) : IK.wash(0.08)))
    }
}

/// The confirm card inside a group, 8pt in from its edges.
struct IKSInsetConfirm: View {
    let question: String
    let detail: String
    var confirmLabel = "Delete"
    let onCancel: () -> Void
    let onConfirm: () -> Void
    var body: some View {
        IKConfirmCard(question: question, detail: detail, confirmLabel: confirmLabel,
                      onCancel: onCancel, onConfirm: onConfirm)
            .padding(8)
    }
}

/// An inline test outcome: icon, title, trailing measurement.
struct IKSResultRow: View {
    let ok: Bool
    let title: String
    var detail: String?
    var value: String?
    var body: some View {
        IKSRow {
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 17))
                .foregroundStyle(ok ? IK.green : IK.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(IK.secondary).lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value).font(.system(size: 15)).foregroundStyle(IK.secondary).monospacedDigit()
            }
        }
    }
}

/// An error line under a group.
struct IKSError: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(IK.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 4))
    }
}

/// A danger-zone group whose one row turns into its own confirm card.
struct IKSDangerZone: View {
    let actionTitle: String
    let question: String
    let detail: String
    var confirmLabel = "Delete"
    var busy = false
    @Binding var confirming: Bool
    let onConfirm: () -> Void

    var body: some View {
        IKSHead("Danger zone")
        if confirming {
            IKConfirmCard(question: question, detail: detail, confirmLabel: confirmLabel,
                          onCancel: { confirming = false },
                          onConfirm: { confirming = false; onConfirm() })
        } else {
            IKGroup {
                Button { confirming = true } label: {
                    IKSRow {
                        Text(busy ? "Working…" : actionTitle).foregroundStyle(IK.red)
                        Spacer(minLength: 0)
                        if busy { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }
}

/// Row insets for the Settings lists that need swipe actions: rows draw
/// their own group background and hairline.
extension View {
    func iksListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// One row of a group drawn inside a List: rounds only the group's
    /// outer corners and draws the hairline above every row but the first.
    func iksGroupRow(first: Bool, last: Bool, separatorInset: CGFloat = 14) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: first ? 14 : 0, bottomLeadingRadius: last ? 14 : 0,
                                           bottomTrailingRadius: last ? 14 : 0, topTrailingRadius: first ? 14 : 0)
        return self
            .overlay(alignment: .top) {
                if !first {
                    Rectangle().fill(IK.wash(0.07)).frame(height: 1).padding(.leading, separatorInset)
                }
            }
            .background(shape.fill(IK.settingsGroup))
            .clipShape(shape)
    }
}
