import Foundation

/// The app's own build identity, stamped into the bundle's Info.plist
/// at build time (`PsmithBuildCommit`): the short commit hash, with a
/// `+YYYYMMDDHHMM` suffix when the tree was dirty. The iOS stamp comes
/// from an Xcode build phase (clients/psmithd-ios/project.yml); the
/// Mac stamp from the `mac-app` Makefile target. Builds that skip
/// those paths (previews, `swift run`, test bundles) read "dev".
///
/// The paired server identity comes over the wire instead:
/// `AuthService.Probe` returns the server's stamp (see
/// `AuthRepository.probe()`), so a settings footer can show both and
/// the user can tell at a glance whether either side is stale.
public enum BuildInfo {
    public static var commit: String {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "PsmithBuildCommit") as? String,
            !raw.isEmpty
        else { return "dev" }
        return raw
    }
}
