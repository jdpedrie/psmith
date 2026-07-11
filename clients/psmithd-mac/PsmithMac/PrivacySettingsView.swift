import SwiftUI
import PsmithKit
import CoreLocation
import AppKit

/// Mac settings panel for opt-in device facts. Today: location. The
/// toggle owns the persistent preference (LocationFactPreference),
/// the OS-permission flow (shared LocationProvider), and a preview of
/// what would actually ride along on the next send.
struct PrivacySettingsView: View {
    @State private var locationEnabled = LocationFactPreference.enabled
    @State private var locationProvider = LocationProvider.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy")
                        .scaledFont(.title2, weight: .semibold)
                    Text("Facts this Mac may attach to outgoing messages. Everything here is off until you turn it on, and stops immediately when you turn it off.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                sectionCard("Location") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $locationEnabled) {
                            Label("Send location", systemImage: "location")
                        }
                        .onChange(of: locationEnabled) { _, on in
                            LocationFactPreference.enabled = on
                            if on {
                                locationProvider.requestPermissionAndFix()
                            }
                        }
                        permissionRow
                        if locationEnabled, isAuthorized {
                            locationPreview
                        }
                        Text("When enabled, an approximate location (e.g. \"Brooklyn, NY\") is included with each message this Mac sends. Only basic_grounding (or other plugins that explicitly request it) will use it.")
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var isAuthorized: Bool {
        locationProvider.authorization == .authorizedAlways
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch locationProvider.authorization {
        case .notDetermined:
            statusRow("System permission", value: "Not asked yet", color: .secondary)
        case .restricted:
            statusRow("System permission", value: "Restricted", color: .red)
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                statusRow("System permission", value: "Denied", color: .red)
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .scaledFont(.callout)
            }
        case .authorizedAlways:
            statusRow("System permission", value: "Authorized", color: .green)
        @unknown default:
            statusRow("System permission", value: "Unknown", color: .secondary)
        }
    }

    @ViewBuilder
    private var locationPreview: some View {
        if let coords = locationProvider.lastCoords {
            VStack(alignment: .leading, spacing: 4) {
                if let city = locationProvider.lastCity {
                    statusRow("City", value: city, color: .primary)
                }
                statusRow("Coordinates", value: coords, color: .secondary)
                if let at = locationProvider.lastFixAt {
                    statusRow("Last fix", value: relative(at), color: .secondary)
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

    private func statusRow(_ key: String, value: String, color: Color) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value)
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    @ViewBuilder
    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
