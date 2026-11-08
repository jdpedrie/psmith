import SwiftUI
import PsmithKit
import PsmithUI

/// Settings › General (board SettingsGeneral): the context-warning size,
/// synced across devices, and this iPhone's conversation cache.
struct SettingsGeneral: View {
    @Environment(AppModel.self) private var app
    /// 25 MB steps across CachePreferences' range.
    @State private var capMB: Int = CachePreferences.capBytes / (1024 * 1024)
    @State private var usedBytes = 0
    @State private var clearing = false
    @State private var confirmingClear = false

    var body: some View {
        SettingsGeneralScreen(
            warnTokens: app.preferences.preferences.contextWarningTokens,
            warnError: app.preferences.error,
            onSetWarn: { tokens in Task { await app.preferences.setContextWarningTokens(tokens) } },
            usedBytes: usedBytes,
            capMB: $capMB,
            clearing: clearing,
            confirmingClear: $confirmingClear,
            onClear: {
                Task {
                    clearing = true
                    defer { clearing = false }
                    try? await app.client.cache?.clear()
                    usedBytes = await app.client.cache?.totalBytes() ?? 0
                }
            }
        )
        .task { usedBytes = await app.client.cache?.totalBytes() ?? 0 }
        .onChange(of: capMB) { _, mb in
            let bytes = mb * 1024 * 1024
            CachePreferences.capBytes = bytes
            // Lowering the cap reclaims disk now, not at the next write.
            Task {
                try? await app.client.cache?.evictIfOverCap(bytes)
                usedBytes = await app.client.cache?.totalBytes() ?? 0
            }
        }
    }
}

struct SettingsGeneralScreen: View {
    let warnTokens: Int32
    let warnError: String?
    let onSetWarn: (Int32) -> Void
    let usedBytes: Int
    @Binding var capMB: Int
    let clearing: Bool
    @Binding var confirmingClear: Bool
    let onClear: () -> Void

    @State private var editingCustom = false
    @State private var customText = ""

    static let presets: [Int32] = [50_000, 75_000, 100_000, 150_000, 200_000]
    private let minMB = CachePreferences.minCapBytes / (1024 * 1024)
    private let maxMB = CachePreferences.maxCapBytes / (1024 * 1024)

    var body: some View {
        IKSettingsPage(title: "General") {
            IKSHead("Context warning", note: "All devices", first: true)
            IKGroup {
                warnMenu
                if editingCustom { customRow }
            }
            if let warnError { IKSError(text: warnError) }
            IKSFooter("Past this size, a conversation’s context shows beside the model under the message field; tap it to compress. Near a model’s own limit it shows in red whatever this is set to.")

            IKSHead("On-device cache", note: "This iPhone")
            IKGroup {
                IKSValueRow(title: "Used", value: SettingsFormat.bytes(usedBytes), mono: true)
                IKSRow {
                    Text("Cap").frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(capMB) MB").font(.system(size: 13, design: .monospaced)).foregroundStyle(IK.secondary)
                    IKSStepper(lowerLabel: "Lower cap by 25 MB", raiseLabel: "Raise cap by 25 MB",
                               canLower: capMB - 25 >= minMB, canRaise: capMB + 25 <= maxMB,
                               lower: { capMB = max(minMB, capMB - 25) },
                               raise: { capMB = min(maxMB, capMB + 25) })
                }
                if confirmingClear {
                    IKSInsetConfirm(
                        question: "Clear \(SettingsFormat.bytes(usedBytes)) from this iPhone?",
                        detail: "Conversations reload from the server the next time you open them. Nothing on the server changes.",
                        confirmLabel: "Clear",
                        onCancel: { confirmingClear = false },
                        onConfirm: { confirmingClear = false; onClear() }
                    )
                } else {
                    Button { confirmingClear = true } label: {
                        IKSRow {
                            Text(clearing ? "Clearing…" : "Clear cache").foregroundStyle(IK.red)
                            Spacer(minLength: 0)
                            if clearing { ProgressView().controlSize(.small) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(clearing)
                }
            }
            IKSFooter("Keeps recent conversations here so they stay readable when the server is unreachable. Lowering the cap trims it now.")
        }
    }

    private var warnMenu: some View {
        Menu {
            Picker("Warn at", selection: Binding(get: { warnTokens }, set: { onSetWarn($0) })) {
                Text("Off").tag(Int32(0))
                ForEach(Self.presets, id: \.self) { Text("\(ContextWarning.compact($0)) tokens").tag($0) }
                if warnTokens > 0, !Self.presets.contains(warnTokens) {
                    Text("\(ContextWarning.compact(warnTokens)) tokens").tag(warnTokens)
                }
            }
            Button("Custom…") {
                customText = warnTokens > 0 ? String(warnTokens / 1_000) : ""
                editingCustom = true
            }
        } label: {
            IKSRow {
                Text("Warn at").foregroundStyle(IK.text).frame(maxWidth: .infinity, alignment: .leading)
                Text(warnTokens == 0 ? "Off" : "\(ContextWarning.compact(warnTokens)) tokens")
                    .font(.system(size: 15)).foregroundStyle(IK.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(IK.chevron)
            }
        }
        .buttonStyle(.plain)
    }

    /// Custom size, edited in place: thousands of tokens, 1 to 2,000.
    private var customRow: some View {
        IKSRow {
            TextField("Thousands of tokens", text: $customText)
                .keyboardType(.numberPad)
                .font(.system(size: 15, design: .monospaced))
                .accessibilityLabel("Warn at, in thousands of tokens")
            Button("Cancel") { editingCustom = false }.ikButton()
            Button("Save") {
                if let k = Int32(customText.trimmingCharacters(in: .whitespaces)), k > 0, k <= 2_000 {
                    onSetWarn(k * 1_000)
                }
                editingCustom = false
            }
            .ikButton(.primary)
        }
    }
}
