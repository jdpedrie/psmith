// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReeveSwift",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "ReeveKit", targets: ["ReeveKit"]),
        .library(name: "ReeveUI", targets: ["ReeveUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "ReeveKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/ReeveKit"
        ),
        .target(
            name: "ReeveUI",
            dependencies: [
                "ReeveKit",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/ReeveUI",
            // Provider logos (LobeHub SVGs) bundled at build time.
            // Monochrome icons render with currentColor so they tint to
            // the surrounding foregroundStyle; colored variants
            // (`*-color.svg`) keep their authored palette.
            resources: [.process("Resources")]
        ),
        // Test harness — non-test target so multiple test targets can share it.
        // Hosts TestReevedServer (boots a local reeved subprocess against an
        // isolated database), TestSession (fresh-user helper), FakeProvider
        // (embedded mock OpenAI-compatible upstream), and Fixtures (canned
        // ReeveProfilePatch / ReeveProfilePlugin builders).
        .target(
            name: "ReeveKitTestHarness",
            dependencies: ["ReeveKit"],
            path: "Tests/Harness"
        ),
        .testTarget(
            name: "ReeveKitTests",
            dependencies: ["ReeveKit", "ReeveKitTestHarness"],
            path: "Tests/ReeveKitTests"
        ),
    ]
)
