import SwiftUI
import UniformTypeIdentifiers
import PsmithKit
import PsmithUI

/// Settings › Files and Device Tools (board SettingsFiles): the notes
/// folder the files_* tools read and write, and the log of every tool the
/// model ran on this iPhone. Saving or forgetting the folder re-registers
/// capabilities so the server offers files_* tools (or stops) on the next
/// turn.
struct SettingsFiles: View {
    @Environment(AppModel.self) private var app
    @State private var isBookmarked = FilesFolderBookmark.isSet
    @State private var displayPath = SettingsFiles.displayPath()
    @State private var picking = false
    @State private var pickerError: String?
    @State private var confirmingForget = false
    @State private var calls: [DeviceToolActivity] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var atEnd = false
    @State private var cursor: Date?

    var body: some View {
        SettingsFilesScreen(
            isBookmarked: isBookmarked,
            displayPath: displayPath,
            pickerError: pickerError,
            confirmingForget: $confirmingForget,
            calls: calls,
            loading: loading,
            loadError: loadError,
            atEnd: atEnd,
            onPick: { pickerError = nil; picking = true },
            onForget: forget,
            onRetry: { Task { calls.isEmpty ? await reload() : await loadMore() } },
            onReachEnd: { Task { await loadMore() } }
        )
        .refreshable { await reload() }
        .task { if calls.isEmpty { await reload() } }
        // The system folder picker is the only way to grant a security-scoped folder.
        .sheet(isPresented: $picking) {
            DocumentFolderPicker(
                onPick: { url in picking = false; handlePicked(url) },
                onCancel: { picking = false }
            )
            .ignoresSafeArea()
        }
    }

    /// The folder's own name, as Files shows it ("My Vault").
    static func displayPath() -> String? {
        FilesFolderBookmark.resolve()?.lastPathComponent
    }

    private func refresh() {
        isBookmarked = FilesFolderBookmark.isSet
        displayPath = Self.displayPath()
    }

    private func forget() {
        FilesFolderBookmark.clear()
        FilesTools.syncRegistration()
        refresh()
        Task { await app.deviceTools.registerWithServer() }
    }

    private func handlePicked(_ url: URL) {
        // The picker's URL needs scoped access to bookmark; the bookmark
        // then carries the grant on its own.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        do {
            try FilesFolderBookmark.save(folderURL: url)
            FilesTools.syncRegistration()
            refresh()
            // Best effort: a failed registration leaves the bookmark; the next bootstrap retries.
            Task { await app.deviceTools.registerWithServer() }
        } catch {
            pickerError = "Couldn’t save the folder: \(error.localizedDescription)"
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        loadError = nil
        do {
            let fresh = try await app.client.deviceTools.listCalls()
            calls = fresh.map(DeviceToolActivity.init)
            cursor = fresh.last?.invokedAt
            atEnd = fresh.count < 50
        } catch {
            loadError = "Couldn’t load activity: \(PsmithError.display(error))"
        }
    }

    private func loadMore() async {
        guard !loading, !atEnd, let cursor else { return }
        loading = true
        defer { loading = false }
        loadError = nil
        do {
            let page = try await app.client.deviceTools.listCalls(before: cursor)
            // invokedAt is the cursor, so a sub-second tie can repeat a row.
            let known = Set(calls.map(\.id))
            calls.append(contentsOf: page.filter { !known.contains($0.id) }.map(DeviceToolActivity.init))
            self.cursor = page.last?.invokedAt ?? cursor
            atEnd = page.count < 50
        } catch {
            loadError = "Couldn’t load more: \(PsmithError.display(error))"
        }
    }
}

/// One logged device-tool call, as the activity list shows it.
struct DeviceToolActivity: Identifiable, Hashable {
    let id: String
    let toolName: String
    let status: String
    let errorMessage: String
    let input: Data
    let output: Data
    let invokedAt: Date
    let completedAt: Date

    init(id: String, toolName: String, status: String, errorMessage: String = "", input: Data, output: Data = Data(),
         invokedAt: Date, completedAt: Date) {
        self.id = id
        self.toolName = toolName
        self.status = status
        self.errorMessage = errorMessage
        self.input = input
        self.output = output
        self.invokedAt = invokedAt
        self.completedAt = completedAt
    }

    init(_ c: PsmithDeviceToolCall) {
        self.init(id: c.id, toolName: c.toolName, status: c.status, errorMessage: c.errorMessage,
                  input: c.inputJSON, output: c.outputJSON, invokedAt: c.invokedAt, completedAt: c.completedAt)
    }

    var duration: String {
        let s = completedAt.timeIntervalSince(invokedAt)
        return s < 1 ? "\(Int((s * 1000).rounded())) ms" : String(format: "%.1f s", s)
    }
}

struct SettingsFilesScreen: View {
    let isBookmarked: Bool
    let displayPath: String?
    let pickerError: String?
    @Binding var confirmingForget: Bool
    let calls: [DeviceToolActivity]
    let loading: Bool
    let loadError: String?
    let atEnd: Bool
    let onPick: () -> Void
    let onForget: () -> Void
    let onRetry: () -> Void
    let onReachEnd: () -> Void
    var now: Date = .now
    var initiallyExpanded: Set<String> = []
    @State private var expanded: Set<String> = []

    var body: some View {
        IKSettingsPage(title: "Files and Device Tools") {
            IKSFooter("Tools the model runs on this iPhone: Calendar, Reminders, and a folder of notes. iOS asks for Calendar and Reminders access the first time the model uses one.", top: 0)

            IKSHead("Folder")
            IKGroup {
                if isBookmarked {
                    IKSRow(vertical: 10) {
                        Image(systemName: "checkmark.circle").font(.system(size: 19)).foregroundStyle(IK.green)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Folder saved").fontWeight(.semibold)
                            if let displayPath {
                                Text(displayPath).font(.system(size: 12, design: .monospaced)).foregroundStyle(IK.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    IKSRow {
                        Image(systemName: "folder.badge.questionmark").foregroundStyle(IK.secondary)
                        Text("No folder selected").foregroundStyle(IK.secondary)
                    }
                }
                IKSActionRow(title: isBookmarked ? "Change folder" : "Pick folder", action: onPick)
                if isBookmarked && !confirmingForget {
                    IKSActionRow(title: "Forget folder", color: IK.red) { confirmingForget = true }
                }
            }
            if isBookmarked && confirmingForget {
                IKConfirmCard(question: "Forget this folder?",
                              detail: "The files stay where they are. The model loses access until you pick the folder again.",
                              confirmLabel: "Forget folder",
                              onCancel: { confirmingForget = false },
                              onConfirm: { confirmingForget = false; onForget() })
                    .padding(.top, 8)
            }
            if let pickerError { IKSError(text: pickerError) }
            IKSFooter(isBookmarked
                      ? "Removes the bookmark from this device. The model will report “folder not configured” until you pick a folder again."
                      : "Any notes folder works. An Obsidian vault, or a folder inside one, stays plain markdown with its frontmatter kept. Psmith keeps a bookmark so it can read and write there without asking again.")

            IKSHead("Recent activity")
            IKGroup {
                if calls.isEmpty && loading {
                    IKSRow { ProgressView().frame(maxWidth: .infinity) }
                } else if calls.isEmpty && loadError == nil {
                    IKSRow(vertical: 10) {
                        IKSTitleNote(title: "No device tool activity yet",
                                     note: "Calendar, Reminders and files tools the model runs here show up in this list.")
                    }
                }
                ForEach(calls) { call in
                    activityRow(call).onAppear { if call.id == calls.last?.id && !atEnd { onReachEnd() } }
                }
                .onAppear { expanded.formUnion(initiallyExpanded) }
                if let loadError {
                    IKSRow {
                        Text(loadError).font(.system(size: 13)).foregroundStyle(IK.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry", action: onRetry).ikButton()
                    }
                } else if !calls.isEmpty && !atEnd && loading {
                    IKSRow { ProgressView().frame(maxWidth: .infinity) }
                }
            }
        }
    }

    private func activityRow(_ call: DeviceToolActivity) -> some View {
        let open = expanded.contains(call.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { expanded.remove(call.id) } else { expanded.insert(call.id) }
            } label: {
                HStack(spacing: 10) {
                    IKDot(color: statusColor(call.status), size: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(call.toolName).font(.system(size: 13.5, weight: .medium, design: .monospaced)).foregroundStyle(IK.text)
                        Text("\(SettingsFormat.relative(call.invokedAt, now: now)) · \(call.duration)").font(.system(size: 12.5)).foregroundStyle(IK.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    IKChevron(down: open)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(call.toolName), \(call.status)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    if !call.errorMessage.isEmpty {
                        Text(call.errorMessage)
                            .font(.system(size: 13)).lineSpacing(2.5)
                            .foregroundStyle(IK.red)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 8.25)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(IK.red.opacity(0.10)))
                            .padding(.bottom, 8)
                    }
                    payload("Input", call.input)
                    if !call.output.isEmpty { payload("Output", call.output).padding(.top, 8) }
                }
                .padding(.leading, 18)
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 14)
    }

    private func payload(_ title: String, _ data: Data) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(IK.tertiary)
            Text(pretty(data))
                .font(.system(size: 12.5, design: .monospaced)).lineSpacing(2)
                .foregroundStyle(IK.strong)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 8.25)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(IKS.field))
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "ok": IK.green
        case "error": IK.red
        case "timeout": IK.orange
        default: IK.tertiary
        }
    }

    private func pretty(_ data: Data) -> String {
        if data.isEmpty { return "(empty)" }
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: out, encoding: .utf8) { return s.replacingOccurrences(of: "\" : ", with: "\": ") }
        return String(data: data, encoding: .utf8) ?? "(binary)"
    }
}

/// UIDocumentPicker in folder mode.
private struct DocumentFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }
        func documentPickerWasCancelled(_: UIDocumentPickerViewController) { onCancel() }
    }
}
