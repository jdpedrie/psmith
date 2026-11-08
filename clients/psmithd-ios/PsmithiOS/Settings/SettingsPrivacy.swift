import SwiftUI
import CoreLocation
import PsmithKit
import PsmithUI

/// Settings › Privacy (board SettingsPrivacy). One switch per fact the
/// device can add to a message; today, location. The switch owns the
/// stored preference and the iOS permission request, and the rows under it
/// show exactly what would ride along on the next send.
struct SettingsPrivacy: View {
    @State private var enabled = LocationFactPreference.enabled
    @State private var location = LocationProvider.shared

    var body: some View {
        SettingsPrivacyScreen(
            enabled: $enabled,
            authorization: location.authorization,
            city: location.lastCity,
            coordinates: location.lastCoords,
            lastFix: location.lastFixAt,
            openSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        )
        .onChange(of: enabled) { _, on in
            LocationFactPreference.enabled = on
            // Asks when undecided; asks for a fix once granted.
            if on { location.requestPermissionAndFix() }
        }
    }
}

struct SettingsPrivacyScreen: View {
    @Binding var enabled: Bool
    let authorization: CLAuthorizationStatus
    let city: String?
    let coordinates: String?
    let lastFix: Date?
    let openSettings: () -> Void
    var now: Date = .now

    private var granted: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    var body: some View {
        IKSettingsPage(title: "Privacy") {
            IKSHead("Location", note: "This iPhone", first: true)
            IKGroup {
                IKSSwitchRow(title: "Send location", note: "Attach an approximate location to each message.", isOn: $enabled)
                permissionRow
                if authorization == .denied {
                    IKSActionRow(title: "Open iOS Settings", chevron: true, action: openSettings)
                }
                if enabled && granted {
                    if let coordinates {
                        if let city { IKSValueRow(title: "City", value: city) }
                        IKSValueRow(title: "Coordinates", value: coordinates, mono: true)
                        if let lastFix { IKSValueRow(title: "Last fix", value: SettingsFormat.relative(lastFix, now: now)) }
                    } else {
                        IKSRow {
                            Text("Acquiring location…").foregroundStyle(IK.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            IKSFooter("Off until you turn it on. When on, each message this iPhone sends includes an approximate location, such as “Brooklyn, NY”. Only basic_grounding, or another plugin that asks for it, uses it. While using the app or Always both work.")
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch authorization {
        case .notDetermined:
            IKSValueRow(title: "System permission", value: "Not asked yet")
        case .restricted:
            IKSValueRow(title: "System permission", value: "Restricted", color: IK.red)
        case .denied:
            IKSValueRow(title: "System permission", value: "Denied", color: IK.red)
        case .authorizedWhenInUse:
            IKSValueRow(title: "System permission", value: "While using the app", color: IK.green, dot: IK.green)
        case .authorizedAlways:
            IKSValueRow(title: "System permission", value: "Always", color: IK.green, dot: IK.green)
        @unknown default:
            IKSValueRow(title: "System permission", value: "Unknown")
        }
    }
}
