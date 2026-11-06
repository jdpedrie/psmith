import Testing
import AppKit
@testable import PsmithMac
import PsmithUI

/// The Dock icon mapping has to cover every theme: a theme added to
/// `Theme.allThemes` without an icon would silently show the default one.
@Suite("DockIconSync")
struct DockIconSyncTests {
    private var appBundleDir: URL {
        // Tests/PsmithMacSnapshotTests/<this file> -> clients/psmithd-mac/AppBundle
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AppBundle")
    }

    @Test("System keeps the bundle icon; every other theme has its own")
    func everyThemeIsMapped() {
        #expect(DockIconSync.resourceName(forThemeID: Theme.system.id) == nil)
        for theme in Theme.allThemes where theme.id != Theme.system.id {
            #expect(DockIconSync.resourceName(forThemeID: theme.id) != nil, "no Dock icon for \(theme.id)")
        }
    }

    @Test("each mapped icon exists and decodes")
    @MainActor
    func iconsDecode() throws {
        for theme in Theme.allThemes {
            guard let name = DockIconSync.resourceName(forThemeID: theme.id) else { continue }
            let url = appBundleDir.appendingPathComponent("\(name).png")
            let image = try #require(NSImage(contentsOf: url), "\(url.lastPathComponent) missing or unreadable")
            #expect(image.size.width >= 512, "\(name) too small for the Dock")
        }
    }
}
