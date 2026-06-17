// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpaltSwift",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "SpaltKit", targets: ["SpaltKit"]),
        .library(name: "SpaltUI", targets: ["SpaltUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "SpaltKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/SpaltKit"
        ),
        .target(
            name: "SpaltUI",
            dependencies: [
                "SpaltKit",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/SpaltUI",
            // Provider logos (LobeHub SVGs) bundled at build time.
            // Monochrome icons render with currentColor so they tint to
            // the surrounding foregroundStyle; colored variants
            // (`*-color.svg`) keep their authored palette.
            resources: [.process("Resources")]
        ),
        // Test harness — non-test target so multiple test targets can share it.
        // Hosts TestSpaltdServer (boots a local spaltd subprocess against an
        // isolated database), TestSession (fresh-user helper), FakeProvider
        // (embedded mock OpenAI-compatible upstream), and Fixtures (canned
        // SpaltProfilePatch / SpaltProfilePlugin builders).
        .target(
            name: "SpaltKitTestHarness",
            dependencies: ["SpaltKit"],
            path: "Tests/Harness"
        ),
        .testTarget(
            name: "SpaltKitTests",
            dependencies: ["SpaltKit", "SpaltKitTestHarness"],
            path: "Tests/SpaltKitTests"
        ),
        .testTarget(
            name: "SpaltUITests",
            dependencies: ["SpaltUI"],
            path: "Tests/SpaltUITests"
        ),
    ]
)
