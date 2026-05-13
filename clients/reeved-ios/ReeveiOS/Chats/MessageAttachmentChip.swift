import SwiftUI
import ReeveKit

/// Compact chip for non-image message attachments (PDF / audio /
/// video). Renders a kind-appropriate SF Symbol, the original
/// filename (truncated middle), and a small "PDF · 1.2 MB"-style
/// metadata line. No remote fetch — the user only needs to see
/// what's on the wire, not the bytes.
///
/// Sized to roughly match the height of the image-thumbnail strip
/// (140pt) so a mixed-kinds message lines up visually.
struct MessageAttachmentChip: View {
    let attachment: ReeveMessageAttachment

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
        let kindLabel: String
        switch attachment.kind {
        case "document":
            if attachment.mimeType == "application/pdf" { kindLabel = "PDF" }
            else { kindLabel = "Document" }
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
}
