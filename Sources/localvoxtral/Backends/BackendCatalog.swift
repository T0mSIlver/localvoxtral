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
        // post2 pins transformers <5.13: 5.13.0 broke the string-keyed
        // AutoTokenizer.register call in mlx_lm/tokenizer_utils.py, so fresh
        // installs resolving latest transformers crashed mlx_lm.server at import.
        // post3 fixes prompt-cache correctness: reuse can no longer serve KV
        // that doesn't match the request prefix (T0mSIlver/mlx-lm#2), and the
        // server cache is actually LRU with one-token prefix hits fixed
        // (T0mSIlver/mlx-lm#3).
        // post4 corrects post3's slid-cache fix: post3 disabled trimming
        // globally for a slid chunked cache, which silently corrupted
        // speculative decoding (the draft-rewind path trims and ignores the
        // result). post4 refuses arbitrary-prefix reuse in the server cache
        // only, leaving the trim/rewind contract intact (ml-explore/mlx-lm#1502,
        // #1503).
        version: "0.31.3.post4",
        requirementName: "mlx-lm",
        wheelURL: URL(string: "https://github.com/T0mSIlver/mlx-lm/releases/download/v0.31.3.post4/mlx_lm-0.31.3.post4-py3-none-any.whl")!,
        wheelSHA256: "d32d58c77b9e3a05b19748fad1ff6c26c67096a95ef88b6be990f9fed0d40bdf",
        executableName: "mlx_lm.server",
        pythonVersion: "3.12",
        port: 8472
    )

    static let all: [ManagedBackendSpec] = [voxmlx, mlxLM]
}
