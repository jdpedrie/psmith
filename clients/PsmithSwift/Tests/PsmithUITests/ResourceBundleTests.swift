import Testing
import Foundation
@testable import PsmithUI

/// `Bundle.psmithUI` — the resource lookup behind the provider logos.
/// In a test host the bundle sits in the build directory, so this runs
/// the `Bundle.module` fallback; the point is that the logos are
/// reachable through the one accessor every caller now uses.
struct ResourceBundleTests {
    @Test func providerLogosAreReachable() {
        let svgs = Bundle.psmithUI.urls(forResourcesWithExtension: "svg", subdirectory: nil) ?? []
        #expect(!svgs.isEmpty)
    }
}
