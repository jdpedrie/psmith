import AppKit
import Foundation
import Observation
import UserNotifications

import ReeveKit

/// Drives macOS local notifications for "your reply is ready" events.
/// Wired into ConversationViewModel.onAssistantTurnComplete by
/// ConversationView via the shared `sharedNotifier` instance;
/// suppresses delivery when Reeve is the active app (the user is
/// already looking at the result) or when the user has disabled the
/// toggle in General settings.
///
/// Click handling routes through `sharedNavigator.pendingConversationSelection`
/// so the app's HomeView can pick it up at scene-active time and
/// switch to the right conversation.
@MainActor
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let prefs: AppPreferences
    private let navigator: Navigator

    init(prefs: AppPreferences, navigator: Navigator) {
        self.prefs = prefs
        self.navigator = navigator
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called from ConversationViewModel.onAssistantTurnComplete. Posts
    /// a notification iff (a) the user enabled the toggle and (b) the
    /// app isn't currently active. Permission is requested on first
    /// notify (rather than at app launch) so the system prompt arrives
    /// in context — when the user just produced a generation in the
    /// background.
    func generationCompleted(
        conversationID: String,
        conversationTitle: String?,
        messageID: String,
        preview: String
    ) {
        guard prefs.notifyOnUnfocusedCompletion else { return }
        if NSApp.isActive { return }

        ensurePermission { [weak self] granted in
            guard granted, let self else { return }
            Task { @MainActor in
                self.deliver(
                    conversationID: conversationID,
                    title: conversationTitle ?? "Untitled",
                    preview: preview
                )
            }
        }
    }

    private func ensurePermission(_ done: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                done(true)
            case .denied:
                done(false)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in done(granted) }
            @unknown default:
                done(false)
            }
        }
    }

    private func deliver(conversationID: String, title: String, preview: String) {
        let content = UNMutableNotificationContent()
        content.title = "Reeve"
        content.subtitle = title
        content.body = preview
        content.sound = .default
        content.userInfo = ["conversation_id": conversationID]
        content.threadIdentifier = "conversation:\(conversationID)" // groups consecutive notifications per conversation in Notification Center

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                NSLog("MacNotifier: add request failed: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification arrives while the app IS active.
    /// We've already filtered for inactive-only delivery upstream, but
    /// implement defensively. Don't show in-app banners for our own
    /// notifications — the user is here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    /// User clicked the notification (or its "Open" action). Bring the
    /// app to the front and route to the matching conversation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let convID = userInfo["conversation_id"] as? String
        // Call the completion handler immediately on the delivering
        // (non-main) thread — Swift 6 strict concurrency forbids
        // capturing it across the main-actor hop. The actual UI work
        // (window activation, navigator update) hops to main on its
        // own; the system's bookkeeping doesn't need to wait on us.
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let convID {
                navigator.pendingConversationSelection = convID
            }
        }
    }
}

/// Shared module-level instance. Constructed lazily on first access so
/// the AppPreferences singleton has been touched at least once before
/// the UNUserNotificationCenter delegate hookup runs.
@MainActor
let sharedNotifier: MacNotifier = MacNotifier(prefs: sharedAppPreferences, navigator: sharedNavigator)
