import SwiftUI
import UIKit
import XCTest
@testable import PsmithiOS
import PsmithUI

/// Renders a SwiftUI view the way a phone shows it: in a real window on the
/// app's scene, so Liquid Glass and materials composite, at a chosen width
/// and appearance, with the iPhone safe areas (59 top, 34 bottom) the boards
/// assume. Captures at 2x to match the board renders.
@MainActor
enum IKRender {
    struct Size: Sendable {
        let label: String
        let width: CGFloat
        let height: CGFloat
    }

    /// The boards are 390 wide. SE, 17 Pro and Pro Max bracket it.
    static let sizes: [Size] = [
        Size(label: "375", width: 375, height: 667),
        Size(label: "390", width: 390, height: 844),
        Size(label: "402", width: 402, height: 874),
        Size(label: "440", width: 440, height: 956),
    ]

    static var outDir: URL {
        let env = ProcessInfo.processInfo.environment["PSMITH_SNAP_OUT"]
        let url = URL(fileURLWithPath: env ?? NSTemporaryDirectory() + "psmith-ios-snaps")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func image<V: View>(_ view: V, size: Size, dark: Bool, theme: Theme = .slate,
                               safeTop: CGFloat = 59, safeBottom: CGFloat = 34) -> UIImage {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        window.overrideUserInterfaceStyle = dark ? .dark : .light

        let host = UIHostingController(rootView: view
            .environment(\.theme, theme)
            .tint(theme.accent))
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        // The window inherits the simulator's own insets; top them up (or
        // pull them back) to the boards' 59/34 so every device size lays
        // out against the same safe area.
        let natural = window.safeAreaInsets
        host.additionalSafeAreaInsets = UIEdgeInsets(top: safeTop - natural.top, left: 0,
                                                     bottom: safeBottom - natural.bottom, right: 0)
        window.layoutIfNeeded()

        // SwiftUI settles layout and glass over a few runloop turns.
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    /// Writes `<name>-<width>-<dark|light>.png` for every size and appearance.
    @discardableResult
    static func shoot<V: View>(_ name: String, sizes: [Size] = IKRender.sizes, appearances: [Bool] = [true, false],
                               theme: Theme = .slate, _ make: () -> V) -> [URL] {
        var urls: [URL] = []
        for size in sizes {
            for dark in appearances {
                let img = image(make(), size: size, dark: dark, theme: theme)
                let url = outDir.appendingPathComponent("\(name)-\(size.label)-\(dark ? "dark" : "light").png")
                try? img.pngData()?.write(to: url)
                urls.append(url)
            }
        }
        return urls
    }
}
