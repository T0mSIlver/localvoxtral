// swift-tools-version: 6.1
import PackageDescription

// Standalone package (like PolishHelper) so the main app's `swift build` / `swift test`
// loop never compiles mlx-swift's C++/Metal core. The shippable helper is built with
// xcodebuild by scripts/package_app.sh; a plain `swift build` of this package compiles
// but produces a binary that cannot load Metal kernels at runtime — fine for the
// Metal-free unit tests (SpeechEngineTextTests), which is what CI's tier-0 lane runs here.
//
// SpeechEngine consumes Blaizzy/mlx-audio-swift's VoxtralRealtime engine as an upstream
// dependency (product `MLXAudioSTT`), pinned to a reviewed revision — see DEPENDENCY.md.
// The float32-leak fixes we previously carried as local patches were upstreamed in
// Blaizzy/mlx-audio-swift#226. Only the append-only delta contract stays local, now in
// our own SpeechEngineText layer (TranscriptDeltaEmitter). Replaces the managed Python
// voxmlx backend.
let package = Package(
    name: "SpeechHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "localvoxtral-speechd", targets: ["localvoxtral-speechd"]),
    ],
    dependencies: [
        // Pinned to mlx-audio-swift's own resolved graph (its Package.resolved): mlx-swift
        // 0.31.3 (the last version before the #428 evalLock deadlock in 0.31.4) and
        // swift-transformers 1.1.9 (>=1.2 fails to compile under Xcode 26).
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3"),
        // Pinned but not directly imported: it's a transitive dep of mlx-audio-swift, and
        // >=1.2 fails to compile under Xcode 26 (the xcodebuild packaging lane). Pinning it
        // here freezes the whole graph to 1.1.9. (SPM warns it's "unused" — expected.)
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.8.1"),
        // The Voxtral Realtime engine, consumed as a dependency (was vendored+patched before
        // #226). Pinned to a full-SHA revision, not a tag, so the exact reviewed tree is
        // reproducible — see DEPENDENCY.md for the upgrade procedure.
        //
        // 8ed8188 is the merge of Blaizzy/mlx-audio-swift#232 (quantized-tied-embedding
        // loader — required by the catalog's -qhead model, SpeechModelCatalog); with it
        // upstream main carries everything the temporary T0mSIlver fork pin held, so the
        // pin is back on upstream.
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "8ed8188bf862062d2c6f4c6ecefbfed301f615a0"
        ),
    ],
    targets: [
        // Pure-Swift, Metal-free: the append-only delta contract (StreamingDelta +
        // TranscriptDeltaEmitter), the realtime wire protocol/codecs, and the watchdog.
        // Kept separate so its regression tests run in the tier-0 `swift test` lane
        // without touching MLX.
        .target(name: "SpeechEngineText"),
        .testTarget(
            name: "SpeechEngineTextTests",
            dependencies: ["SpeechEngineText"]
        ),
        // Our loopback OpenAI-Realtime server, driving the upstream Voxtral Realtime engine
        // (MLX; needs Metal at runtime).
        .target(
            name: "SpeechEngine",
            dependencies: [
                "SpeechEngineText",
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "localvoxtral-speechd",
            dependencies: ["SpeechEngine", "SpeechEngineText"]
        ),
    ]
)
