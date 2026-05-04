import Foundation
import SwiftUI

/// Platform-glue interface for clipboard read/write. Each platform shell
/// (`ReeveMac`, future `ReeveiOS`) supplies its own implementation —
/// AppKit's `NSPasteboard` on Mac, UIKit's `UIPasteboard` on iOS — and
/// injects it via `@Environment(\.clipboard)`. Views call through this
/// instead of importing AppKit/UIKit directly so the same view code
/// compiles in both shells.
public protocol Clipboard: Sendable {
    /// Replace the system clipboard's plain-text contents with `text`.
    /// Implementations should be best-effort; failures are silent — the
    /// user-visible "Copied" toast is the primary feedback path.
    func write(_ text: String)

    /// Read the current plain-text clipboard contents. Returns nil when
    /// the clipboard holds non-text data or is empty.
    func read() -> String?
}

/// No-op implementation used as the default environment value and in
/// snapshot/Layer-1 tests where the real clipboard would be polluted by
/// test runs. Calls record nothing and `read()` always returns nil.
public struct NoopClipboard: Clipboard {
    public init() {}
    public func write(_ text: String) {}
    public func read() -> String? { nil }
}

private struct ClipboardEnvironmentKey: EnvironmentKey {
    static let defaultValue: Clipboard = NoopClipboard()
}

public extension EnvironmentValues {
    /// The platform clipboard, injected by the shell at scene
    /// construction time. Views call `clipboard.write(...)` instead of
    /// reaching into `NSPasteboard.general` so the same code path works
    /// on iOS / iPad / Mac.
    var clipboard: Clipboard {
        get { self[ClipboardEnvironmentKey.self] }
        set { self[ClipboardEnvironmentKey.self] = newValue }
    }
}
