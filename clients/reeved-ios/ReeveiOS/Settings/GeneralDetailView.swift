import SwiftUI
import ReeveKit

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

    var body: some View {
        Form {
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
                Text("Reeve keeps recent conversations on this device so they stay readable when the server is unreachable. Encrypted at rest by iOS data protection.")
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
}
