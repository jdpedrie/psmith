import SwiftUI
import UniformTypeIdentifiers
import PsmithKit
import PsmithUI

/// A profile's Share or delete page (board SettingsProfileShare): export it
/// to a file, review an import before anything is created, and delete it,
/// confirmed in place.
struct SettingsProfileShare: View {
    let profileID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var importing = false

    var body: some View {
        let profiles = app.profiles
        if let profile = profiles.profile(id: profileID) {
            SettingsProfileShareScreen(
                profile: profile,
                export: profiles.pendingExport,
                exporting: profiles.isSharing,
                pendingImport: profiles.pendingImport,
                importFilename: ProfileImportFile.name,
                importError: profiles.pendingImport == nil ? nil : profiles.error,
                hasChildren: profiles.hasChildren(profile.id),
                confirmingDelete: $confirmingDelete,
                onExport: { Task { await profiles.exportProfile(id: profile.id) } },
                onPickImport: { importing = true },
                onCancelImport: { profiles.cancelImport() },
                onConfirmImport: { Task { await profiles.confirmImport() } },
                onDelete: {
                    Task {
                        profiles.selectedID = profile.id
                        await profiles.deleteSelected()
                        if profiles.profile(id: profile.id) == nil { dismiss() }
                    }
                }
            )
            .onDisappear { profiles.pendingExport = nil }
            .profileImporter(isPresented: $importing, profiles: profiles)
        } else {
            IKSettingsPage(title: "Share or delete") {
                IKSFooter("This profile is gone.", top: 0)
            }
        }
    }
}

/// The name of the file behind a pending import review, for its heading.
@MainActor
enum ProfileImportFile {
    static var name: String?
}

extension View {
    /// The system file picker for a profile bundle, read and handed to a dry run.
    func profileImporter(isPresented: Binding<Bool>, profiles: ProfilesViewModel) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                // A file from outside the sandbox needs a scoped claim to read.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    ProfileImportFile.name = url.lastPathComponent
                    Task { await profiles.previewImport(payload: data) }
                } catch {
                    profiles.error = "Couldn’t read that file: \(error.localizedDescription)"
                }
            case .failure(let error):
                profiles.error = error.localizedDescription
            }
        }
    }
}

struct SettingsProfileShareScreen: View {
    let profile: PsmithProfile
    let export: PsmithProfileExport?
    let exporting: Bool
    let pendingImport: PsmithImportResult?
    let importFilename: String?
    let importError: String?
    let hasChildren: Bool
    @Binding var confirmingDelete: Bool
    let onExport: () -> Void
    let onPickImport: () -> Void
    let onCancelImport: () -> Void
    let onConfirmImport: () -> Void
    let onDelete: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        IKSettingsPage(title: "Share or delete") {
            IKSHead("Export", first: true)
            IKGroup {
                if let export, let url = Self.write(export) {
                    ShareLink(item: url) {
                        IKSRow(color: theme.accentInk) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 16)).frame(width: 18)
                            Text("Share \(export.suggestedFilename)").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    IKSActionRow(title: exporting ? "Exporting…" : "Export \(profile.name)", systemImage: "square.and.arrow.up",
                                 action: onExport)
                        .disabled(exporting)
                }
                if let notices = export?.notices, !notices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock").font(.system(size: 12))
                            Text("Not included")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IK.secondary)
                        ForEach(notices, id: \.self) { n in
                            Text(n).font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(IK.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            IKSFooter("Anyone with this file can recreate the profile.")

            IKSHead("Import")
            if let pendingImport {
                ProfileImportReviewCard(result: pendingImport, filename: importFilename, error: importError, busy: exporting,
                                        onCancel: onCancelImport, onImport: onConfirmImport)
            } else {
                IKGroup {
                    IKSActionRow(title: "Import from a file", systemImage: "square.and.arrow.down", action: onPickImport)
                }
                IKSFooter("Imports open a review first. Nothing is created until you confirm.")
            }

            IKSHead("Delete")
            if confirmingDelete && !hasChildren {
                IKConfirmCard(question: "Delete \(profile.name)?",
                              detail: "This can’t be undone. Its prompt, models and plugins go with it.",
                              onCancel: { confirmingDelete = false },
                              onConfirm: {
                                  confirmingDelete = false
                                  Haptics.notify(.warning)
                                  onDelete()
                              })
            } else {
                IKGroup {
                    IKSActionRow(title: "Delete \(profile.name)", color: hasChildren ? IK.tertiary : IK.red) { confirmingDelete = true }
                        .disabled(hasChildren)
                }
            }
            IKSFooter("A profile that conversations or child profiles use can’t be deleted.")
        }
    }

    /// ShareLink needs a file to offer a filename; bare bytes share as an unnamed blob.
    static func write(_ export: PsmithProfileExport) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(export.suggestedFilename)
        return (try? export.payload.write(to: url)) != nil ? url : nil
    }
}

/// An import's dry run: what it will be called, what's renamed, and what
/// still needs setting up. Nothing is created until Import.
struct ProfileImportReviewCard: View {
    let result: PsmithImportResult
    let filename: String?
    let error: String?
    let busy: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    private var ordered: [PsmithImportWarning] {
        result.warnings.sorted { rank($0.kind) < rank($1.kind) }
    }

    var body: some View {
        IKGroup {
            VStack(alignment: .leading, spacing: 0) {
                if let filename {
                    Text(filename).font(.system(size: 13, design: .monospaced)).foregroundStyle(IK.text)
                }
                Text("Nothing is created until you confirm.").font(.system(size: 12.5)).foregroundStyle(IK.secondary)
                    .padding(.top, 2)
                ForEach(result.renamed, id: \.self) { name in
                    Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(IK.text).padding(.top, 10)
                }
                if ordered.isEmpty {
                    warning(icon: "checkmark.circle", text: "Everything resolved. Nothing else to set up.", color: IK.secondary)
                }
                ForEach(ordered) { w in
                    warning(icon: icon(w.kind), text: w.message, color: w.kind == .renamed ? IK.secondary : IK.orange)
                }
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(IK.red).padding(.top, 8)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel).ikButton()
                    Button("Import", action: onImport).ikButton(.primary).disabled(busy)
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func warning(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).padding(.top, 2).frame(width: 15)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13.5))
        .lineSpacing(2)
        .foregroundStyle(color)
        .frame(minHeight: 20, alignment: .topLeading)
        .padding(.top, 8)
    }

    private func rank(_ k: PsmithImportWarning.Kind) -> Int {
        switch k {
        case .renamed: 0
        case .providerMissing: 1
        case .mcpServerMissing: 2
        case .pluginUnknown: 3
        case .unspecified: 4
        }
    }

    private func icon(_ k: PsmithImportWarning.Kind) -> String {
        switch k {
        case .providerMissing: "cpu"
        case .mcpServerMissing: "server.rack"
        case .pluginUnknown: "puzzlepiece.extension"
        case .renamed: "textformat"
        case .unspecified: "exclamationmark.triangle"
        }
    }
}
