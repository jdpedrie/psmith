import SwiftUI
import PsmithKit

/// Mac settings panel for app-level preferences that don't fit the
/// other categories. Currently the on-device cache controls; future
/// home for defaults like conversation order.
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var capMB: Int = CachePreferences.capBytes / (1024 * 1024)
    @State private var currentBytes: Int = 0
    @State private var clearing = false
    @State private var showingClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("General")
                        .scaledFont(.title2, weight: .semibold)
                    Text("Psmith keeps recent conversations on this Mac so they stay readable when the server is unreachable.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                sectionCard("On-device cache") {
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
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            currentBytes = await app.client.cache?.totalBytes() ?? 0
        }
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
