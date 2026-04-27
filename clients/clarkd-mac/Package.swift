// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "clarkd-mac",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "ClarkSwift", path: "../ClarkSwift"),
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
    ]
)
