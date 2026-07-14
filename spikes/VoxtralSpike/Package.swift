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
        // Pinned to mlx-audio-swift's own resolved graph. Left to float, SwiftPM picks
        // swift-transformers >= 1.2, which does not compile under Xcode 26's toolchain
        // (Hub/Config.swift: ObjectKey vs String dictionary-key type errors).
        // mlx-swift 0.31.3 is also deliberate: 0.31.4 introduced the evalLock deadlock
        // (ml-explore/mlx-swift#428) that our polishd helper is currently pinned to.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9"),
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
