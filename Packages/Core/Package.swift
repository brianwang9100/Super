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
    targets: [
        .target(
            name: "Core",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
