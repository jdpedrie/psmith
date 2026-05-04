import UIKit
import ReeveKit

/// UIKit-backed `Clipboard`. Wraps `UIPasteboard.general` so the rest
/// of the app stays UIKit-free. iOS doesn't need an explicit
/// "clear contents" — assigning `string` replaces what's there.
struct UIKitClipboard: Clipboard {
    func write(_ text: String) {
        UIPasteboard.general.string = text
    }

    func read() -> String? {
        UIPasteboard.general.string
    }
}
