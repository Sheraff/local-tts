// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalTTS",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "LocalTTSCore", targets: ["LocalTTSCore"]),
        .executable(name: "LocalTTS", targets: ["LocalTTS"]),
        .executable(name: "LocalTTSTestRunner", targets: ["LocalTTSTestRunner"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            from: "1.24.2"
        ),
        .package(url: "https://github.com/Sheraff/espeak-ng-spm.git", branch: "local-tts-macos-fixes"),
    ],
    targets: [
        .target(
            name: "LocalTTSCore",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "libespeak-ng", package: "espeak-ng-spm"),
                .product(name: "espeak-ng-data", package: "espeak-ng-spm"),
            ],
            exclude: [
                "KokoroG2P/LICENSE-MisakiSwift.txt",
            ],
            resources: [
                .copy("Resources/KokoroG2P"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "LocalTTS",
            dependencies: ["LocalTTSCore"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "LocalTTSTestRunner",
            dependencies: ["LocalTTSCore"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
