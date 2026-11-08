import SwiftUI
import UserNotifications
import PsmithKit
import PsmithUI

/// Settings › Notifications (board SettingsNotifications). Turning the
/// switch on asks iOS for permission up front, so the system prompt shows
/// now rather than when the first reply lands. When iOS has notifications
/// off for Psmith the switch can't change that, so the page says so.
struct SettingsNotifications: View {
    @Environment(AppPreferences.self) private var prefs
    @State private var permission: NotificationPermission = .unknown

    var body: some View {
        SettingsNotificationsScreen(
            isOn: Binding(
                get: { prefs.notifyOnUnfocusedCompletion },
                set: { on in
                    prefs.notifyOnUnfocusedCompletion = on
                    if on { requestPermission() }
                }
            ),
            permission: permission,
            openSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        )
        .task { await refresh() }
    }

    private func refresh() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        permission = NotificationPermission(s.authorizationStatus)
    }

    private func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in permission = granted ? .allowed : .denied }
                }
            case .denied:
                Task { @MainActor in permission = .denied }
            default:
                break
            }
        }
    }
}

enum NotificationPermission: Equatable {
    case unknown, notAsked, allowed, denied

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .allowed
        @unknown default: self = .unknown
        }
    }
}

struct SettingsNotificationsScreen: View {
    @Binding var isOn: Bool
    let permission: NotificationPermission
    let openSettings: () -> Void

    var body: some View {
        IKSettingsPage(title: "Notifications") {
            IKGroup {
                IKSSwitchRow(title: "Notify when a reply finishes", note: "Only while Psmith is in the background.", isOn: $isOn)
            }
            .padding(.top, 4)
            IKSFooter("iOS asks for permission when you turn this on.")

            if permission != .unknown {
                IKSHead("System permission")
                IKGroup {
                    switch permission {
                    case .denied:
                        IKSValueRow(title: "Notifications", value: "Off in iOS Settings", color: IK.red)
                        IKSActionRow(title: "Open iOS Settings", chevron: true, action: openSettings)
                    case .allowed:
                        IKSValueRow(title: "Notifications", value: "Allowed", color: IK.green, dot: IK.green)
                    default:
                        IKSValueRow(title: "Notifications", value: "Not asked yet")
                    }
                }
                if permission == .denied {
                    IKSFooter("Notifications are turned off for Psmith in iOS Settings, so nothing will ring until they’re allowed there.")
                }
            }
        }
    }
}
