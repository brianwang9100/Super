// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bible",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "Bible", targets: ["Bible"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "Bible",
            dependencies: [
                "Core",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BibleTests",
            dependencies: [
                "Bible",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
