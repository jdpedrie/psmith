import SwiftUI
import PsmithKit
import PsmithUI
import CoreLocation
import UserNotifications
import AppKit

/// The General pane (board "General"): the context warning, which follows
/// the user to every device, then what this Mac does on its own:
/// notifications, location, the on-device cache. About closes it.
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppPreferences.self) private var prefs

    @State private var capMB: Int = CachePreferences.capBytes / (1024 * 1024)
    @State private var usedBytes: Int = 0
    @State private var clearing = false
    @State private var confirmingClear = false
    @State private var customWarning = ""
    @State private var showingCustom = false
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var locationEnabled = LocationFactPreference.enabled
    @State private var location = LocationProvider.shared
    @State private var serverVersion = "…"

    private static let warningPresets: [Int32] = [50_000, 75_000, 100_000, 150_000, 200_000]
    private static let capPresets: [Int] = [50, 100, 250, 500, 1024]

    var body: some View {
        @Bindable var prefs = prefs
        SKFormPage {
            contextWarning
            SKGroup("Notifications") {
                SKRow("Notify when a reply finishes", detail: "Only while Psmith is in the background.") {
                    Toggle("Notify when a reply finishes", isOn: $prefs.notifyOnUnfocusedCompletion).skSwitch()
                }
                notificationPermissionRow
            } trailing: {
                SKChip.thisMac
            }
            location(enabled: $locationEnabled)
            cache
            SKGroup("About") {
                SKRow("Psmith") { Text(BuildInfo.commit).sk(13, SK.secondary, mono: true) }
                SKRow("Server") {
                    Text("\(serverVersion) · \(app.serverURL.host ?? app.serverURL.absoluteString)").sk(13, SK.secondary, mono: true)
                }
            }
        }
        .task {
            usedBytes = await app.client.cache?.totalBytes() ?? 0
            await app.preferences.load()
            await refreshNotificationStatus()
            switch await app.client.auth.probe() {
            case .ok(_, let version): serverVersion = version.isEmpty ? "dev" : version
            case .wrongServer, .unreachable: serverVersion = "unreachable"
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings: the permission may have changed.
            Task { await refreshNotificationStatus() }
        }
    }

    // MARK: Context warning

    private var warningTokens: Int32 { app.preferences.preferences.contextWarningTokens }

    private var isCustomWarning: Bool {
        warningTokens > 0 && !Self.warningPresets.contains(warningTokens)
    }

    private var warningLabel: String {
        if showingCustom || isCustomWarning { return "Custom" }
        if warningTokens == 0 { return "Off" }
        return "\(ContextWarning.compact(warningTokens)) tokens"
    }

    private var contextWarning: some View {
        SKGroup("Context warning") {
            SKRow("Warn at", detail: "Past this size the context shows beside the model under the message field. Click it to compress.") {
                SKPopup(value: warningLabel, minWidth: 150) {
                    Button("Off") { setWarning(0) }
                    ForEach(Self.warningPresets, id: \.self) { preset in
                        Button("\(ContextWarning.compact(preset)) tokens") { setWarning(preset) }
                    }
                    Divider()
                    Button("Custom…") {
                        customWarning = warningTokens > 0 ? String(warningTokens / 1_000) : ""
                        showingCustom = true
                    }
                }
            }
            if showingCustom || isCustomWarning {
                SKRow("Custom threshold", detail: "1 to 2,000. Saves when you press Return.") {
                    HStack(spacing: 8) {
                        TextField("Thousands of tokens", text: $customWarning)
                            .skField(width: 70, mono: true)
                            .onSubmit(saveCustomWarning)
                            .onAppear {
                                if customWarning.isEmpty, warningTokens > 0 { customWarning = String(warningTokens / 1_000) }
                            }
                        Text("thousand tokens").sk(12.5, SK.secondary)
                    }
                }
            }
        } trailing: {
            SKChip.synced
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Near a model's own limit the context shows in red whatever this is set to.")
                if let error = app.preferences.error {
                    Text(error).foregroundStyle(SK.red)
                }
            }
        }
    }

    private func setWarning(_ tokens: Int32) {
        showingCustom = false
        Task { await app.preferences.setContextWarningTokens(tokens) }
    }

    private func saveCustomWarning() {
        guard let k = Int32(customWarning.trimmingCharacters(in: .whitespaces)), (1...2_000).contains(k) else { return }
        showingCustom = false
        Task { await app.preferences.setContextWarningTokens(k * 1_000) }
    }

    // MARK: Notifications

    @ViewBuilder
    private var notificationPermissionRow: some View {
        switch notificationStatus {
        case .denied:
            SKRow("macOS permission", detail: "Notifications are off for Psmith in System Settings, so nothing posts.") {
                HStack(spacing: 10) {
                    Text("Not allowed").sk(13, SK.orange)
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .skButton(small: true)
                }
            }
        case .authorized, .provisional:
            SKRow("macOS permission") { Text("Allowed").sk(13, SK.green) }
        default:
            SKRow("macOS permission", detail: "macOS asks the first time a notification would post.") {
                Text("Not asked yet").sk(13, SK.secondary)
            }
        }
    }

    private func refreshNotificationStatus() async {
        // The notification center raises outside an app bundle (tests,
        // `swift run`), where there's no permission to report anyway.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Location

    private func location(enabled: Binding<Bool>) -> some View {
        SKGroup("Location") {
            SKRow("Send location", detail: "Attach an approximate location to each message.") {
                Toggle("Send location", isOn: enabled).skSwitch()
                    .onChange(of: enabled.wrappedValue) { _, on in
                        LocationFactPreference.enabled = on
                        if on { location.requestPermissionAndFix() }
                    }
            }
            locationPermissionRow
            if enabled.wrappedValue, location.authorization == .authorizedAlways {
                SKRow("Now") {
                    if let city = location.lastCity ?? location.lastCoords {
                        HStack(spacing: 6) {
                            Text(city).sk(13)
                            if let at = location.lastFixAt {
                                Text("· \(Self.relative(at))").sk(12.5, SK.tertiary)
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Finding…").sk(12.5, SK.secondary)
                        }
                    }
                }
            }
        } trailing: {
            SKChip.thisMac
        } footer: {
            Text("Only basic_grounding, or another plugin that asks for it, uses the location.")
        }
    }

    @ViewBuilder
    private var locationPermissionRow: some View {
        switch location.authorization {
        case .authorizedAlways:
            SKRow("macOS permission") { Text("Allowed").sk(13, SK.green) }
        case .denied, .restricted:
            SKRow("macOS permission", detail: "Location is off for Psmith in System Settings.") {
                HStack(spacing: 10) {
                    Text("Not allowed").sk(13, SK.orange)
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .skButton(small: true)
                }
            }
        default:
            SKRow("macOS permission", detail: "macOS asks when you turn this on.") {
                Text("Not asked yet").sk(13, SK.secondary)
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Cache

    private var cache: some View {
        SKGroup("On-device cache") {
            SKRow("Used") { Text(Self.bytes(usedBytes)).sk(13, SK.secondary, mono: true) }
            SKRow("Keep up to", detail: "Lowering it frees space now.") {
                SKPopup(value: Self.megabytes(capMB), minWidth: 100) {
                    ForEach(Self.capPresets, id: \.self) { mb in
                        Button(Self.megabytes(mb)) { setCap(mb) }
                    }
                }
            }
            if confirmingClear {
                SKRawRow(vertical: 8, horizontal: 8) {
                    SKConfirmStrip(
                        question: "Clear the cache?",
                        detail: "Conversations reload from the server the next time you open them. Nothing on the server changes.",
                        confirmLabel: "Clear Cache",
                        onCancel: { confirmingClear = false },
                        onConfirm: clearCache
                    )
                }
            } else {
                SKRow("Clear cache", detail: "Conversations reload from the server the next time you open them.") {
                    Button(clearing ? "Clearing…" : "Clear Cache…") { confirmingClear = true }
                        .skButton(.destructive)
                        .disabled(clearing || usedBytes == 0)
                }
            }
        } trailing: {
            SKChip.thisMac
        }
    }

    private func setCap(_ mb: Int) {
        capMB = mb
        let bytes = mb * 1024 * 1024
        CachePreferences.capBytes = bytes
        // Lowering the cap reclaims disk now, not at the next cache write.
        Task {
            try? await app.client.cache?.evictIfOverCap(bytes)
            usedBytes = await app.client.cache?.totalBytes() ?? 0
        }
    }

    private func clearCache() {
        confirmingClear = false
        Task {
            clearing = true
            defer { clearing = false }
            try? await app.client.cache?.clear()
            usedBytes = await app.client.cache?.totalBytes() ?? 0
        }
    }

    private static func megabytes(_ mb: Int) -> String {
        mb >= 1024 && mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    private static func bytes(_ n: Int) -> String {
        let mb = Double(n) / (1024 * 1024)
        return mb < 1 ? String(format: "%.0f KB", Double(n) / 1024) : String(format: "%.1f MB", mb)
    }
}
