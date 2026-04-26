// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatLiveLLM",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../../Packages/Core"),
        .package(path: "../../Packages/Chat"),
    ],
    targets: [
        .executableTarget(
            name: "ChatLiveLLM",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "Chat", package: "Chat"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
