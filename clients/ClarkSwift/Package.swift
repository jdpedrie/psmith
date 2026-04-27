// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClarkSwift",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "ClarkKit", targets: ["ClarkKit"]),
        .library(name: "ClarkUI", targets: ["ClarkUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "ClarkKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/ClarkKit"
        ),
        .target(
            name: "ClarkUI",
            dependencies: [
                "ClarkKit",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/ClarkUI"
        ),
        .testTarget(
            name: "ClarkKitTests",
            dependencies: ["ClarkKit"],
            path: "Tests/ClarkKitTests"
        ),
    ]
)
