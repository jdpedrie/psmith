import SwiftUI
import UIKit
import os.log

private let gestureLog = Logger(subsystem: "dev.jdpedrie.psmith", category: "BackSwipe")

/// Restores edge-only back navigation while a conversation is frontmost.
///
/// iOS 26 gave UINavigationController a second pop gesture —
/// `interactiveContentPopGestureRecognizer` — that recognizes a
/// rightward drag ANYWHERE in the content area, not just at the screen
/// edge. In the transcript that's hostile: wide code blocks and tables
/// scroll horizontally, and any rightward drag that misses one pops
/// the conversation (verified in the sim: a drag starting at x=116
/// navigated back). SwiftUI exposes no control, so this zero-size
/// UIKit probe reaches the hosting navigation controller and disables
/// JUST the content-area recognizer for the duration of the screen.
/// The classic edge swipe (`interactivePopGestureRecognizer`) stays
/// enabled, and the recognizer is restored on disappear so every
/// other screen keeps the system-default behavior.
struct BackSwipeLimiter: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) {}

    final class Probe: UIViewController {
        /// The recognizer THIS probe disabled — restore-on-disappear
        /// must not re-enable a recognizer someone else owns disabling.
        private weak var disabled: UIGestureRecognizer?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            limit()
            // The parent chain can attach a beat after willAppear when
            // SwiftUI hosts the representable; one async retry covers it.
            DispatchQueue.main.async { [weak self] in self?.limit() }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            disabled?.isEnabled = true
            disabled = nil
        }

        private func limit() {
            guard disabled == nil,
                  let recognizer = navigationController?.interactiveContentPopGestureRecognizer,
                  recognizer.isEnabled
            else { return }
            recognizer.isEnabled = false
            disabled = recognizer
            // The edge recognizer must survive this — it's the whole
            // point of disabling only the content-area one. Log both
            // states so a regression shows up in `log show` instead of
            // needing a thumb on a device.
            let edge = navigationController?.interactivePopGestureRecognizer
            gestureLog.notice("content pop disabled; edge recognizer present=\(edge != nil, privacy: .public) enabled=\(edge?.isEnabled ?? false, privacy: .public)")
        }
    }
}
