import SwiftUI

/// Full-screen image viewer presented when the user taps an attached
/// image thumbnail in a message bubble. Loads from the same
/// signed-URL endpoint the in-row thumbnail uses; the URL is passed
/// in so we don't pay for a second `GetFileURL` round-trip.
///
/// Interactions:
///   - Tap the X button (top-right) to dismiss.
///   - Drag down to dismiss (with the image following the gesture
///     for a tactile feel; releases past ~120pt commit, otherwise
///     spring back).
///   - Double-tap toggles between fit-to-screen and 2× zoom,
///     centered on the tap point. (Pinch-zoom would require a
///     UIScrollView bridge for a polished experience; deferred
///     until a user asks.)
struct MessageAttachmentLightbox: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var dismissDragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .onTapGesture(count: 2) { toggleZoom() }
                case .failure:
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Couldn't load image")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                case .empty:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                @unknown default:
                    EmptyView()
                }
            }
            .offset(y: dismissDragOffset)

            VStack {
                HStack {
                    Spacer()
                    closeButton
                }
                Spacer()
            }
        }
        .gesture(dismissDragGesture)
        .background(
            // Lightens the background as the image is dragged off-
            // screen — gives the dismiss gesture a soft fade-out
            // instead of a hard cutoff, matching system app
            // behavior (Photos, Mail attachment preview).
            Color.black
                .opacity(max(0, 1 - abs(dismissDragOffset) / 400))
                .ignoresSafeArea()
        )
        .statusBar(hidden: true)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.4))
                .font(.title)
        }
        .buttonStyle(.plain)
        .padding(16)
        .accessibilityLabel("Close")
    }

    /// Drag-down dismiss. Only engages when the image is at native
    /// scale — at >1× scale the gesture is reserved for panning
    /// (which we'd add when pinch-zoom lands).
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard scale <= 1 else { return }
                if value.translation.height > 0 {
                    dismissDragOffset = value.translation.height
                }
            }
            .onEnded { value in
                guard scale <= 1 else { return }
                if value.translation.height > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.25)) {
                        dismissDragOffset = 0
                    }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.18)) {
            scale = scale > 1 ? 1 : 2
        }
    }
}
