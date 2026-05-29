// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Todo",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
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
            // Holds `SystemPrompt.md` — the applet's contribution to the
            // Chat leading system message. `.process` (not `.copy`) keeps
            // the bundle codesign-valid on the iOS simulator.
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "TodoTests",
            dependencies: [
                "Todo",
                .product(name: "Core", package: "Core"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "GRDBSnapshotTesting", package: "GRDBSnapshotTesting"),
            ],
            exclude: [
                "Database/__Snapshots__",
                "UI/Snapshots/__Snapshots__",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
