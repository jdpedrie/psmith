import SwiftUI
import QuickLook

/// SwiftUI wrapper around `QLPreviewController` for previewing a
/// single local file URL. Used by `MessageAttachmentChip` to render
/// PDF / audio / video attachments inline via Quick Look — no
/// external app handoff, no extra UI to build.
///
/// Quick Look needs a *file* URL, not a remote one, so the caller
/// is expected to download to a temp path first and pass that URL
/// here.
struct MessageAttachmentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
