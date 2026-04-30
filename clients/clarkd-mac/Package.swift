// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "clarkd-mac",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "ClarkSwift", path: "../ClarkSwift"),
        // Layer-2 (snapshot) tests only. Pinned to 1.x — the executable
        // target deliberately does not depend on it; it's surfaced solely
        // through the SnapshotHarness + ClarkMacSnapshotTests targets.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClarkMac",
            dependencies: [
                .product(name: "ClarkKit", package: "ClarkSwift"),
                .product(name: "ClarkUI", package: "ClarkSwift"),
            ],
            path: "ClarkMac"
        ),
        .executableTarget(
            name: "Verify",
            dependencies: [
                .product(name: "ClarkKit", package: "ClarkSwift"),
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
                .product(name: "ClarkKit", package: "ClarkSwift"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/SnapshotHarness"
        ),
        // Snapshot tests live in their own target so they can `@testable
        // import ClarkMac` and reach the executable's internal SwiftUI
        // views directly.
        .testTarget(
            name: "ClarkMacSnapshotTests",
            dependencies: [
                "ClarkMac",
                "SnapshotHarness",
                .product(name: "ClarkKit", package: "ClarkSwift"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/ClarkMacSnapshotTests",
            exclude: ["__Snapshots__"]
        ),
    ]
)
