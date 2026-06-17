import Foundation
import SwiftUI

/// Platform-glue interface for "fired when an assistant turn finishes".
/// Each shell wires its OS-native notification path behind this:
///   - Mac: `UNUserNotificationCenter` + suppress when `NSApp.isActive`
///   - iOS: `UNUserNotificationCenter` + suppress when `ScenePhase ==
///     .active`; backgrounded streams may also mint a local push via
///     BGTaskScheduler-driven background continuation.
///
/// Views/view-models reach this via `@Environment(\.notifier)` so
/// `ConversationView` doesn't have to know whether the running app is
/// AppKit or UIKit shaped.
public protocol Notifier: Sendable {
    /// Called from `ConversationViewModel` after a successful assistant
    /// turn lands in `messages`. The implementation decides whether to
    /// surface a system notification — typically "yes, only if the
    /// app is currently backgrounded; never when the user is already
    /// looking at the result".
    @MainActor
    func generationCompleted(
        conversationID: String,
        conversationTitle: String?,
        messageID: String,
        preview: String
    )
}

/// No-op default — used in tests, snapshot harnesses, and any pane
/// that hasn't been injected with the platform-specific implementation
/// yet. Calls drop on the floor; no notification is posted.
public struct NoopNotifier: Notifier {
    public init() {}
    @MainActor
    public func generationCompleted(
        conversationID: String,
        conversationTitle: String?,
        messageID: String,
        preview: String
    ) {}
}

private struct NotifierEnvironmentKey: EnvironmentKey {
    static let defaultValue: Notifier = NoopNotifier()
}

public extension EnvironmentValues {
    /// The platform notifier, injected by the shell at scene
    /// construction time. Reading this in a view body is the supported
    /// way to fire a "your reply is ready" notification — never reach
    /// into `UNUserNotificationCenter` directly from shared code.
    var notifier: Notifier {
        get { self[NotifierEnvironmentKey.self] }
        set { self[NotifierEnvironmentKey.self] = newValue }
    }
}
