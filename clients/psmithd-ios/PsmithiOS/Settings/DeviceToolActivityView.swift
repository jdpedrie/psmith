import SwiftUI
import PsmithKit

/// Settings → Device tool activity. Recent-first scroll of every
/// device-tool call the server has logged for this user. Each row
/// shows tool name, status + colour, when it ran, and the conversation
/// it fired in; tapping expands to the raw input + output JSON the
/// model and client exchanged, so the user can see exactly what
/// crossed the wire.
///
/// Paginated by `invokedAt` cursor. The next page loads when the
/// last visible row appears.
struct DeviceToolActivityView: View {
    @Environment(AppModel.self) private var app

    @State private var calls: [PsmithDeviceToolCall] = []
    @State private var loading: Bool = false
    @State private var loadError: String?
    @State private var atEnd: Bool = false

    var body: some View {
        Group {
            if calls.isEmpty && loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if calls.isEmpty {
                ContentUnavailableView(
                    "No device-tool activity yet",
                    systemImage: "tray",
                    description: Text("Calendar, Reminders, and Obsidian tools the model invokes through your device will show up here.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Device tool activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task {
            if calls.isEmpty {
                await reload()
            }
        }
        .overlay(alignment: .bottom) {
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            ForEach(calls) { call in
                CallRow(call: call)
                    .onAppear {
                        if call.id == calls.last?.id && !atEnd {
                            Task { await loadMore() }
                        }
                    }
            }
            if !atEnd && !calls.isEmpty {
                HStack {
                    Spacer()
                    if loading { ProgressView() }
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        loadError = nil
        do {
            let fresh = try await app.client.deviceTools.listCalls()
            calls = fresh
            atEnd = fresh.count < 50
        } catch {
            loadError = "Couldn't load activity: \(String(describing: error))"
        }
    }

    private func loadMore() async {
        guard !loading, let cursor = calls.last?.invokedAt else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await app.client.deviceTools.listCalls(before: cursor)
            // Dedupe in case the cursor matches an existing
            // entry's invokedAt (unlikely but possible at
            // sub-second resolution).
            let known = Set(calls.map { $0.id })
            let fresh = page.filter { !known.contains($0.id) }
            calls.append(contentsOf: fresh)
            atEnd = page.count < 50
        } catch {
            loadError = "Couldn't load more: \(String(describing: error))"
        }
    }
}

/// One audit row. Collapsed view shows tool name + status badge +
/// relative timestamp. Expanded shows the input + output JSON
/// pretty-printed in a monospaced block, plus an error string when
/// status != ok.
private struct CallRow: View {
    let call: PsmithDeviceToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.toolName)
                        .font(.callout.weight(.medium))
                        .monospaced()
                    Text(relativeWhen)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                if !call.errorMessage.isEmpty {
                    Text(call.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
                payloadSection("Input", data: call.inputJSON)
                if !call.outputJSON.isEmpty {
                    payloadSection("Output", data: call.outputJSON)
                }
                HStack(spacing: 6) {
                    Text("Duration:")
                        .foregroundStyle(.secondary)
                    Text(durationString)
                        .monospacedDigit()
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func payloadSection(_ title: String, data: Data) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(pretty(data))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func pretty(_ data: Data) -> String {
        if data.isEmpty { return "(empty)" }
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: pretty, encoding: .utf8) {
            return s
        }
        return String(data: data, encoding: .utf8) ?? "(binary)"
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color, system): (String, Color, String) = {
            switch call.status {
            case "ok":      return ("OK", .green, "checkmark.circle.fill")
            case "error":   return ("ERROR", .red, "exclamationmark.triangle.fill")
            case "timeout": return ("TIMEOUT", .orange, "clock.badge.exclamationmark")
            default:        return (call.status.uppercased(), .secondary, "questionmark.circle")
            }
        }()
        Image(systemName: system)
            .foregroundStyle(color)
            .help(label)
            .font(.title3)
    }

    private var relativeWhen: String {
        call.invokedAt.formatted(.relative(presentation: .numeric))
    }

    private var durationString: String {
        let secs = call.completedAt.timeIntervalSince(call.invokedAt)
        if secs < 1 {
            return "\(Int(secs * 1000))ms"
        }
        return String(format: "%.2fs", secs)
    }
}
