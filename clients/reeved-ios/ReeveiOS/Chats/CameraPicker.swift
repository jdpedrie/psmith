import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around UIImagePickerController in
/// `.camera` source mode. Presented from the composer's paperclip
/// menu via `.fullScreenCover` so the camera fills the screen and
/// the user-facing controls land in their familiar positions
/// (capture button at the bottom, cancel at the top-left).
///
/// On capture: invokes `onCapture` with the JPEG-encoded bytes of
/// the photo (re-encoded from the picker's UIImage so the rest of
/// the attach pipeline — preprocessing, upload — sees a single
/// uniform mime type regardless of which sensor produced the
/// image). On cancel or any failure: invokes `onCancel`.
///
/// Camera-only by design — picking from the photo library is a
/// separate menu item that goes through PhotosPicker (more
/// privacy-respecting and gives the asset's original metadata).
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // Prefer the original image (full sensor res) over the
            // edited variant — we don't allow editing in this picker
            // anyway. Fall back to .editedImage if a future change
            // flips allowsEditing on without remembering to update
            // here.
            let image = (info[.originalImage] as? UIImage)
                ?? (info[.editedImage] as? UIImage)
            guard let image, let data = image.jpegData(compressionQuality: 0.92) else {
                onCancel()
                return
            }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
