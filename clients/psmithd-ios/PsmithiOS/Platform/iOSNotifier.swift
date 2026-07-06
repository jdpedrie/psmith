import UIKit
import Foundation
import Observation
import UserNotifications

import PsmithKit
import PsmithUI

/// iOS counterpart to MacNotifier. Drives "your reply is ready" local
/// notifications via `UNUserNotificationCenter`; mirrors the same
/// suppression rule (no notification when the app is currently
/// active). Click handling routes through `iOSNavigator` so the
/// active tab + conversation selection survive the focus hop.
///
/// Wired into the env at app construction time
/// (`.environment(\.notifier, sharedIOSNotifier)`); the
/// `ConversationViewModel`'s `onAssistantTurnComplete` closure reads
/// it at conversation-mount time.
@MainActor
final class iOSNotifier: NSObject, UNUserNotificationCenterDelegate, Notifier {
    private let prefs: AppPreferences
    private let navigator: iOSNavigator

    init(prefs: AppPreferences, navigator: iOSNavigator) {
        self.prefs = prefs
        self.navigator = navigator
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func generationCompleted(
        conversationID: String,
        conversationTitle: String?,
        messageID: String,
        preview: String
    ) {
        guard prefs.notifyOnUnfocusedCompletion else { return }
        // Don't fire when the app is currently active — the user is
        // already looking at the result.
        if UIApplication.shared.applicationState == .active { return }

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
        content.title = "Psmith"
        content.subtitle = title
        content.body = preview
        content.sound = .default
        content.userInfo = ["conversation_id": conversationID]
        // Groups consecutive notifications per conversation in
        // Notification Center — same key the Mac uses.
        content.threadIdentifier = "conversation:\(conversationID)"

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                NSLog("iOSNotifier: add request failed: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when a notification arrives while the app IS active.
    /// We've already filtered for inactive-only delivery upstream so
    /// this is defensive — drop the in-app banner because the user is
    /// already here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    /// User tapped the notification. Hop to the Chats tab + queue a
    /// pending conversation selection that ChatsRoot will consume on
    /// next appear. Completion handler called immediately on the
    /// delivering thread per Swift 6 strict-concurrency
    /// (the same shape MacNotifier uses).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let convID = userInfo["conversation_id"] as? String
        completionHandler()
        Task { @MainActor in
            if let convID {
                navigator.pendingConversationSelection = convID
            }
        }
    }
}

/// Module-level shared instance — same pattern as `sharedNotifier` on
/// Mac. Lazily constructed on first access so the prefs + navigator
/// singletons are guaranteed live.
@MainActor
let sharedIOSNotifier: iOSNotifier = iOSNotifier(
    prefs: sharedAppPreferences,
    navigator: sharedIOSNavigator
)
