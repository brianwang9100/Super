// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chat",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "Chat", targets: ["Chat"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/groue/GRDBQuery.git", from: "0.10.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        .package(url: "https://github.com/johnsundell/splash.git", from: "0.16.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
        .package(url: "https://github.com/groue/GRDBSnapshotTesting.git", from: "0.3.0"),
    ],
    targets: [
        .target(
            name: "Chat",
            dependencies: [
                "Core",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GRDBQuery", package: "GRDBQuery"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Splash", package: "splash"),
            ],
            // `.process` flattens the directory into the bundle root —
            // `Resources/DefaultSystemPrompt.md` ends up at
            // `Chat_Chat.bundle/DefaultSystemPrompt.md`. We use `.process`
            // (not `.copy`) because the `.copy` layout (`Info.plist` at
            // root + `Resources/` subfolder) is neither iOS-shallow nor
            // macOS-deep, which makes `codesign` reject the bundle with
            // "bundle format unrecognized" — breaking simulator builds
            // that need a signed app for Keychain entitlements.
            // `ChatSettings._loadBundledDefaultSystemPrompt` looks the
            // file up without a subdirectory to match this layout.
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ChatTests",
            dependencies: [
                "Chat",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "GRDBSnapshotTesting", package: "GRDBSnapshotTesting"),
            ],
            exclude: [
                "Database/__Snapshots__",
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
