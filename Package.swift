// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BabylonSpeech",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "BabylonSpeech",
            targets: ["BabylonSpeech"]
        ),
        .library(
            name: "BabylonSpeechOpenAI",
            targets: ["BabylonSpeechOpenAI"]
        ),
        .library(
            name: "BabylonSpeechGoogle",
            targets: ["BabylonSpeechGoogle"]
        ),
    ],
    dependencies: [
        .package(path: "../babylon.audio"),
    ],
    targets: [
        .target(
            name: "BabylonSpeech",
            dependencies: [
                .product(name: "BabylonAudio", package: "babylon.audio"),
            ]
        ),
        .target(
            name: "BabylonSpeechOpenAI",
            dependencies: [
                "BabylonSpeech",
                .product(name: "BabylonAudio", package: "babylon.audio"),
            ]
        ),
        .target(
            name: "BabylonSpeechGoogle",
            dependencies: [
                "BabylonSpeech",
                .product(name: "BabylonAudio", package: "babylon.audio"),
            ]
        ),
        .testTarget(
            name: "BabylonSpeechTests",
            dependencies: [
                "BabylonSpeech",
                .product(name: "BabylonAudio", package: "babylon.audio"),
            ]
        ),
        .testTarget(
            name: "BabylonSpeechOpenAITests",
            dependencies: ["BabylonSpeechOpenAI"]
        ),
        .testTarget(
            name: "BabylonSpeechGoogleTests",
            dependencies: ["BabylonSpeechGoogle"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
