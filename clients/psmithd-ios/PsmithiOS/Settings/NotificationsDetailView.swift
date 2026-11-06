import SwiftUI
import UserNotifications
import PsmithKit
import PsmithUI

/// iOS Notifications — single Toggle per `docs/clients/ios-reference.md`
/// Uses iOS Form styling (rounded sections + separators) for the
/// iOS-Settings-app feel. Toggle-on requests notification permission
/// upfront so the system dialog appears immediately rather than at
/// first-fire-time.
struct NotificationsDetailView: View {
    @Environment(AppPreferences.self) private var prefs
    /// The system has notifications off for Psmith. The toggle can't
    /// change that, so say so instead of letting it flip on silently.
    @State private var deniedBySystem = false

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
                Text("Posts a notification when an assistant turn completes while Psmith is in the background. Suppressed when Psmith is the active app.")
            }
            if deniedBySystem && prefs.notifyOnUnfocusedCompletion {
                Section {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } footer: {
                    Text("Notifications are turned off for Psmith in iOS Settings, so nothing will ring until they're allowed there.")
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAuthorization() }
    }

    private func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        deniedBySystem = settings.authorizationStatus == .denied
    }

    private func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in deniedBySystem = !granted }
                }
            case .denied:
                Task { @MainActor in deniedBySystem = true }
            default:
                break
            }
        }
    }
}
