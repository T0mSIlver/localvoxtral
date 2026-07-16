// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "localvoxtral",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "localvoxtral", targets: ["localvoxtral"]),
        // The Claude Code hook publisher. Dependency-free (Foundation +
        // Darwin/Glibc) so the same source builds for a remote Linux host.
        .executable(name: "localvoxtral-claude-hook", targets: ["localvoxtral-claude-hook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Kentzo/ShortcutRecorder.git", from: "3.4.0"),
    ],
    targets: [
        // Wire contract shared by the app's broker and the hook publisher.
        // Foundation only — it must compile on Linux for a remote publisher.
        .target(name: "ClaudeContextWire"),
        .target(
            name: "ClaudeHookPublisherCore",
            dependencies: ["ClaudeContextWire"]
        ),
        // Thin main; all logic lives in the Core library so it is testable.
        // Named for the binary: SwiftPM names the built executable after the
        // TARGET, not the product (cf. PolishHelper's localvoxtral-polishd).
        .executableTarget(
            name: "localvoxtral-claude-hook",
            dependencies: ["ClaudeHookPublisherCore", "ClaudeContextWire"]
        ),
        .executableTarget(
            name: "localvoxtral",
            dependencies: [
                .product(name: "ShortcutRecorder", package: "ShortcutRecorder"),
                "ClaudeContextWire",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "localvoxtralTests",
            dependencies: [
                "localvoxtral",
                "ClaudeContextWire",
                "ClaudeHookPublisherCore",
            ]
        ),
    ]
)
