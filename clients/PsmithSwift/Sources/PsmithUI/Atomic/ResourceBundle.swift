import Foundation

private final class PsmithUIBundleToken {}

extension Bundle {
    /// The PsmithUI resource bundle (provider logos).
    ///
    /// SwiftPM's generated `Bundle.module` checks beside the host's
    /// bundle and then the absolute path of the build directory the
    /// binary was compiled in, never `Contents/Resources`, which is
    /// where the Mac app bundle carries the resources. The installed app
    /// therefore ran on the build-directory fallback and trapped on its
    /// first provider logo the moment the checkout moved (2026-09-26,
    /// `dev/clark` became `dev/psmith`). Look inside the host bundle
    /// first; `Bundle.module` stays the fallback for `swift run` and
    /// test hosts, where the bundle sits in the build directory.
    static let psmithUI: Bundle = {
        let name = "PsmithSwift_PsmithUI.bundle"
        for host in [Bundle.main, Bundle(for: PsmithUIBundleToken.self)] {
            for base in [host.resourceURL, host.bundleURL] {
                if let base, let bundle = Bundle(url: base.appendingPathComponent(name)) {
                    return bundle
                }
            }
        }
        return Bundle.module
    }()
}
