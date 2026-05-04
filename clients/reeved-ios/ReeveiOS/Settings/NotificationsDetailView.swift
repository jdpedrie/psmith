import SwiftUI
import UserNotifications
import ReeveKit
import ReeveUI

/// iOS Notifications — single Toggle per `docs/ios-screens.md` §2.19.
/// Uses iOS Form styling (rounded sections + separators) for the
/// iOS-Settings-app feel. Toggle-on requests notification permission
/// upfront so the system dialog appears immediately rather than at
/// first-fire-time.
struct NotificationsDetailView: View {
    @Environment(AppPreferences.self) private var prefs

    var body: some View {
        @Bindable var p = prefs
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { prefs.notifyOnUnfocusedCompletion },
                    set: { newValue in
                        prefs.notifyOnUnfocusedCompletion = newValue
                        if newValue {
                            requestPermission()
                        }
                    }
                )) {
                    Text("Ring on generation finish")
                }
            } footer: {
                Text("Posts a notification when an assistant turn completes while Reeve is in the background. Suppressed when Reeve is the active app.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            default:
                // Already determined — nothing to prompt for. If the
                // user denied earlier, the toggle still flips on but
                // delivery silently no-ops; they have to re-enable in
                // Settings.app to actually receive notifications.
                break
            }
        }
    }
}
