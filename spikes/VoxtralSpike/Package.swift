// swift-tools-version: 6.1
import PackageDescription

// THROWAWAY SPIKE — not part of the shipped build.
//
// Answers one question: can mlx-audio-swift's VoxtralRealtime replace the
// managed Python voxmlx backend with acceptable accuracy and realtime headroom?
//
// Like PolishHelper, this MUST be built with xcodebuild (aggregate scheme
// "VoxtralSpike"), never `swift build`: SwiftPM's CLI cannot compile mlx-swift's
// Metal kernels, and the resulting binary dies at runtime with
// "Failed to load the default metallib".
let package = Package(
    name: "VoxtralSpike",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "voxtral-spike", targets: ["voxtral-spike"])
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.6"),
    ],
    targets: [
        .executableTarget(
            name: "voxtral-spike",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        )
    ]
)
