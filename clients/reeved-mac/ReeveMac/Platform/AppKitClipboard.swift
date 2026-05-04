import AppKit
import ReeveKit

/// AppKit-backed `Clipboard`. Wraps `NSPasteboard.general` so the rest
/// of the app can stay AppKit-free. `clearContents()` precedes
/// `setString` to evict any previous types (rich text, URLs) that
/// might otherwise survive when the next paste resolves type
/// preference order.
struct AppKitClipboard: Clipboard {
    func write(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func read() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
