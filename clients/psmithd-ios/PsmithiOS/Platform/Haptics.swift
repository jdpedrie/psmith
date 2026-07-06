import UIKit

/// Thin wrapper around UIKit's haptic feedback generators. Single
/// import point so call sites read like `Haptics.impact()` instead of
/// recreating a generator each time.
///
/// Per `docs/clients/ios-reference.md` — sites that get haptics today:
///   - send button press (`.light` impact)
///   - delete confirmed (`.warning` notification)
///   - login success (`.success` notification)
enum Haptics {
    /// Tactile bump. Use for affirmative micro-actions (send, toggle).
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Stronger semantic feedback (`.success`, `.warning`, `.error`).
    /// Use for destructive confirmations and major state changes.
    static func notify(_ kind: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(kind)
    }
}
