import SwiftUI

/// Tiny capsule toast — slides in from the bottom, holds for a
/// configurable duration, slides out. Designed for quiet success
/// confirmations the user might miss otherwise (e.g. "Switched to
/// new context after compression").
///
/// Driven by an optional binding to a String. Setting the binding
/// non-nil shows the toast; the modifier clears the binding back to
/// nil after the duration. Keeps the call site to a single line:
///
///   .toast(message: $model.lastPromotedContextID == nil
///       ? .constant(nil)
///       : .constant("Compression promoted — switched to new context"))
///
/// (The view-side wrapper `.compressionPromotedToast(of:)` packages
/// that pattern for the conversation view's use.)
public struct Toast: View {
    let text: String
    let systemImage: String?

    public init(text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.85), in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: String?
    let systemImage: String?
    let duration: Double

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Toast(text: message, systemImage: systemImage)
                    .padding(.bottom, 90)        // clear of the composer
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        withAnimation(.easeInOut(duration: 0.25)) {
                            self.message = nil
                        }
                    }
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(message)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: message)
    }
}

public extension View {
    /// Show a transient toast at the bottom of the view when `message`
    /// is non-nil. The modifier clears the binding back to nil after
    /// `duration` seconds, so the parent doesn't need a timer.
    func toast(
        message: Binding<String?>,
        systemImage: String? = nil,
        duration: Double = 2.5
    ) -> some View {
        modifier(ToastModifier(message: message, systemImage: systemImage, duration: duration))
    }
}
