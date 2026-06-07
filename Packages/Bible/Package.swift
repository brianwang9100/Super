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
            // `.process` (not `.copy`) keeps the bundle codesign-valid on the
            // iOS simulator — see the note in `Chat/Package.swift`. Ships the
            // prebuilt `bible-text.sqlite` (the sole on-device source of Bible
            // text) and `SystemPrompt.md`. The per-book JSON the sqlite is built
            // from is no longer shipped — it lives in the test target's fixtures.
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
                "Bible",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "GRDBSnapshotTesting", package: "GRDBSnapshotTesting"),
            ],
            // Snapshot baselines are read from the source tree at test time
            // via `#filePath`, not the bundle — exclude them from resource
            // processing.
            exclude: [
                "UI/Snapshots/__Snapshots__",
                "Database/__Snapshots__",
            ],
            // `Fixtures/Text/` holds the 264 per-book `<CODE>-<bookID>.json`
            // (the parity oracle the shipped sqlite is generated from), and
            // `Fixtures/WEB-BAD.json` is a deliberately malformed resource the
            // loader's malformed-resource test reads. `.process` flattens them
            // into the test bundle, where `BundledBibleTextLoader` looks them up
            // by name.
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
