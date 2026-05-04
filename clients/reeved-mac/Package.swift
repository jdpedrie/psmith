// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "reeved-mac",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "ReeveSwift", path: "../ReeveSwift"),
        // Layer-2 (snapshot) tests only. Pinned to 1.x — the executable
        // target deliberately does not depend on it; it's surfaced solely
        // through the SnapshotHarness + ReeveMacSnapshotTests targets.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .executableTarget(
            name: "ReeveMac",
            dependencies: [
                .product(name: "ReeveKit", package: "ReeveSwift"),
                .product(name: "ReeveUI", package: "ReeveSwift"),
            ],
            path: "ReeveMac"
            // Provider logos moved to ReeveUI/Resources/Logos so the iOS
            // app can ship the same `ProviderLogo` view without
            // duplicating the SVG bundle.
        ),
        .executableTarget(
            name: "Verify",
            dependencies: [
                .product(name: "ReeveKit", package: "ReeveSwift"),
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
                .product(name: "ReeveKit", package: "ReeveSwift"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/SnapshotHarness"
        ),
        // Snapshot tests live in their own target so they can `@testable
        // import ReeveMac` and reach the executable's internal SwiftUI
        // views directly.
        .testTarget(
            name: "ReeveMacSnapshotTests",
            dependencies: [
                "ReeveMac",
                "SnapshotHarness",
                .product(name: "ReeveKit", package: "ReeveSwift"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/ReeveMacSnapshotTests",
            exclude: ["__Snapshots__"]
        ),
    ]
)
