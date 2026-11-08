import SwiftUI
import PsmithKit
import UniformTypeIdentifiers

/// A sent image: a 140pt thumbnail. Clicking opens it as a page in the
/// reading column (board AppImage).
struct MessageAttachmentImageMac: View {
    let attachment: PsmithMessageAttachment
    var messageID: String = ""
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    @State private var url: URL?
    @State private var failed = false

    private let side: CGFloat = 140

    var body: some View {
        Group {
            if failed {
                placeholder(systemImage: "exclamationmark.triangle")
            } else if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.15))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder(systemImage: "exclamationmark.triangle")
                    default:
                        placeholder(systemImage: "photo")
                    }
                }
            } else {
                placeholder(systemImage: "photo")
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            guard url != nil, !failed else { return }
            navigator.page = .image(messageID: messageID, fileID: attachment.fileID, filename: attachment.originalFilename ?? "Image")
        }
        .task(id: attachment.fileID) {
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
            Color.white.opacity(0.05)
            Image(systemName: systemImage).font(.system(size: 18, weight: .light)).foregroundStyle(SK.tertiary)
        }
    }
}

/// A file on a sent message: icon, name, size.
struct MessageAttachmentChipMac: View {
    let attachment: PsmithMessageAttachment

    var body: some View {
        AttachmentFileChip(
            name: attachment.originalFilename ?? defaultName,
            detail: ByteCountFormatter.string(fromByteCount: attachment.sizeBytes, countStyle: .file),
            systemImage: iconName
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
}

/// The file chip the transcript and the composer share.
struct AttachmentFileChip: View {
    let name: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 14)).foregroundStyle(SK.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).sk(12).lineLimit(1).truncationMode(.middle).frame(height: 15)
                Text(detail).sk(11, SK.tertiary).lineLimit(1).frame(height: 13.75)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// An image as a page in the reading column: black ground, fitted,
/// double-click to zoom. Escape and the breadcrumb go back.
struct ImagePage: View {
    let fileID: String
    let filename: String
    let back: () -> Void
    let backTitle: String
    @Environment(AppModel.self) private var app
    @State private var url: URL?
    @State private var failed = false
    @State private var zoomed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SKBreadcrumb(parts: [(backTitle, back)], current: filename).padding(.bottom, -10)
                Spacer(minLength: 0)
                Text("Double-click to zoom · Escape to go back").sk(11.5, SK.tertiary)
            }
            .padding(.bottom, 12)
            ZStack {
                Color.black
                if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(SK.orange)
                        Text("Couldn’t load the image").sk(13, .white.opacity(0.8))
                    }
                } else if let url {
                    ScrollView([.horizontal, .vertical]) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fit)
                                    .scaleEffect(zoomed ? 2 : 1)
                                    .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.18)) { zoomed.toggle() } }
                            case .failure:
                                Text("Couldn’t load the image").sk(13, .white.opacity(0.8))
                            default:
                                MKSpinner(size: 20, color: .white)
                            }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else {
                    MKSpinner(size: 20, color: .white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .task(id: fileID) {
            do { url = try await app.client.files.signedURL(fileID: fileID) } catch { failed = true }
        }
    }
}
