import Foundation

struct ManagedBackendSpec: Equatable, Sendable {
    let id: String
    let displayName: String
    let version: String
    let requirementName: String
    let wheelURL: URL
    let wheelSHA256: String
    let executableName: String
    let pythonVersion: String
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
    static let voxmlx = ManagedBackendSpec(
        id: "voxmlx",
        displayName: "voxmlx",
        version: "0.1.0",
        requirementName: "voxmlx[server]",
        wheelURL: URL(string: "https://github.com/T0mSIlver/voxmlx/releases/download/v0.1.0/voxmlx-0.1.0-py3-none-any.whl")!,
        wheelSHA256: "028b39a51e6f5e4126b009fe0a316e68fe9215d500de970ea125a0ba550d8c83",
        executableName: "voxmlx-serve",
        pythonVersion: "3.12",
        port: 8471
    )

    static let mlxLM = ManagedBackendSpec(
        id: "mlx-lm",
        displayName: "mlx-lm",
        version: "0.31.3.post1",
        requirementName: "mlx-lm",
        wheelURL: URL(string: "https://github.com/T0mSIlver/mlx-lm/releases/download/v0.31.3.post1/mlx_lm-0.31.3.post1-py3-none-any.whl")!,
        wheelSHA256: "05bcc1a66f5f3b1127e9eae9ed54f9ad046b12af97c0829632ecde70c6f3a87b",
        executableName: "mlx_lm.server",
        pythonVersion: "3.12",
        port: 8472
    )

    static let all: [ManagedBackendSpec] = [voxmlx, mlxLM]
}
