// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "VisualTestSupport", targets: ["VisualTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        // Use MarkdownUI's existing parser to remove internal-link semantics in scoped previews.
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.4.0"),
        .package(url: "https://github.com/johnsundell/splash.git", from: "0.16.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "VisualTestSupport",
            dependencies: [.product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Core",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "Splash", package: "splash"),
            ],
            // Bundles the four EB Garamond faces (Regular / Italic /
            // SemiBold / SemiBold Italic) + JetBrains Mono Regular .ttf
            // files that `SplashView`, the Bible reader, assistant message
            // text, and other branded surfaces ask for via `Font.custom(...)`.
            // Registration is wired through `Core.registerBundledFonts()`;
            // callers must invoke it once at process start before the first
            // SwiftUI render.
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: [
                "Core",
                "VisualTestSupport",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Splash", package: "splash"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["UI/Snapshots/__Snapshots__"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
