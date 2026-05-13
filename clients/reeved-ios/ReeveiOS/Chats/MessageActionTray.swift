import SwiftUI

/// Mail-style swipe-left action tray for a chat message bubble.
///
/// Pull the bubble left to reveal Copy / Edit / More chips on the
/// right; release past the snap threshold to commit the open
/// position. Tap a chip to fire its action and close. Tap the
/// bubble or swipe right to dismiss without acting.
///
/// Designed not to fight the parent ScrollView's vertical pan:
///   • A 12pt minimum distance keeps small finger jitter from
///     starting the gesture at all.
///   • A per-drag direction lock (set on the first sample past
///     `lockSampleAt`) hands vertical-leaning drags back to the
///     scroll view: if the first qualifying movement is more
///     vertical than horizontal (with a 1.4× bias toward vertical
///     so diagonals land on scroll, not swipe), the gesture
///     ignores everything until the user lifts.
///   • A right-swipe-from-rest is treated as vertical (no
///     accidental backwards drag).
///
/// The tray is laid out behind the bubble in a ZStack, right-
/// aligned. As the bubble's `.offset` shifts left, the tray
/// becomes visible. Past the open position the bubble rubber-
/// bands at 0.4× to bound the visual travel.
struct MessageActionTray: ViewModifier {
    var onCopy: () -> Void
    /// `nil` when the message isn't editable (assistant turn,
    /// frozen role, etc.). Hides the Edit chip — keeps Copy + More.
    var onEdit: (() -> Void)?
    var onMore: () -> Void

    /// Total uncovered tray width. Sized so three 56pt chips with
    /// 6pt spacing + 4pt trailing inset land cleanly on the right.
    private let trayWidth: CGFloat = 188
    /// Open snap threshold. ~half the tray; below this an end-
    /// of-drag bounces back closed.
    private let snapOpenAt: CGFloat = 96
    /// Velocity above which a flick commits regardless of distance.
    /// Mail uses ~600pt/s; we go a bit higher so a sideways nudge
    /// during scrolling doesn't fly the tray open.
    private let flickVelocity: CGFloat = 850
    /// First-sample distance the drag must travel before the
    /// direction-lock decision is made. Same as iMessage's
    /// swipe-for-timestamp feel.
    private let lockSampleAt: CGFloat = 18
    /// Horizontal-vs-vertical ratio at first sample for the lock
    /// to land on `.horizontal`. >1 biases toward vertical (lets
    /// the scroll view win diagonals); 1.4 is a comfortable middle.
    private let horizontalBias: CGFloat = 1.4

    /// Live offset (positive = bubble shifted left). Source of
    /// truth for both rendering and gesture math; resting position
    /// is 0 (closed) or `trayWidth` (open), with in-between values
    /// only existing while a finger is on the bubble.
    @State private var openOffset: CGFloat = 0
    /// Snapshot of `openOffset` at gesture start, so per-drag
    /// translation can be applied relative to wherever the tray
    /// was resting.
    @State private var dragBaseOffset: CGFloat = 0
    /// Per-gesture lock state — `engaged` follows the finger,
    /// `ignored` lets the rest of the drag pass through to other
    /// recognizers (typically the parent ScrollView).
    @State private var lock: Lock = .undecided

    private enum Lock { case undecided, engaged, ignored }

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            tray
                .opacity(trayOpacity)
                .padding(.trailing, 4)
                .allowsHitTesting(openOffset > snapOpenAt * 0.5)
            content
                .offset(x: -openOffset)
                .simultaneousGesture(dragGesture)
                .simultaneousGesture(closeOnTap)
        }
    }

    /// Tap-to-close, but only when the tray is open. Wired as a
    /// simultaneous gesture so it doesn't suppress the bubble's
    /// own taps (markdown links, attachment chips, etc.) when the
    /// tray is closed.
    private var closeOnTap: some Gesture {
        TapGesture().onEnded {
            guard openOffset > 0 else { return }
            close(then: nil)
        }
    }

    private var trayOpacity: Double {
        let pct = min(1, max(0, Double(openOffset / trayWidth)))
        // Ramp opacity faster than position so the chips are
        // legible by the time the user is past the snap threshold.
        return min(1, pct * 1.5)
    }

    private var tray: some View {
        HStack(spacing: 6) {
            chip(icon: "doc.on.doc", label: "Copy", tint: .blue) {
                close(then: onCopy)
            }
            if let onEdit {
                chip(icon: "pencil", label: "Edit", tint: .orange) {
                    close(then: onEdit)
                }
            }
            chip(icon: "ellipsis", label: "More", tint: Color(.systemGray)) {
                close(then: onMore)
            }
        }
    }

    private func chip(
        icon: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(tint, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Snap closed, then fire the supplied action one frame later
    /// so the close animation visibly starts before any modal
    /// (edit sheet, delete confirm, etc.) takes over the screen.
    private func close(then action: (() -> Void)?) {
        Haptics.impact(.light)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            openOffset = 0
        }
        guard let action else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            action()
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                if lock == .ignored { return }
                if lock == .undecided {
                    let dx = abs(v.translation.width)
                    let dy = abs(v.translation.height)
                    if dx + dy < lockSampleAt { return }
                    let leadsHorizontal = dx > dy * horizontalBias
                    // Right-pull from a closed tray is a vertical-
                    // intent fake-out (e.g., the user starts to scroll
                    // and brushes sideways). Only left-pull engages.
                    if leadsHorizontal && !(openOffset == 0 && v.translation.width > 0) {
                        lock = .engaged
                        dragBaseOffset = openOffset
                    } else {
                        lock = .ignored
                        return
                    }
                }
                let pulledLeft = -v.translation.width
                var raw = dragBaseOffset + pulledLeft
                if raw > trayWidth {
                    raw = trayWidth + (raw - trayWidth) * 0.4
                } else if raw < 0 {
                    raw = 0
                }
                openOffset = raw
            }
            .onEnded { v in
                defer { lock = .undecided }
                guard lock == .engaged else { return }
                let velocityLeft = -(v.predictedEndTranslation.width - v.translation.width)
                let target: CGFloat
                if dragBaseOffset > 0 {
                    // Started open. Close if user pulled right past
                    // half the tray, or flicked right hard enough.
                    let closing = openOffset < trayWidth - snapOpenAt
                        || velocityLeft < -flickVelocity
                    target = closing ? 0 : trayWidth
                } else {
                    // Started closed. Open if past snap or flicked left.
                    let opening = openOffset > snapOpenAt
                        || velocityLeft > flickVelocity
                    target = opening ? trayWidth : 0
                }
                if (target == 0) != (openOffset == 0) {
                    Haptics.impact(.light)
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    openOffset = target
                }
            }
    }
}

extension View {
    /// Apply the swipe-left action tray to a message bubble.
    /// Pass `onEdit: nil` to hide the Edit chip for non-editable
    /// roles (e.g., assistant turns).
    func messageActionTray(
        onCopy: @escaping () -> Void,
        onEdit: (() -> Void)? = nil,
        onMore: @escaping () -> Void
    ) -> some View {
        modifier(MessageActionTray(onCopy: onCopy, onEdit: onEdit, onMore: onMore))
    }
}
