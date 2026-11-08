import SwiftUI
import PsmithKit

/// A message's images and files above its bubble (Attachments). Images
/// are 140pt tiles that push the image viewer; files are chips.
struct MessageAttachments: View {
    let message: PsmithMessage

    var body: some View {
        let images = message.attachments.filter { $0.kind == "image" }
        let files = message.attachments.filter { $0.kind != "image" }
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(images) { MessageAttachmentImage(messageID: message.id, attachment: $0) }
                    }
                }
                .defaultScrollAnchor(.trailing)
                .fixedSize(horizontal: images.count <= 2, vertical: false)
            }
            ForEach(files) { MessageAttachmentChip(attachment: $0) }
        }
    }
}

/// One image tile. Loads a signed URL for the thumbnail; tap opens the
/// image viewer page.
struct MessageAttachmentImage: View {
    let messageID: String
    let attachment: PsmithMessageAttachment
    @Environment(AppModel.self) private var app
    @Environment(\.openConversationPage) private var open
    @State private var url: URL?
    @State private var failed = false

    private let side: CGFloat = 140
    private var filename: String { attachment.originalFilename ?? "Image" }

    var body: some View {
        Button {
            open(.image(messageID: messageID, fileID: attachment.fileID, filename: filename))
        } label: {
            Group {
                if let url, !failed {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.15))) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            placeholder(failed: phase.error != nil)
                        }
                    }
                } else {
                    placeholder(failed: failed)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(IK.ring(0.1), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open image \(filename)")
        .task(id: attachment.fileID) {
            if url != nil { return }
            do { url = try await app.client.files.signedURL(fileID: attachment.fileID) } catch { failed = true }
        }
    }

    private func placeholder(failed: Bool) -> some View {
        ZStack {
            LinearGradient(colors: [IK.wash(0.10), IK.wash(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: "photo").font(.system(size: 26))
                Text(filename).font(.system(size: 11.5)).multilineTextAlignment(.center).lineLimit(2)
            }
            .foregroundStyle(IK.secondary)
            .padding(.horizontal, 10)
        }
    }
}
