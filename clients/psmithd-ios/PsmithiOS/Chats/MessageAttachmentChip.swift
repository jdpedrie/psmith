import SwiftUI
import PsmithKit

/// A file a message carries (PDF, audio, video): icon, name, size.
/// Tap downloads it and pushes Quick Look (Attachments).
struct MessageAttachmentChip: View {
    let attachment: PsmithMessageAttachment
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
                        .font(.system(size: 20))
                        .foregroundStyle(IK.secondary)
                        .opacity(loading ? 0 : 1)
                    if loading { IKSpinner() }
                }
                .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: 13))
                        .foregroundStyle(IK.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(metaLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(failed ? IK.red : IK.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 240, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(IK.wash(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(IK.ring(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayName), \(metaLine). Tap to preview.")
        .navigationDestination(isPresented: $showingPreview) {
            if let localURL {
                MessageAttachmentPreview(url: localURL)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(displayName)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

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
                .appendingPathComponent("psmith-attachments", isDirectory: true)
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
            return "doc.text"
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
        if failed { return "Couldn't load. Tap to retry." }
        return formattedSize(attachment.sizeBytes)
    }

    private func formattedSize(_ bytes: Int64) -> String { UsageFormat.bytes(Int(bytes)) }

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
