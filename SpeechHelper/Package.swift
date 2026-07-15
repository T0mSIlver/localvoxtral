// swift-tools-version: 6.1
import PackageDescription

// Standalone package (like PolishHelper) so the main app's `swift build` / `swift test`
// loop never compiles mlx-swift's C++/Metal core. The shippable helper is built with
// xcodebuild by scripts/package_app.sh; a plain `swift build` of this package compiles
// but produces a binary that cannot load Metal kernels at runtime — fine for the
// Metal-free unit tests (SpeechEngineTextTests), which is what CI's tier-0 lane runs here.
//
// SpeechEngine vendors Blaizzy/mlx-audio-swift's VoxtralRealtime (MIT) with local fixes —
// see VENDORED.md. It replaces the managed Python voxmlx backend.
let package = Package(
    name: "SpeechHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "localvoxtral-speechd", targets: ["localvoxtral-speechd"]),
        .library(name: "SpeechEngineText", targets: ["SpeechEngineText"]),
    ],
    dependencies: [
        // Pinned to mlx-audio-swift's own resolved graph (its Package.resolved): mlx-swift
        // 0.31.3 (the last version before the #428 evalLock deadlock in 0.31.4) and
        // swift-transformers 1.1.9 (>=1.2 fails to compile under Xcode 26).
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.8.1"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.3"),
    ],
    targets: [
        // Pure-Swift, Metal-free: the append-only delta contract. Kept separate so its
        // regression tests run in the tier-0 `swift test` lane without touching MLX.
        .target(name: "SpeechEngineText"),
        .testTarget(
            name: "SpeechEngineTextTests",
            dependencies: ["SpeechEngineText"]
        ),
        // The vendored Voxtral Realtime engine (MLX; needs Metal at runtime).
        .target(
            name: "SpeechEngine",
            dependencies: [
                "SpeechEngineText",
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
        .executableTarget(
            name: "localvoxtral-speechd",
            dependencies: ["SpeechEngine"]
        ),
    ]
)
