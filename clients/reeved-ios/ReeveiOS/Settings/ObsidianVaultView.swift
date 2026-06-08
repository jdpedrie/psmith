import SwiftUI
import UniformTypeIdentifiers
import ReeveKit

/// Settings → Obsidian. Surfaces the saved vault bookmark (if any),
/// lets the user (re-)pick a vault folder via UIDocumentPicker, and
/// forgets it on demand. After save, re-runs the
/// RegisterCapabilities call so the server starts surfacing
/// obsidian_* tools on the next model turn.
struct ObsidianVaultView: View {
    @Environment(AppModel.self) private var app

    /// Tracks the on-disk bookmark state. Refreshed whenever the
    /// picker dismisses (success or cancel) so the row reflects
    /// reality without polling.
    @State private var isBookmarked: Bool = ObsidianVaultBookmark.isSet
    @State private var bookmarkedDisplayPath: String? = displayPath()
    @State private var pickingFolder: Bool = false
    @State private var pickerError: String?

    var body: some View {
        Form {
            Section {
                if isBookmarked {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Folder saved")
                                .font(.callout.weight(.medium))
                            if let bookmarkedDisplayPath {
                                Text(bookmarkedDisplayPath)
                                    .font(.caption2)
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

                Button {
                    pickerError = nil
                    pickingFolder = true
                } label: {
                    Label(isBookmarked ? "Change folder" : "Pick folder",
                          systemImage: "folder.badge.plus")
                }
            } header: {
                Text("Folder")
            } footer: {
                Text("Pick the folder you want Reeve to access — your entire Obsidian vault, or a subfolder of it (e.g. \"Vault/Reeve/\"). Reeve stores a security-scoped bookmark so it can read and write notes inside that folder without re-prompting. No Obsidian plugin or local-REST setup required.")
            }

            if isBookmarked {
                Section {
                    Button(role: .destructive) {
                        ObsidianVaultBookmark.clear()
                        ObsidianTools.syncRegistration()
                        refresh()
                        Task { await app.deviceTools.registerWithServer() }
                    } label: {
                        Label("Forget folder", systemImage: "trash")
                    }
                } footer: {
                    Text("Removes the bookmark from this device. The model will report \"vault not configured\" until you pick a folder again.")
                }
            }

            if let pickerError {
                Section {
                    Text(pickerError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Obsidian")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pickingFolder) {
            DocumentFolderPicker(
                onPick: { url in
                    pickingFolder = false
                    handlePicked(url: url)
                },
                onCancel: { pickingFolder = false }
            )
            .ignoresSafeArea()
        }
    }

    private func handlePicked(url: URL) {
        // UIDocumentPicker hands back a URL that needs security-
        // scoped access to be opened. We start the access, save the
        // bookmark, stop the access. The bookmark itself encodes
        // the permission, so subsequent resolves re-grant it.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        do {
            try ObsidianVaultBookmark.save(folderURL: url)
            ObsidianTools.syncRegistration()
            refresh()
            // Re-register so the server knows obsidian_* tools are
            // now fulfillable. Best-effort: a registration failure
            // doesn't unset the bookmark; the next bootstrap will
            // pick it up.
            Task { await app.deviceTools.registerWithServer() }
        } catch {
            pickerError = "Couldn't save bookmark: \(String(describing: error))"
        }
    }

    private func refresh() {
        isBookmarked = ObsidianVaultBookmark.isSet
        bookmarkedDisplayPath = Self.displayPath()
    }

    /// Show the user a recognisable label for their vault folder.
    /// UIDocumentPicker URLs are full filesystem paths inside an
    /// iCloud container or similar — the last path component
    /// ("My Vault") is what they see in Files.
    static func displayPath() -> String? {
        guard let url = ObsidianVaultBookmark.resolve() else { return nil }
        return url.lastPathComponent
    }
}

/// Thin UIViewControllerRepresentable wrapper around
/// UIDocumentPickerViewController in folder-pick mode. Hands the
/// picked URL (or nothing on cancel) back to the parent view.
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

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
        func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
