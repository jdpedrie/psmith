import SwiftUI
import UIKit
import os.log

private let bridgeLog = Logger(subsystem: "dev.jdpedrie.psmith", category: "StatusBarTap")

/// Reclaims the status-bar tap for the inverted transcript.
///
/// UIKit's scroll-to-top gesture is dead on the conversation screen:
/// with several eligible scroll views (the flipped transcript plus
/// horizontal code/table scrollers) UIKit refuses to pick one, and
/// even if it fired, its native semantics scroll to contentOffset
/// zero — which inverted is the NEWEST message, not the top of the
/// context the user expects. This zero-size probe plants a hidden
/// 1pt UIScrollView that claims `scrollsToTop`, disables it on every
/// other scroll view under the window (restoring them on detach, so
/// the chats list gets its native behavior back after pop), and
/// translates the tap into the caller's scroll-to-oldest action.
struct StatusBarTapBridge: UIViewRepresentable {
    var onTap: () -> Void

    func makeUIView(context: Context) -> BridgeView {
        BridgeView(onTap: onTap)
    }

    func updateUIView(_ view: BridgeView, context: Context) {
        view.onTap = onTap
    }

    final class BridgeView: UIView, UIScrollViewDelegate {
        var onTap: () -> Void
        private let claimer = UIScrollView()
        /// Scroll views this bridge disabled, restored on detach.
        private var disabled: [Weak<UIScrollView>] = []

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
            super.init(frame: .zero)
            // Interaction must stay ENABLED — a scroll view under a
            // non-interactive parent is ineligible for the system
            // scroll-to-top resolution. hitTest below keeps the
            // bridge transparent to real touches anyway.
            claimer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            claimer.contentSize = CGSize(width: 1, height: 3)
            // A scroll view resting AT its top is "already there" and
            // UIKit never consults its delegate — park it one point
            // down so the tap always has somewhere to go. The
            // delegate returns false, so the offset never actually
            // moves.
            claimer.contentOffset = CGPoint(x: 0, y: 1)
            claimer.scrollsToTop = true
            claimer.isHidden = false // hidden scroll views are ineligible
            claimer.alpha = 0.02     // effectively invisible, still eligible
            claimer.delegate = self
            addSubview(claimer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        // Transparent to touches: the bridge exists only for the
        // status-bar gesture resolution, never for direct hits.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                restore()
                return
            }
            // The transcript's backing scroll view can attach after
            // this probe does — sweep now and again a beat later.
            sweep()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.sweep()
            }
        }

        private func sweep() {
            guard let window else { return }
            var found: [UIScrollView] = []
            collectScrollViews(in: window, into: &found)
            var count = 0
            for sv in found where sv !== claimer && sv.scrollsToTop {
                sv.scrollsToTop = false
                disabled.append(Weak(sv))
                count += 1
            }
            bridgeLog.notice("sweep: \(found.count, privacy: .public) scroll views, disabled \(count, privacy: .public), claimer eligible=\(self.claimer.scrollsToTop, privacy: .public) window=\(self.claimer.window != nil, privacy: .public)")
        }

        private func restore() {
            for box in disabled {
                box.value?.scrollsToTop = true
            }
            disabled.removeAll()
        }

        private func collectScrollViews(in view: UIView, into out: inout [UIScrollView]) {
            for sub in view.subviews {
                if let sv = sub as? UIScrollView { out.append(sv) }
                collectScrollViews(in: sub, into: &out)
            }
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            bridgeLog.notice("status-bar tap claimed")
            onTap()
            return false
        }
    }

    struct Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
}
