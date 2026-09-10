// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bible",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Bible", targets: ["Bible"]),
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
            name: "Bible",
            dependencies: [
                "Core",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GRDBQuery", package: "GRDBQuery"),
            ],
            // `.process` keeps simulator bundles codesign-valid; `.copy` does not.
            // Ship the text SQLite database; per-book JSON remains a test oracle.
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BibleTests",
            dependencies: [
                .product(name: "VisualTestSupport", package: "Core"),
                "Bible",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "GRDBSnapshotTesting", package: "GRDBSnapshotTesting"),
            ],
            // Snapshots are read through #filePath, outside the resource bundle.
            exclude: [
                "Database/__Snapshots__",
                "UI/Snapshots/__Snapshots__",
            ],
            // `.process` flattens fixtures for name-based lookup by BundledBibleTextLoader.
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
