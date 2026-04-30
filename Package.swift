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
        .package(path: "Vendor/MisakiSwift"),
        .package(url: "https://github.com/Ryu0118/swift-readability", exact: "0.3.0"),
    ],
    targets: [
        .target(
            name: "LocalTTSCore",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "MisakiSwift", package: "MisakiSwift"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "LocalTTS",
            dependencies: [
                "LocalTTSCore",
                .product(name: "Readability", package: "swift-readability"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "LocalTTSTestRunner",
            dependencies: ["LocalTTSCore"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
