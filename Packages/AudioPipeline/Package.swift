// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AudioPipeline",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "AudioPipeline",
            targets: ["AudioPipeline"]
        )
    ],
    targets: [
        .target(name: "AudioPipeline"),
        .testTarget(
            name: "AudioPipelineTests",
            dependencies: ["AudioPipeline"]
        )
    ]
)
