// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PsmithSwift",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "PsmithKit", targets: ["PsmithKit"]),
        .library(name: "PsmithUI", targets: ["PsmithUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "PsmithKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/PsmithKit"
        ),
        .target(
            name: "PsmithUI",
            dependencies: [
                "PsmithKit",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/PsmithUI",
            // Provider logos (LobeHub SVGs) bundled at build time.
            // Monochrome icons render with currentColor so they tint to
            // the surrounding foregroundStyle; colored variants
            // (`*-color.svg`) keep their authored palette.
            resources: [.process("Resources")]
        ),
        // Test harness — non-test target so multiple test targets can share it.
        // Hosts TestPsmithdServer (boots a local psmithd subprocess against an
        // isolated database), TestSession (fresh-user helper), FakeProvider
        // (embedded mock OpenAI-compatible upstream), and Fixtures (canned
        // PsmithProfilePatch / PsmithProfilePlugin builders).
        .target(
            name: "PsmithKitTestHarness",
            dependencies: ["PsmithKit"],
            path: "Tests/Harness"
        ),
        .testTarget(
            name: "PsmithKitTests",
            dependencies: ["PsmithKit", "PsmithKitTestHarness"],
            path: "Tests/PsmithKitTests"
        ),
        .testTarget(
            name: "PsmithUITests",
            dependencies: ["PsmithUI"],
            path: "Tests/PsmithUITests"
        ),
    ]
)
