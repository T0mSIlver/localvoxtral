import Foundation

/// How a managed backend's executable gets onto the user's Mac.
enum BackendInstallKind: Equatable, Sendable {
    /// Installed at runtime: pinned wheel via a pinned uv into the app-managed
    /// backends/ tree under Application Support.
    case uvWheel(wheelURL: URL, wheelSHA256: String, requirementName: String, pythonVersion: String)
    /// Ships inside the .app bundle (Contents/MacOS); nothing to install or
    /// update at runtime — the app's own update cycle owns it.
    case bundledExecutable
}

struct ManagedBackendSpec: Equatable, Sendable {
    let id: String
    let displayName: String
    let version: String
    let installKind: BackendInstallKind
    let executableName: String
    let port: Int
}

struct UVDistribution: Equatable, Sendable {
    let version: String
    let tarballURL: URL
    let tarballSHA256: String
    let archiveBinaryPath: String

    static let pinned = UVDistribution(
        version: "0.11.26",
        tarballURL: URL(string: "https://github.com/astral-sh/uv/releases/download/0.11.26/uv-aarch64-apple-darwin.tar.gz")!,
        tarballSHA256: "8f7fbf1708399b921857bce71e1d60f0d3ccf52a30caebc1c1a2f175dce13ab6",
        archiveBinaryPath: "uv-aarch64-apple-darwin/uv"
    )
}

enum BackendCatalog {
    /// Retained for installed-backend cleanup and the part-4 retirement work.
    /// It is no longer part of the managed bootstrap set.
    static let voxmlx = ManagedBackendSpec(
        id: "voxmlx",
        displayName: "voxmlx",
        version: "0.1.0",
        installKind: .uvWheel(
            wheelURL: URL(string: "https://github.com/T0mSIlver/voxmlx/releases/download/v0.1.0/voxmlx-0.1.0-py3-none-any.whl")!,
            wheelSHA256: "028b39a51e6f5e4126b009fe0a316e68fe9215d500de970ea125a0ba550d8c83",
            requirementName: "voxmlx[server]",
            pythonVersion: "3.12"
        ),
        executableName: "voxmlx-serve",
        port: 8471
    )

    /// The dictation engine: localvoxtral-speechd (MLX Swift, see
    /// SpeechHelper/), bundled inside the .app. It serves the same loopback
    /// OpenAI Realtime subset and port as voxmlx, so client endpoints stay
    /// stable while managed bootstrap moves off the Python process.
    static let speechd = ManagedBackendSpec(
        id: "speechd",
        displayName: "Dictation engine",
        version: "bundled",
        installKind: .bundledExecutable,
        executableName: "localvoxtral-speechd",
        port: 8471
    )

    /// The polishing engine: localvoxtral-polishd (MLX Swift, see PolishHelper/),
    /// bundled inside the .app. It replaced the uv-installed mlx-lm fork wheel:
    /// upstream mlx-lm went unmaintained and the fork existed to carry fixes
    /// (transformers pins, prompt-cache correctness, parent-pid watchdog) that
    /// the Swift helper now owns directly.
    static let polishd = ManagedBackendSpec(
        id: "polishd",
        displayName: "Polishing engine",
        version: "bundled",
        installKind: .bundledExecutable,
        executableName: "localvoxtral-polishd",
        port: 8472
    )

    static let all: [ManagedBackendSpec] = [speechd, polishd]
}
