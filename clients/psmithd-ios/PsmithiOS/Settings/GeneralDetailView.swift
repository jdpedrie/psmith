import SwiftUI
import PsmithKit

/// "General" detail screen — app-level preferences that don't fit
/// the other categories. Currently just the on-device cache
/// controls; future home for things like default conversation order
/// or analytics opt-outs.
struct GeneralDetailView: View {
    @Environment(AppModel.self) private var app

    /// User-tunable cap. Bound to UserDefaults via `CachePreferences`.
    /// Stepper increments in 25 MB chunks across the [25, 1024] MB
    /// range — wide enough that someone running long context-window
    /// experiments has room without giving up the "lightweight" feel.
    @State private var capMB: Int = CachePreferences.capBytes / (1024 * 1024)

    /// Snapshot of the current cache footprint, refreshed onAppear
    /// and after Clear. Off the main path so the slider stays
    /// responsive even when measuring across thousands of entries.
    @State private var currentBytes: Int = 0

    @State private var clearing: Bool = false
    @State private var showingClearConfirm: Bool = false
    @State private var editingCustomWarning = false
    @State private var customWarningText = ""

    var body: some View {
        Form {
            contextWarningSection
            Section {
                HStack {
                    Text("Used")
                    Spacer()
                    Text(formatBytes(currentBytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Stepper(value: $capMB, in: minMB...maxMB, step: 25) {
                    HStack {
                        Text("Cap")
                        Spacer()
                        Text("\(capMB) MB")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .onChange(of: capMB) { _, newMB in
                    let bytes = newMB * 1024 * 1024
                    CachePreferences.capBytes = bytes
                    // Lowering the cap should reclaim disk now, not
                    // wait for the next cache write.
                    Task {
                        try? await app.client.cache?.evictIfOverCap(bytes)
                        currentBytes = await app.client.cache?.totalBytes() ?? 0
                    }
                }

                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    if clearing {
                        ProgressView()
                    } else {
                        Text("Clear cache")
                    }
                }
                .disabled(clearing)
            } header: {
                Text("On-device cache")
            } footer: {
                Text("Psmith keeps recent conversations on this device so they stay readable when the server is unreachable. Encrypted at rest by iOS data protection.")
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            currentBytes = await app.client.cache?.totalBytes() ?? 0
        }
        .alert(
            "Clear on-device cache?",
            isPresented: $showingClearConfirm
        ) {
            Button("Clear", role: .destructive) {
                Task {
                    clearing = true
                    defer { clearing = false }
                    try? await app.client.cache?.clear()
                    currentBytes = await app.client.cache?.totalBytes() ?? 0
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conversations will reload from the server on next view. No server-side data is affected.")
        }
    }

    private var minMB: Int { CachePreferences.minCapBytes / (1024 * 1024) }
    private var maxMB: Int { CachePreferences.maxCapBytes / (1024 * 1024) }

    private func formatBytes(_ n: Int) -> String {
        let mb = Double(n) / (1024 * 1024)
        if mb < 1 {
            let kb = Double(n) / 1024
            return String(format: "%.0f KB", kb)
        }
        return String(format: "%.1f MB", mb)
    }

    // MARK: - Context warning

    private static let warningPresets: [Int32] = [50_000, 75_000, 100_000, 150_000, 200_000]
    /// Picker tag for "Custom…", never stored.
    private static let customTag: Int32 = -1

    private var warningTokens: Int32 {
        app.preferences.preferences.contextWarningTokens
    }

    private var contextWarningSection: some View {
        Section {
            Picker("Warn at", selection: Binding(
                get: { warningTokens },
                set: { choice in
                    if choice == Self.customTag {
                        customWarningText = warningTokens > 0 ? String(warningTokens / 1_000) : ""
                        editingCustomWarning = true
                    } else {
                        Task { await app.preferences.setContextWarningTokens(choice) }
                    }
                }
            )) {
                Text("Off").tag(Int32(0))
                ForEach(Self.warningPresets, id: \.self) { preset in
                    Text("\(ContextWarning.compact(preset)) tokens").tag(preset)
                }
                if warningTokens > 0, !Self.warningPresets.contains(warningTokens) {
                    Text("\(ContextWarning.compact(warningTokens)) tokens").tag(warningTokens)
                }
                Text("Custom…").tag(Self.customTag)
            }
            if let error = app.preferences.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Context warning")
        } footer: {
            Text("When a conversation's context passes this size, it shows beside the model below the message field; tap it to compact. Near a model's own limit it shows in red whatever this is set to. Applies on all your devices.")
        }
        .alert("Warn at", isPresented: $editingCustomWarning) {
            TextField("Thousands of tokens", text: $customWarningText)
                .keyboardType(.numberPad)
            Button("Save") {
                if let k = Int32(customWarningText.trimmingCharacters(in: .whitespaces)), k > 0, k <= 2_000 {
                    Task { await app.preferences.setContextWarningTokens(k * 1_000) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In thousands of tokens: 120 warns at 120,000.")
        }
    }

}
