// swift-tools-version: 6.1
import PackageDescription

// Standalone package (not part of the root localvoxtral package) so the main
// app's `swift build` / `swift test` loop never compiles the MLX C++ core.
// SwiftPM command-line builds of this package produce a binary that cannot
// load Metal kernels at runtime (mlx-swift compiles its metallib only under
// Xcode's build system) — that's fine for unit tests, which stay Metal-free.
// The shippable helper is built with xcodebuild by scripts/package_app.sh.
let package = Package(
    name: "PolishHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "localvoxtral-polishd", targets: ["localvoxtral-polishd"])
    ],
    dependencies: [
        // Revision, not a tag: the newest release (3.31.4) loads EVERY
        // .safetensors file under the model directory, ignoring
        // model.safetensors.index.json. Our default polishing model
        // (mlx-community/Qwen3.5-4B-OptiQ-4bit) ships optiq/mtp.safetensors +
        // optiq/optiq_vision.safetensors next to the indexed weights, so those
        // auxiliary tensors get merged into the model's weight dictionary and
        // generation comes out incoherent. Fixed upstream by ml-explore/
        // mlx-swift-lm#408 (this commit, main head); move back to a tag once a
        // release carries it.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "f5f18ed9d3373b21874bd43da34922377c6da0fb"
        ),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "PolishHelperCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "localvoxtral-polishd",
            dependencies: ["PolishHelperCore"]
        ),
        .testTarget(
            name: "PolishHelperCoreTests",
            dependencies: [
                "PolishHelperCore",
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
