import SwiftUI
import PsmithKit
import UniformTypeIdentifiers

/// Mac settings panel for device tools: the Obsidian vault bookmark
/// (the one tool that needs configuration) and the recent-first audit
/// of every device-tool call the server logged for this user.
/// Calendar and Reminders need no setup — macOS prompts for access on
/// the first call the model makes.
struct DeviceToolsSettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var isBookmarked: Bool = ObsidianVaultBookmark.isSet
    @State private var bookmarkedDisplayPath: String? = DeviceToolsSettingsView.displayPath()
    @State private var pickingFolder = false
    @State private var pickerError: String?

    @State private var calls: [PsmithDeviceToolCall] = []
    @State private var loadingCalls = false
    @State private var callsError: String?
    @State private var atEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device tools")
                        .scaledFont(.title2, weight: .semibold)
                    Text("Tools the model runs on this Mac: Calendar, Reminders, and Obsidian notes. macOS asks for Calendar/Reminders access the first time the model uses them; Obsidian needs a folder picked below.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                obsidianSection
                activitySection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            if calls.isEmpty { await reloadCalls() }
        }
        .fileImporter(
            isPresented: $pickingFolder,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else { return }
            handlePicked(url: url)
        }
    }

    // MARK: - Obsidian

    private var obsidianSection: some View {
        sectionCard("Obsidian") {
            VStack(alignment: .leading, spacing: 12) {
                if isBookmarked {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Folder saved")
                                .scaledFont(.callout, weight: .medium)
                            if let bookmarkedDisplayPath {
                                Text(bookmarkedDisplayPath)
                                    .scaledFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Label("No folder selected", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        pickerError = nil
                        pickingFolder = true
                    } label: {
                        Label(isBookmarked ? "Change folder…" : "Pick folder…",
                              systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.glass)
                    if isBookmarked {
                        Button(role: .destructive) {
                            ObsidianVaultBookmark.clear()
                            ObsidianTools.syncRegistration()
                            refreshBookmark()
                            Task { await app.deviceTools.registerWithServer() }
                        } label: {
                            Label("Forget folder", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
                if let pickerError {
                    Text(pickerError)
                        .scaledFont(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Text("Pick your Obsidian vault (or a subfolder). Psmith stores a bookmark so the model can read and write notes inside it — no Obsidian plugin required.")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func handlePicked(url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        do {
            try ObsidianVaultBookmark.save(folderURL: url)
            ObsidianTools.syncRegistration()
            refreshBookmark()
            // Re-register so the server knows obsidian_* tools are now
            // fulfillable. Best-effort; the next bootstrap re-syncs.
            Task { await app.deviceTools.registerWithServer() }
        } catch {
            pickerError = "Couldn't save bookmark: \(String(describing: error))"
        }
    }

    private func refreshBookmark() {
        isBookmarked = ObsidianVaultBookmark.isSet
        bookmarkedDisplayPath = Self.displayPath()
    }

    static func displayPath() -> String? {
        guard let url = ObsidianVaultBookmark.resolve() else { return nil }
        return url.lastPathComponent
    }

    // MARK: - Activity

    private var activitySection: some View {
        sectionCard("Recent activity") {
            VStack(alignment: .leading, spacing: 0) {
                if let callsError {
                    Text(callsError)
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                        .padding(.bottom, 8)
                }
                if calls.isEmpty && !loadingCalls {
                    Text("No device-tool activity yet. Calls the model makes through your devices will show up here.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calls) { call in
                        DeviceToolCallRowMac(call: call)
                            .onAppear {
                                if call.id == calls.last?.id && !atEnd {
                                    Task { await loadMoreCalls() }
                                }
                            }
                        if call.id != calls.last?.id {
                            Divider()
                        }
                    }
                    if loadingCalls {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func reloadCalls() async {
        loadingCalls = true
        defer { loadingCalls = false }
        callsError = nil
        do {
            let fresh = try await app.client.deviceTools.listCalls()
            calls = fresh
            atEnd = fresh.count < 50
        } catch {
            callsError = "Couldn't load activity: \(PsmithError.display(error))"
        }
    }

    private func loadMoreCalls() async {
        guard !loadingCalls, let cursor = calls.last?.invokedAt else { return }
        loadingCalls = true
        defer { loadingCalls = false }
        do {
            let page = try await app.client.deviceTools.listCalls(before: cursor)
            let known = Set(calls.map { $0.id })
            calls.append(contentsOf: page.filter { !known.contains($0.id) })
            atEnd = page.count < 50
        } catch {
            callsError = "Couldn't load more: \(PsmithError.display(error))"
        }
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

/// One audit row: tool name + status dot + relative time; click
/// expands to the raw input/output JSON that crossed the wire.
private struct DeviceToolCallRowMac: View {
    let call: PsmithDeviceToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(call.toolName)
                    .scaledFont(.callout, weight: .medium)
                    .monospaced()
                Spacer()
                Text(relativeWhen)
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.tertiary)
                    .scaledFont(.caption)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                if !call.errorMessage.isEmpty {
                    Text(call.errorMessage)
                        .scaledFont(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                jsonBlock("Input", call.inputJSON)
                jsonBlock("Output", call.outputJSON)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func jsonBlock(_ title: String, _ raw: Data) -> some View {
        if !raw.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.caption2, weight: .semibold)
                    .foregroundStyle(.tertiary)
                Text(prettyJSON(raw))
                    .scaledFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func prettyJSON(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8)
        else { return String(data: data, encoding: .utf8) ?? "" }
        return s
    }

    private var statusColor: Color {
        switch call.status {
        case "ok": return .green
        case "error": return .red
        default: return .orange
        }
    }

    private var relativeWhen: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: call.invokedAt, relativeTo: Date())
    }
}
