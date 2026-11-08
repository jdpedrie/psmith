import SwiftUI
import AppKit
import PsmithKit
import PsmithUI

// The main window's building blocks. Measurements come from the redesign
// canvas's main-window board kit (the "Main window" page of "Psmith Mac
// redesign concepts"); text, controls, groups and strips are the Settings
// kit's (SettingsKit.swift), so the two windows share them. What differs is
// the ground: the main window follows the theme, in its dark variant.

// MARK: - Theme-derived surfaces

/// The list and inspector columns: the theme's chrome under 24% black.
struct MKWell: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack { theme.chrome; Color.black.opacity(0.24) }
    }
}

/// The user bubble and the composer card sit on these.
enum MK {
    /// Composer and slot cards: a step above the chrome.
    static let raised = Color(hex: 0x1A2533)
    static let raisedRing = Color.white.opacity(0.09)
    static let accentText = Color(hex: 0x9FCBF2)
    static let card = Color.white.opacity(0.04)
    /// The transcript and every slot share one measure.
    static let column: CGFloat = 720
    static let listWidth: CGFloat = 290
    static let listRange: ClosedRange<CGFloat> = 240...420
    static let inspectorWidth: CGFloat = 320
    static let header: CGFloat = 52
    static let windowFloor = NSSize(width: 1080, height: 600)
}

extension Theme {
    /// accentText on the boards is a light tint of the accent, for text
    /// and icons on a wash of it.
    var accentInk: Color { accent.mix(with: .white, by: 0.45) }
}

// MARK: - Header parts

/// A 28pt icon button: the list's hide and new buttons, the inspector
/// toggle. Active draws the accent wash the inspector toggle shows open.
struct MKIconButton: View {
    let systemImage: String
    let label: String
    var active = false
    var size: CGFloat = 14
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(active ? theme.accentInk : SK.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? theme.accent.opacity(0.18) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(active ? theme.accent.opacity(0.45) : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Controls sharing one 28pt capsule, split by hairlines.
struct MKCapsule<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(SK.control))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SK.controlRing, lineWidth: 0.5))
            .fixedSize()
    }
}

struct MKCapsuleDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 14)
    }
}

/// A column's top band: 52pt, the window's traffic lights sit centered in
/// it (the empty unified toolbar puts them at x 19, 42, 65).
///
/// Opaque and above what follows it: a scroll view under the window's
/// title-bar safe area extends itself up into it, so without this a long
/// transcript scrolls up over the header.
struct MKHeaderBand<Content: View>: View {
    var divider = true
    var ground: MKHeaderGround = .chrome
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 8) { content }
            .frame(height: MK.header)
            .frame(maxWidth: .infinity)
            .background {
                switch ground {
                case .chrome: theme.chrome
                case .well: MKWell()
                }
            }
            .overlay(alignment: .bottom) {
                if divider { Rectangle().fill(SK.line).frame(height: 1) }
            }
            .zIndex(1)
    }
}

enum MKHeaderGround { case chrome, well }

// MARK: - Small parts

/// The boards' 12pt progress ring: a quarter arc turning on a faint track.
struct MKSpinner: View {
    var size: CGFloat = 12
    var color: Color = SK.secondary
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 1.5)
            Circle().trim(from: 0, to: 0.25).stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size - 1.5, height: size - 1.5)
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityLabel("In progress")
    }
}

/// Thinking and tool pills: a 22pt capsule.
struct MKPill: View {
    let systemImage: String
    let label: String
    var color: Color = SK.secondary
    var chevron: MKPillChevron = .closed

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium))
            Text(label).sk(11.5, color, weight: .medium).monospacedDigit().lineLimit(1)
            if chevron != .none {
                Image(systemName: chevron == .open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(SK.tertiary)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

enum MKPillChevron { case none, closed, open }

/// A card in the composer's place: review, archived, elicitation,
/// compression. Same width and corner as the composer.
struct MKSlotCard<Content: View>: View {
    var ring: Color = MK.raisedRing
    var padding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(MK.raised))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ring, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
    }
}

/// Above the composer: an error or state the conversation is in.
struct MKInlineBanner: View {
    let systemImage: String
    let text: String
    var color: Color = SK.orange
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .medium)).foregroundStyle(color).frame(width: 14, height: 14)
            Text(text).sk(12).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SK.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.33), lineWidth: 1))
    }
}

/// A destructive confirmation sized for a list row or an inspector row:
/// question, detail, then the buttons on their own line.
struct MKConfirmCard: View {
    let question: String
    let detail: String
    let confirmLabel: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(question).sk(13, weight: .semibold).lineLimit(2)
            Text(detail).sk(11.5, SK.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).skButton(small: true).keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm).skButton(.destructiveFilled, small: true)
            }
            .padding(.top, 8)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(SK.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SK.red.opacity(0.35), lineWidth: 1))
    }
}

/// One line of the transcript's strips: icon, bold lead, detail, then
/// buttons, as the message delete and fork confirmations draw.
struct MKStrip<Buttons: View>: View {
    let systemImage: String
    let lead: String
    let detail: String
    var tint: Color = SK.red
    var fill: Color = SK.red.opacity(0.10)
    var ring: Color = SK.red.opacity(0.35)
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .medium)).foregroundStyle(tint).frame(width: 14, height: 14)
            (Text(lead).fontWeight(.semibold) + Text(" ") + Text(detail).foregroundColor(SK.secondary))
                .sk(12.5)
                .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ring, lineWidth: 1))
    }
}

/// A user avatar: the first letter on the accent.
struct MKAvatar: View {
    let name: String
    var size: CGFloat = 22
    @Environment(\.theme) private var theme
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size <= 22 ? 11 : 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(theme.accent))
    }
}

/// The main window's measure: a centered column that stops at 720 and
/// keeps 24pt from each edge when the pane is narrower.
struct MKColumn<Content: View>: View {
    var width: CGFloat = MK.column
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: width)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
    }
}
