import SwiftUI
import UIKit

/// The transcript's long-press, as a real `UILongPressGestureRecognizer`
/// rather than SwiftUI's `.onLongPressGesture`.
///
/// The rows sit inside a UIKit scroll view, and a SwiftUI long-press
/// there arbitrates with the scroll view's pan through SwiftUI's own
/// gesture graph: on device the hold intermittently never fired (the
/// user-reported "long-press does nothing"), and nothing a simulator
/// tap reproduces. A UIKit recognizer goes through the same arbitration
/// as the system context menu it replaces: hold still past the press
/// duration and the press begins and the pan fails; move past the
/// allowable distance first and the pan wins and the press fails.
///
/// It fires on `.began`, the moment the hold is recognized, so the menu
/// is up while the finger is still down, matching the system menu.
struct MessageLongPressGesture: UIGestureRecognizerRepresentable {
    /// Matches `UIContextMenuInteraction`'s feel more closely than
    /// UIKit's 0.5s default, which reads as sluggish next to it.
    static let minimumPressDuration: TimeInterval = 0.4
    /// UIKit's default. Real fingertips drift a few points while
    /// holding, and the pan's own slop is about this size.
    static let allowableMovement: CGFloat = 10

    let action: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = Self.minimumPressDuration
        recognizer.allowableMovement = Self.allowableMovement
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began {
            action()
        }
    }
}

extension View {
    /// Long-press (and its VoiceOver equivalent) opens the message's
    /// action menu. The only way any transcript row should attach one.
    func messageActionsOnLongPress(_ action: @escaping () -> Void) -> some View {
        gesture(MessageLongPressGesture(action: action))
            .accessibilityAction(named: "Message actions", action)
    }
}
