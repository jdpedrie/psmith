// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "psmithd-mac",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "PsmithSwift", path: "../PsmithSwift"),
        // Layer-2 (snapshot) tests only. Pinned to 1.x — the executable
        // target deliberately does not depend on it; it's surfaced solely
        // through the SnapshotHarness + PsmithMacSnapshotTests targets.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .executableTarget(
            name: "PsmithMac",
            dependencies: [
                .product(name: "PsmithKit", package: "PsmithSwift"),
                .product(name: "PsmithUI", package: "PsmithSwift"),
            ],
            path: "PsmithMac"
            // Provider logos moved to PsmithUI/Resources/Logos so the iOS
            // app can ship the same `ProviderLogo` view without
            // duplicating the SVG bundle.
        ),
        .executableTarget(
            name: "Verify",
            dependencies: [
                .product(name: "PsmithKit", package: "PsmithSwift"),
            ],
            path: "Verify"
        ),
        // Snapshot harness — non-test target so the test target itself can
        // stay focused on @Test bodies. Hosts Fixtures (canned domain
        // models), Stubs (pre-loaded view models that satisfy view
        // @Environment requirements without a server), and SnapshotConfig
        // (the assertSnapshot wrapper that pins window size + appearance).
        .target(
            name: "SnapshotHarness",
            dependencies: [
                .product(name: "PsmithKit", package: "PsmithSwift"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/SnapshotHarness"
        ),
        // Snapshot tests live in their own target so they can `@testable
        // import PsmithMac` and reach the executable's internal SwiftUI
        // views directly.
        .testTarget(
            name: "PsmithMacSnapshotTests",
            dependencies: [
                "PsmithMac",
                "SnapshotHarness",
                .product(name: "PsmithKit", package: "PsmithSwift"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/PsmithMacSnapshotTests",
            exclude: ["__Snapshots__"]
        ),
    ]
)
