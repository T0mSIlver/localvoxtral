#!/usr/bin/env bash
# Runs the speech helper's Metal-free tests (SpeechEngineTextTests) on Linux,
# with no Mac. SpeechHelper's own manifest needs mlx-swift, which needs macOS and
# a newer SwiftPM, so this builds the pure-Swift target from a manifest of its own
# that points at the same sources. Three files need Apple frameworks and stay out,
# with their tests: BenchTranscriptDigest and WebSocketHandshake (CryptoKit) and
# ParentProcessWatchdog (a kqueue process source). The Mac lanes run everything.
#
#   ./scripts/speech-text-tests-linux.sh                    # every portable test
#   ./scripts/speech-text-tests-linux.sh --filter PauseGateTests
#
# SWIFT names the toolchain (default: `swift` on PATH, Swift 6.2).
# LV_LINUX_SPEECH_TEXT_DIR is the scratch package (default: .build/linux-speech-text).
set -euo pipefail

cd "$(dirname "$0")/.."
SWIFT="${SWIFT:-swift}"
PKG="${LV_LINUX_SPEECH_TEXT_DIR:-.build/linux-speech-text}"

mkdir -p "$PKG/Sources" "$PKG/Tests"
ln -sfn "$(realpath --relative-to="$PKG/Sources" SpeechHelper/Sources/SpeechEngineText)" \
    "$PKG/Sources/SpeechEngineText"
ln -sfn "$(realpath --relative-to="$PKG/Tests" SpeechHelper/Tests/SpeechEngineTextTests)" \
    "$PKG/Tests/SpeechEngineTextTests"
cat >"$PKG/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SpeechEngineTextLinux",
    targets: [
        .target(
            name: "SpeechEngineText",
            exclude: [
                "BenchTranscriptDigest.swift",
                "ParentProcessWatchdog.swift",
                "WebSocketHandshake.swift",
            ]
        ),
        .testTarget(
            name: "SpeechEngineTextTests",
            dependencies: ["SpeechEngineText"],
            exclude: [
                "BenchTranscriptDigestTests.swift",
                "ParentProcessWatchdogTests.swift",
            ]
        ),
    ]
)
MANIFEST

"$SWIFT" test --package-path "$PKG" "$@"
