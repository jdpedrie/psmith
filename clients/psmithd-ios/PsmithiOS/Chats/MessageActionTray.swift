import SwiftUI

/// Mail-style swipe-left action tray for a chat message bubble.
///
/// Pull the bubble left to reveal the applicable action chips on
/// the right; release past the snap threshold to commit the open
/// position. Tap a chip to fire its action and close. Tap the
/// bubble or swipe right to dismiss without acting.
///
/// The tray sizes itself to the number of applicable actions —
/// nil callbacks omit their chip. Today's full set is 5 (Copy,
/// Edit, Reload, Delete, Delete-all-replies); most messages show
/// 3–4. There is no overflow surface — every action the user can
/// take on this message is visible in one place.
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
struct MessageActionTray: ViewModifier {
    var onCopy: () -> Void
    var onEdit: (() -> Void)?
    var onReload: (() -> Void)?
    var onDelete: () -> Void
    var onDeleteAllReplies: (() -> Void)?

    /// Chip footprint. Smaller than the previous 56pt design to
    /// keep the tray width manageable when 5 chips are present —
    /// at 50pt the worst-case 5-chip tray is ~270pt, which still
    /// leaves ~120pt of bubble visible on the smallest iPhone.
    private let chipW: CGFloat = 50
    private let chipH: CGFloat = 56
    private let chipSpacing: CGFloat = 4
    private let trailingInset: CGFloat = 4

    /// Open snap threshold. Constant regardless of tray width, so
    /// the user learns one feel — pull past ~96pt to commit no
    /// matter how many chips a given message has.
    private let snapOpenAt: CGFloat = 96
    /// Velocity above which a flick commits regardless of distance.
    private let flickVelocity: CGFloat = 850
    /// First-sample distance the drag must travel before the
    /// direction-lock decision is made.
    private let lockSampleAt: CGFloat = 18
    /// Horizontal-vs-vertical ratio for the lock to land on
    /// `.horizontal`. >1 biases toward vertical.
    private let horizontalBias: CGFloat = 1.4

    @State private var openOffset: CGFloat = 0
    @State private var dragBaseOffset: CGFloat = 0
    @State private var lock: Lock = .undecided

    private enum Lock { case undecided, engaged, ignored }

    private var chipCount: Int {
        var n = 2  // Copy + Delete are always present
        if onEdit != nil { n += 1 }
        if onReload != nil { n += 1 }
        if onDeleteAllReplies != nil { n += 1 }
        return n
    }

    private var trayWidth: CGFloat {
        CGFloat(chipCount) * chipW
            + CGFloat(max(0, chipCount - 1)) * chipSpacing
            + trailingInset
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            tray
                .opacity(trayOpacity)
                .padding(.trailing, trailingInset)
                .allowsHitTesting(openOffset > snapOpenAt * 0.5)
            content
                .offset(x: -openOffset)
                .simultaneousGesture(dragGesture)
                .simultaneousGesture(closeOnTap)
        }
    }

    /// Tap-to-close, gated on tray-open so the bubble's own taps
    /// (markdown links, attachment chips, footer chips, etc.)
    /// keep working when the tray is closed.
    private var closeOnTap: some Gesture {
        TapGesture().onEnded {
            guard openOffset > 0 else { return }
            close(then: nil)
        }
    }

    private var trayOpacity: Double {
        let pct = min(1, max(0, Double(openOffset / trayWidth)))
        return min(1, pct * 1.5)
    }

    private var tray: some View {
        HStack(spacing: chipSpacing) {
            chip(icon: "doc.on.doc", label: "Copy", tint: .blue) {
                close(then: onCopy)
            }
            if let onEdit {
                chip(icon: "pencil", label: "Edit", tint: .orange) {
                    close(then: onEdit)
                }
            }
            if let onReload {
                chip(icon: "arrow.clockwise", label: "Reload", tint: .green) {
                    close(then: onReload)
                }
            }
            chip(icon: "trash", label: "Delete", tint: .red) {
                close(then: onDelete)
            }
            if let onDeleteAllReplies {
                chip(icon: "trash.slash", label: "Delete from here", tint: .red) {
                    close(then: onDeleteAllReplies)
                }
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
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.white)
            .frame(width: chipW, height: chipH)
            .background(tint, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

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
                    let closing = openOffset < trayWidth - snapOpenAt
                        || velocityLeft < -flickVelocity
                    target = closing ? 0 : trayWidth
                } else {
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
    /// Apply the swipe-left action tray. Pass `nil` for any action
    /// that doesn't apply to this message — the corresponding chip
    /// is omitted and the tray sizes itself to the visible chips.
    func messageActionTray(
        onCopy: @escaping () -> Void,
        onEdit: (() -> Void)? = nil,
        onReload: (() -> Void)? = nil,
        onDelete: @escaping () -> Void,
        onDeleteAllReplies: (() -> Void)? = nil
    ) -> some View {
        modifier(MessageActionTray(
            onCopy: onCopy,
            onEdit: onEdit,
            onReload: onReload,
            onDelete: onDelete,
            onDeleteAllReplies: onDeleteAllReplies
        ))
    }
}
