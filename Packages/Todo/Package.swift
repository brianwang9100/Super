// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Todo",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "Todo", targets: ["Todo"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/groue/GRDBQuery.git", from: "0.10.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
        .package(url: "https://github.com/groue/GRDBSnapshotTesting.git", from: "0.3.0"),
    ],
    targets: [
        .target(
            name: "Todo",
            dependencies: [
                "Core",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GRDBQuery", package: "GRDBQuery"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "TodoTests",
            dependencies: [
                "Todo",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "GRDBSnapshotTesting", package: "GRDBSnapshotTesting"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
