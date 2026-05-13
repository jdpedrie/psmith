import SwiftUI
import ReeveKit

/// Renders one image attachment on a historical message. Mints a
/// signed URL via `FilesRepository.signedURL` on first appear and
/// caches it for the lifetime of this view. SwiftUI's `AsyncImage`
/// handles the URLSession fetch + cache below us — bytes are also
/// cached by URLSession's default disk cache, so repeated views of
/// the same conversation don't re-download.
struct MessageAttachmentImage: View {
    let attachment: ReeveMessageAttachment
    @Environment(AppModel.self) private var app

    @State private var url: URL?
    @State private var failed = false
    @State private var showingLightbox = false

    /// Square thumbnail size — matches the composer's pending-chip
    /// dimensions so a sent message visually echoes the chip the
    /// user just dismissed by hitting send.
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
            // Only present the lightbox when we actually have a URL
            // — tapping during the loading / failed states would
            // either show a spinner or an error glyph at full
            // screen, neither of which is useful.
            guard url != nil, !failed else { return }
            showingLightbox = true
        }
        .fullScreenCover(isPresented: $showingLightbox) {
            if let url {
                MessageAttachmentLightbox(url: url)
            }
        }
        .task(id: attachment.fileID) {
            // Signed URLs have a 30s TTL. The view re-mints if the
            // user lingers on a long scroll-back page and the URL
            // expires — `task(id:)` fires once per attachment id,
            // and we don't re-fire on URL expiry. Acceptable v1:
            // if the URL expires while visible, AsyncImage will
            // fail and the user sees the warning glyph. The next
            // scroll-out + scroll-in re-mints.
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
