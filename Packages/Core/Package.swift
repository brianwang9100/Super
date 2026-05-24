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
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "Core",
            // Bundles the Instrument Serif Italic + JetBrains Mono Regular
            // .ttf files that `SplashView` and other branded surfaces ask
            // for via `Font.custom(...)`. Registration is wired through
            // `Core.registerBundledFonts()`; callers must invoke it once
            // at process start before the first SwiftUI render.
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
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            // Snapshot PNG baselines live next to each snapshot test file
            // under `__Snapshots__/<TestSuite>/`. They're consumed by
            // SnapshotTesting at runtime via `Bundle.module`-relative
            // lookups SwiftPM doesn't model — excluding them silences the
            // "unhandled files" warning without changing test behavior.
            exclude: [
                "UI/Snapshots/__Snapshots__",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
