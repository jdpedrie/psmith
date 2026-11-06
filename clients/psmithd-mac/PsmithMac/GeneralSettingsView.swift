import SwiftUI
import PsmithKit

/// Mac settings panel for app-level preferences that don't fit the
/// other categories: the context warning (synced across devices) and
/// the on-device cache.
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var capMB: Int = CachePreferences.capBytes / (1024 * 1024)
    @State private var currentBytes: Int = 0
    @State private var clearing = false
    @State private var showingClearConfirm = false

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Psmith keeps recent conversations on this Mac so they stay readable when the server is unreachable."
        ) {
                SettingsSection(title: "Context warning") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Warn at")
                            Spacer()
                            Picker("Warn at", selection: warningBinding) {
                                Text("Off").tag(Int32(0))
                                ForEach(Self.warningPresets, id: \.self) { preset in
                                    Text("\(ContextWarning.compact(preset)) tokens").tag(preset)
                                }
                                if warningTokens > 0, !Self.warningPresets.contains(warningTokens) {
                                    Text("\(ContextWarning.compact(warningTokens)) tokens").tag(warningTokens)
                                }
                                Text("Custom…").tag(Self.customTag)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                        Text("Past this size, a conversation's context shows beside the model under the message field; click it to compress. Near a model's own limit it shows in red whatever this is set to. Applies on all your devices.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error = app.preferences.error {
                            Text(error)
                                .scaledFont(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .alert("Warn at", isPresented: $editingCustomWarning) {
                    TextField("Thousands of tokens", text: $customWarningText)
                    Button("Save") {
                        if let k = Int32(customWarningText.trimmingCharacters(in: .whitespaces)), k > 0, k <= 2_000 {
                            Task { await app.preferences.setContextWarningTokens(k * 1_000) }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("In thousands of tokens: 120 warns at 120,000.")
                }

                SettingsSection(title: "On-device cache") {
                    VStack(alignment: .leading, spacing: 12) {
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
                            // Lowering the cap should reclaim disk now,
                            // not wait for the next cache write.
                            Task {
                                try? await app.client.cache?.evictIfOverCap(bytes)
                                currentBytes = await app.client.cache?.totalBytes() ?? 0
                            }
                        }
                        Button {
                            showingClearConfirm = true
                        } label: {
                            if clearing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Clearing…")
                                }
                            } else {
                                Label("Clear cache", systemImage: "trash")
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .disabled(clearing)
                        .confirmationDialog(
                            "Clear on-device cache?",
                            isPresented: $showingClearConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Clear", role: .destructive) {
                                Task {
                                    clearing = true
                                    defer { clearing = false }
                                    try? await app.client.cache?.clear()
                                    currentBytes = await app.client.cache?.totalBytes() ?? 0
                                }
                            }
                        } message: {
                            Text("Conversations will reload from the server on next view. No server-side data is affected.")
                        }
                    }
                }
        }
        .task {
            currentBytes = await app.client.cache?.totalBytes() ?? 0
            await app.preferences.load()
        }
    }

    // MARK: - Context warning

    private static let warningPresets: [Int32] = [50_000, 75_000, 100_000, 150_000, 200_000]
    /// Picker tag for "Custom…", never stored.
    private static let customTag: Int32 = -1
    @State private var editingCustomWarning = false
    @State private var customWarningText = ""

    private var warningTokens: Int32 { app.preferences.preferences.contextWarningTokens }

    private var warningBinding: Binding<Int32> {
        Binding(
            get: { warningTokens },
            set: { choice in
                if choice == Self.customTag {
                    customWarningText = warningTokens > 0 ? String(warningTokens / 1_000) : ""
                    editingCustomWarning = true
                } else {
                    Task { await app.preferences.setContextWarningTokens(choice) }
                }
            }
        )
    }

    private var minMB: Int { CachePreferences.minCapBytes / (1024 * 1024) }
    private var maxMB: Int { CachePreferences.maxCapBytes / (1024 * 1024) }

    private func formatBytes(_ n: Int) -> String {
        let mb = Double(n) / (1024 * 1024)
        if mb < 1 {
            return String(format: "%.0f KB", Double(n) / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}
