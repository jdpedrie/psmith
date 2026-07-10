import SwiftUI
import PsmithKit
import UniformTypeIdentifiers

/// Mac rendering for message attachments. Mirrors the iOS trio
/// (thumbnail / chip / lightbox) with Mac presentation: the lightbox
/// is a sheet (macOS has no fullScreenCover) and dismissal is the
/// close button or Escape rather than drag-down.

/// One image attachment on a historical message. Mints a signed URL
/// via FilesRepository on first appear; AsyncImage handles fetch +
/// URLSession disk cache below us.
struct MessageAttachmentImageMac: View {
    let attachment: PsmithMessageAttachment
    @Environment(AppModel.self) private var app

    @State private var url: URL?
    @State private var failed = false
    @State private var showingLightbox = false

    /// Square thumbnail — matches the composer's pending-chip size so
    /// a sent message visually echoes the chip it replaces.
    private let side: CGFloat = 140

    var body: some View {
        Group {
            if failed {
                placeholder(systemImage: "exclamationmark.triangle")
            } else if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.15))) { phase in
                    switch phase {
                    case .empty:
                        placeholder(systemImage: "photo")
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder(systemImage: "exclamationmark.triangle")
                    @unknown default:
                        placeholder(systemImage: "photo")
                    }
                }
            } else {
                placeholder(systemImage: "photo")
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard url != nil, !failed else { return }
            showingLightbox = true
        }
        .sheet(isPresented: $showingLightbox) {
            if let url {
                MessageAttachmentLightboxMac(url: url, filename: attachment.originalFilename)
            }
        }
        .task(id: attachment.fileID) {
            // Signed URLs are short-lived; task(id:) mints once per
            // attachment. If the URL expires while visible, AsyncImage
            // shows the warning glyph and a scroll-out/in re-mints.
            if url != nil { return }
            do {
                url = try await app.client.files.signedURL(fileID: attachment.fileID)
            } catch {
                failed = true
            }
        }
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Color.primary.opacity(0.05)
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Non-image attachment (PDF / audio / video): icon + filename + size.
/// Informational — the model saw the bytes; the chip records what rode
/// along with the message.
struct MessageAttachmentChipMac: View {
    let attachment: PsmithMessageAttachment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.originalFilename ?? defaultName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .frame(maxWidth: 240, alignment: .leading)
    }

    private var iconName: String {
        switch attachment.kind {
        case "document": return "doc.richtext"
        case "audio":    return "waveform"
        case "video":    return "film"
        default:          return "doc"
        }
    }

    private var defaultName: String {
        switch attachment.kind {
        case "document": return "Document"
        case "audio":    return "Audio"
        case "video":    return "Video"
        default:          return "File"
        }
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: attachment.sizeBytes, countStyle: .file)
    }
}

/// Sheet-presented image viewer. Double-click toggles 2× zoom;
/// Escape / the close button dismisses.
struct MessageAttachmentLightboxMac: View {
    let url: URL
    var filename: String?
    @Environment(\.dismiss) private var dismiss
    @State private var zoomed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            ScrollView([.horizontal, .vertical]) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: zoomed ? .infinity : 760, maxHeight: zoomed ? .infinity : 560)
                            .scaleEffect(zoomed ? 2 : 1, anchor: .center)
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut(duration: 0.18)) { zoomed.toggle() }
                            }
                    case .failure:
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.orange)
                            Text("Couldn't load image")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(60)
                    case .empty:
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                            .padding(120)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .font(.title)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
            .help("Close")
        }
        .frame(minWidth: 480, idealWidth: 800, minHeight: 360, idealHeight: 600)
    }
}
