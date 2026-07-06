import SwiftUI
import PsmithKit
import CoreLocation

/// Settings → Privacy. One toggle per opt-in fact the device
/// can supply to the server's grounding pipeline. Today: just
/// location; future siblings (Calendar peek, etc.) plug in here
/// using the same shape.
///
/// The toggle owns:
///   • The persistent "user wants this" flag (UserDefaults via
///     `LocationFactPreference`).
///   • The OS-permission flow (CLLocationManager via the shared
///     `LocationProvider`).
///   • The "current location" preview line so the user can see
///     what would actually ride along on their next send.
struct PrivacyDetailView: View {
    @State private var locationEnabled = LocationFactPreference.enabled
    @State private var locationProvider = LocationProvider.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $locationEnabled) {
                    Label("Send location", systemImage: "location")
                }
                .onChange(of: locationEnabled) { _, on in
                    LocationFactPreference.enabled = on
                    if on {
                        // Asks for permission if not yet decided;
                        // immediately requests a fix when granted.
                        locationProvider.requestPermissionAndFix()
                    }
                }

                permissionRow
                if locationEnabled, locationProvider.authorization == .authorizedWhenInUse
                    || locationProvider.authorization == .authorizedAlways {
                    locationPreview
                }
            } header: {
                Text("Location")
            } footer: {
                Text("When enabled, an approximate location (e.g. \"Brooklyn, NY\") is included with each message your device sends. Only basic_grounding (or other plugins that explicitly request it) will use it. Toggle off to stop sending immediately.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch locationProvider.authorization {
        case .notDetermined:
            statusRow("System permission", value: "Not asked yet", style: .secondary)
        case .restricted:
            statusRow("System permission", value: "Restricted", style: .red)
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                statusRow("System permission", value: "Denied", style: .red)
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.callout)
            }
        case .authorizedWhenInUse, .authorizedAlways:
            statusRow("System permission", value: "Authorized", style: .green)
        @unknown default:
            statusRow("System permission", value: "Unknown", style: .secondary)
        }
    }

    @ViewBuilder
    private var locationPreview: some View {
        if let coords = locationProvider.lastCoords {
            VStack(alignment: .leading, spacing: 4) {
                if let city = locationProvider.lastCity {
                    statusRow("City", value: city, style: .primary)
                }
                statusRow("Coordinates", value: coords, style: .secondary)
                if let at = locationProvider.lastFixAt {
                    statusRow("Last fix", value: relative(at), style: .secondary)
                }
            }
        } else {
            HStack {
                Text("Acquiring location…")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }

    private func statusRow(_ key: String, value: String, style: TextStyle) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value)
                .foregroundStyle(style.color)
                .monospacedDigit()
        }
    }

    private enum TextStyle {
        case primary, secondary, red, green
        var color: Color {
            switch self {
            case .primary: return .primary
            case .secondary: return .secondary
            case .red: return .red
            case .green: return .green
            }
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
