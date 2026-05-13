import SwiftUI
import UIKit

/// SwiftUI text input backed by `UITextView` so we can intercept
/// the standard paste action and route image-pasteboard content
/// to an `onImagePaste` callback instead of letting iOS try to
/// stringify the image and stick the file URL in the text.
///
/// Sizes itself like the SwiftUI vertical TextField it replaces:
/// auto-grows from `minHeight` to `maxHeight`, then enables
/// scrolling. The measured height is reported via the
/// `measuredHeight` binding so the parent view's layout can
/// reserve the right slot in the composer.
///
/// Placeholder is owned by the parent (overlayed Text); kept out
/// of here so the wrapper stays focused on text + paste plumbing.
struct PasteAwareTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    var minHeight: CGFloat
    var maxHeight: CGFloat
    var onImagePaste: (Data) -> Void

    func makeUIView(context: Context) -> InternalTextView {
        let view = InternalTextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.adjustsFontForContentSizeCategory = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: InternalTextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
            recalculateHeight(view: uiView)
        }
        // Mirror SwiftUI focus state into UIKit. Skip when the
        // text view's actual responder state already matches —
        // becomeFirstResponder fires keyboard animations even
        // when redundant.
        if isFocused, !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !isFocused, uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    fileprivate func recalculateHeight(view: UITextView) {
        let width = view.bounds.width > 0 ? view.bounds.width : view.intrinsicContentSize.width
        let size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let bounded = min(max(size.height, minHeight), maxHeight)
        // Flip scrolling on once we hit the cap, off below it —
        // matches the SwiftUI `.lineLimit(1...8)` behavior the
        // composer used previously (grow up to N lines, then
        // start scrolling internally).
        let shouldScroll = size.height > maxHeight
        if view.isScrollEnabled != shouldScroll {
            view.isScrollEnabled = shouldScroll
        }
        if abs(measuredHeight - bounded) > 0.5 {
            DispatchQueue.main.async { measuredHeight = bounded }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteAwareTextField

        init(parent: PasteAwareTextField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.recalculateHeight(view: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused {
                DispatchQueue.main.async { self.parent.isFocused = true }
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused {
                DispatchQueue.main.async { self.parent.isFocused = false }
            }
        }

        @MainActor
        fileprivate func handleImagePaste(_ data: Data) {
            parent.onImagePaste(data)
        }
    }

    /// UITextView subclass that overrides `paste(_:)` to peel
    /// off images from the system pasteboard. Text paste falls
    /// through to the default UIKit behavior.
    final class InternalTextView: UITextView {
        weak var coordinator: Coordinator?

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            // Surface "Paste" in the edit menu whenever there's
            // either text OR an image on the clipboard. UIKit's
            // default only enables it for matching mime types
            // (text-in-text-view) — without this override the
            // long-press Paste item is hidden when only an image
            // is on the board, leaving the user with no way to
            // invoke our paste handler.
            if action == #selector(UIResponderStandardEditActions.paste(_:)) {
                if UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings {
                    return true
                }
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            if let image = UIPasteboard.general.image,
               let data = image.jpegData(compressionQuality: 0.92) {
                Task { @MainActor in
                    self.coordinator?.handleImagePaste(data)
                }
                return
            }
            super.paste(sender)
        }
    }
}
