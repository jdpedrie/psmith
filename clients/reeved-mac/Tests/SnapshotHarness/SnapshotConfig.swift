import Foundation
import AppKit
import SwiftUI
@_exported import SnapshotTesting

/// Standardised window sizes used throughout the snapshot tests. Three
/// sizes catch the layouts we've burned ourselves on:
///   - `.minColumn` mirrors the SettingsView middle-column floor (340pt
///     ideal width) — small enough that a clipping bug in any in-pane
///     form will trip the snapshot.
///   - `.minWindow` mirrors the AppKit `contentMinSize` enforced by
///     `AppDelegate.configure(_:)` — anything below that doesn't ship.
///   - `.default` mirrors the WindowGroup `.defaultSize` — the canvas
///     the user normally sees.
public enum SnapshotSize {
    public static let minColumn = CGSize(width: 540, height: 600)
    public static let minWindow = CGSize(width: 1080, height: 520)
    public static let `default` = CGSize(width: 1100, height: 720)
}

/// Default precision tuple. SwiftUI's text + glass effects produce 1-2%
/// subpixel jitter across runs — `perceptualPrecision` absorbs it. The
/// precise `precision` floor catches every-pixel rewrites; the looser
/// `perceptualPrecision` floor allows fonts to hint differently across
/// macOS minor versions without false-positive churn.
public let defaultPrecision: Float = 0.99
public let defaultPerceptualPrecision: Float = 0.98

/// Thin wrapper that wraps a SwiftUI view in a fixed-size NSHostingView
/// so the renderer doesn't try to negotiate with an unconstrained
/// container, then hands it to `assertSnapshot(of:as:)` with `.image`.
///
/// The view should already have every required environment value
/// supplied by the caller (SnapshotStubs / fixtures). Snapshot mode is
/// driven by the `RECORD_SNAPSHOTS` env var in the conventional way —
/// when set, references are rewritten; otherwise the assertion compares.
@MainActor
public func assertViewSnapshot<V: View>(
    _ view: V,
    size: CGSize,
    name: String? = nil,
    precision: Float = defaultPrecision,
    perceptualPrecision: Float = defaultPerceptualPrecision,
    record: Bool? = nil,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
) {
    let recordEnv = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"]
    let recordMode: SnapshotTestingConfiguration.Record = {
        if let record { return record ? .all : .missing }
        if let recordEnv, !recordEnv.isEmpty, recordEnv != "0", recordEnv.lowercased() != "false" {
            return .all
        }
        return .missing
    }()

    // Hosted view forced to the requested size. The host is attached
    // to an offscreen NSWindow so SwiftUI structural views (especially
    // NavigationSplitView) can perform their column-resolve pass —
    // they bail out of layout when the host has no window. We pump the
    // runloop briefly so deferred layout settles before we read the
    // bitmap.
    //
    // Limitations baked into this approach:
    //   * NSView's `cacheDisplay(in:to:)` (which is what
    //     SnapshotTesting's `.image` strategy ultimately calls) only
    //     captures CALayer-backed drawing. macOS 26 Liquid Glass uses
    //     Metal blurs that don't appear in the cached bitmap, and
    //     some SF-Symbol image variants render through layers we
    //     can't reach. Snapshots therefore catch *text + structural
    //     layout* regressions; missing glass chrome is expected and
    //     stable across runs.
    //   * Tests must avoid kicking off async loads in `.task { … }`
    //     since the runloop spin doesn't await network work.
    let host = NSHostingView(rootView:
        view
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark)
    )
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: .darkAqua)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderFront(nil)
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    host.layoutSubtreeIfNeeded()

    withSnapshotTesting(record: recordMode) {
        assertSnapshot(
            of: host,
            as: .image(precision: precision, perceptualPrecision: perceptualPrecision),
            named: name,
            file: file,
            testName: testName,
            line: line
        )
    }
}

/// Render a single view across a vector of sizes, producing one
/// reference image per size. Names each variant by `<sizeLabel>` so the
/// reference filenames stay self-describing.
@MainActor
public func assertViewSnapshots<V: View>(
    _ view: V,
    sizes: [(label: String, size: CGSize)],
    record: Bool? = nil,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
) {
    for (label, size) in sizes {
        assertViewSnapshot(
            view,
            size: size,
            name: label,
            record: record,
            file: file,
            testName: testName,
            line: line
        )
    }
}

/// Default size sweep — `default` and `minWindow`. Snapshots that care
/// about the column-min case pass their own.
public let defaultSizes: [(label: String, size: CGSize)] = [
    ("default", SnapshotSize.default),
    ("minWindow", SnapshotSize.minWindow),
]

public let columnSizes: [(label: String, size: CGSize)] = [
    ("default", SnapshotSize.default),
    ("minColumn", SnapshotSize.minColumn),
]
