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
            // iOS simulator — see the note in `Chat/Package.swift`. The 66
            // `WEB-<bookID>.json` files land flat at the bundle root, where
            // `BundledBibleTextLoader` looks them up by name.
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
            ],
            // Snapshot baselines are read from the source tree at test time
            // via `#filePath`, not the bundle — exclude them from resource
            // processing.
            exclude: [
                "UI/Snapshots/__Snapshots__",
            ],
            // `Fixtures/WEB-BAD.json` is a deliberately malformed resource
            // the loader's malformed-resource test reads via the test bundle.
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
