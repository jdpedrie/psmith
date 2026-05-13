import SwiftUI
import ReeveKit

/// Compact chip for non-image message attachments (PDF / audio /
/// video). Renders a kind-appropriate SF Symbol, the original
/// filename (truncated middle), and a small "PDF · 1.2 MB"-style
/// metadata line. Tap opens the file in Quick Look — handles PDFs,
/// audio, video, and most document types out of the box.
///
/// Sized to roughly match the height of the image-thumbnail strip
/// (140pt) so a mixed-kinds message lines up visually.
struct MessageAttachmentChip: View {
    let attachment: ReeveMessageAttachment
    @Environment(AppModel.self) private var app

    @State private var localURL: URL?
    @State private var loading = false
    @State private var failed = false
    @State private var showingPreview = false

    var body: some View {
        Button {
            Task { await openPreview() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .opacity(loading ? 0 : 1)
                    if loading {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(failed
                            ? AnyShapeStyle(Color.red)
                            : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 220, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayName), \(metaLine). Tap to preview.")
        .fullScreenCover(isPresented: $showingPreview) {
            if let localURL {
                NavigationStack {
                    MessageAttachmentPreview(url: localURL)
                        .ignoresSafeArea()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showingPreview = false }
                            }
                        }
                }
            }
        }
    }

    /// Mint a signed URL, download the bytes to a sandboxed temp
    /// file, and present the Quick Look sheet. Caches the local
    /// file across taps for the lifetime of this view so re-taps
    /// don't re-download.
    @MainActor
    private func openPreview() async {
        if let localURL, FileManager.default.fileExists(atPath: localURL.path) {
            showingPreview = true
            return
        }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let signed = try await app.client.files.signedURL(fileID: attachment.fileID)
            let (data, _) = try await URLSession.shared.data(from: signed)
            // Quick Look infers the type from the file extension —
            // honor the original filename when we have it so PDFs
            // don't get rendered as plain text. Fall back to a
            // mime-derived extension.
            let suggestedName = attachment.originalFilename?.isEmpty == false
                ? attachment.originalFilename!
                : "\(attachment.fileID).\(extensionForMime(attachment.mimeType))"
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("reeve-attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(suggestedName)
            try? FileManager.default.removeItem(at: dest)
            try data.write(to: dest)
            localURL = dest
            showingPreview = true
        } catch {
            failed = true
        }
    }

    private var iconName: String {
        switch attachment.kind {
        case "document":
            return attachment.mimeType == "application/pdf" ? "doc.richtext" : "doc"
        case "audio": return "waveform"
        case "video": return "film"
        default: return "doc"
        }
    }

    private var displayName: String {
        if let name = attachment.originalFilename, !name.isEmpty {
            return name
        }
        switch attachment.kind {
        case "document": return attachment.mimeType == "application/pdf" ? "PDF" : "Document"
        case "audio": return "Audio"
        case "video": return "Video"
        default: return "File"
        }
    }

    private var metaLine: String {
        if failed { return "Couldn't load — tap to retry" }
        let kindLabel: String
        switch attachment.kind {
        case "document":
            kindLabel = attachment.mimeType == "application/pdf" ? "PDF" : "Document"
        case "audio": kindLabel = "Audio"
        case "video": kindLabel = "Video"
        default: kindLabel = attachment.mimeType
        }
        return "\(kindLabel) · \(formattedSize(attachment.sizeBytes))"
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Best-effort file extension for a mime type. Quick Look uses
    /// the extension to pick a renderer, so a bare file_id with no
    /// extension would render as text. Covers the kinds the
    /// composer supports; falls back to "bin" so something is set.
    private func extensionForMime(_ mime: String) -> String {
        switch mime {
        case "application/pdf": return "pdf"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "audio/flac": return "flac"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "video/webm": return "webm"
        default:
            if let slash = mime.lastIndex(of: "/") {
                return String(mime[mime.index(after: slash)...])
            }
            return "bin"
        }
    }
}
