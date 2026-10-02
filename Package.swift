// swift-tools-version: 6.2

import PackageDescription
import Foundation

/// The e2e test harness: the control socket (`DogfoodControlSocket`) and the
/// WAV file that stands in for the microphone (`DogfoodAudioFileSource`).
/// Source gates it as `#if DEBUG || LOCALVOXTRAL_E2E_HARNESS`, so the unit
/// tests build it and a release build contains neither unless the UI smoke
/// workflow asks with `LOCALVOXTRAL_E2E_HARNESS=1`. `package_app.sh` stamps
/// such a bundle and checks every binary against its stamp
/// (`scripts/packaging/check-harness-symbols.sh`).
let harnessSwiftSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["LOCALVOXTRAL_E2E_HARNESS"] == "1"
    ? [.define("LOCALVOXTRAL_E2E_HARNESS")] : []

/// The widget extension's App Intents need metadata that only Xcode's build
/// asks the compiler for: the const values `appintentsmetadataprocessor`
/// reads. `scripts/packaging/package-widgets.sh` sets this variable to the
/// output path for its one release build; every other build leaves it unset.
let widgetConstValuesPath = ProcessInfo.processInfo.environment["LOCALVOXTRAL_WIDGET_CONST_VALUES"]
let widgetConstProtocolsPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("scripts/packaging/app-intents-const-protocols.json").path
let widgetSwiftSettings: [SwiftSetting] = widgetConstValuesPath.map {
    [.unsafeFlags([
        "-emit-const-values-path", $0,
        "-Xfrontend", "-const-gather-protocols-file",
        "-Xfrontend", widgetConstProtocolsPath,
    ])]
} ?? []

/// Everything but the app and its suite, which need AppKit and are declared on
/// macOS only below. On Linux, `scripts/core-tests-linux.sh` builds the test
/// product and runs the core's tests.
var products: [Product] = [
    // The Claude Code hook publisher. Dependency-free (Foundation +
    // Darwin/Glibc) so it builds for the remote Linux hosts Claude Code runs
    // on; scripts/core-tests-linux.sh builds it there.
    .executable(name: "localvoxtral-claude-hook", targets: ["localvoxtral-claude-hook"]),
    // The `localvoxtral` command (#721): Foundation only, like the hook
    // publisher, whose socket client it reuses.
    .executable(name: "localvoxtral-cli", targets: ["localvoxtral-cli"]),
]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
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
    // The `localvoxtral` command's arguments, request and output; the
    // binary's main is a few lines around it.
    .target(
        name: "LocalvoxtralCLICore",
        dependencies: ["ClaudeContextWire", "ClaudeHookPublisherCore"]
    ),
    .executableTarget(
        name: "localvoxtral-cli",
        dependencies: ["LocalvoxtralCLICore", "ClaudeContextWire", "ClaudeHookPublisherCore"]
    ),
    // What the app computes without AppKit: the transcript merge, the text
    // merging algorithms, the polish token guard, the payload macro, the
    // polish-outcome and connection-failure classifiers, the session clock
    // (#432 step 9), and the Claude session snapshot, which is why it depends
    // on the wire contract. The app re-exports it.
    // Built with the harness define too, so `#if LOCALVOXTRAL_E2E_HARNESS`
    // means the same thing in code that moves here from the app (#591).
    .target(
        name: "localvoxtralCore",
        dependencies: ["ClaudeContextWire"],
        swiftSettings: harnessSwiftSettings
    ),
    // The hook publisher and its Linux process-table reader; runs on both
    // platforms.
    .testTarget(
        name: "ClaudeHookPublisherCoreTests",
        dependencies: ["ClaudeHookPublisherCore", "ClaudeContextWire"]
    ),
    // The wire contract's own tests: what the hook publisher sends and the
    // app's broker and remote listener accept.
    .testTarget(
        name: "ClaudeContextWireTests",
        dependencies: ["ClaudeContextWire"]
    ),
    // Test doubles that need only the core, shared by the core's suite and
    // the app's (#616). A library, because test targets can't depend on each
    // other.
    .target(
        name: "localvoxtralTestSupport",
        dependencies: ["localvoxtralCore", "ClaudeContextWire", "localvoxtralTestSupportSignals"],
        path: "Tests/localvoxtralTestSupport"
    ),
    // Makes a Linux test process ignore SIGPIPE when it loads. C, for the
    // constructor.
    .target(
        name: "localvoxtralTestSupportSignals",
        path: "Tests/localvoxtralTestSupportSignals"
    ),
    .testTarget(
        name: "localvoxtralCoreTests",
        dependencies: [
            "localvoxtralCore",
            "ClaudeContextWire",
            // The broker and Vibe suites drive the real hook publisher.
            "ClaudeHookPublisherCore",
            // The CLI suite drives the command against a real broker.
            "LocalvoxtralCLICore",
            "localvoxtralTestSupport",
        ],
        swiftSettings: harnessSwiftSettings
    ),
]

#if os(macOS)
products.insert(.executable(name: "localvoxtral", targets: ["localvoxtral"]), at: 0)
// The WidgetKit extension (#630); `scripts/packaging/package-widgets.sh`
// wraps it into Contents/PlugIns.
products.append(.executable(name: "localvoxtral-widgets", targets: ["localvoxtralWidgets"]))
dependencies.append(.package(url: "https://github.com/Kentzo/ShortcutRecorder.git", from: "3.4.0"))
targets += [
    // The desktop widgets' SwiftUI views, apart from the extension so the
    // view snapshot tests can render them.
    .target(name: "localvoxtralWidgetUI", dependencies: ["localvoxtralCore"]),
    .executableTarget(
        name: "localvoxtralWidgets",
        dependencies: ["localvoxtralWidgetUI", "localvoxtralCore"],
        swiftSettings: widgetSwiftSettings
    ),
    .executableTarget(
        name: "localvoxtral",
        dependencies: [
            .product(name: "ShortcutRecorder", package: "ShortcutRecorder"),
            "ClaudeContextWire",
            "localvoxtralCore",
        ],
        // Colocated agent-guide markdown, not a bundle resource.
        exclude: [
            "ClaudeContext/AGENTS.md"
        ],
        resources: [
            .process("Resources"),
        ],
        swiftSettings: harnessSwiftSettings
    ),
    .testTarget(
        name: "localvoxtralTests",
        dependencies: [
            "localvoxtral",
            "localvoxtralCore",
            "ClaudeContextWire",
            "ClaudeHookPublisherCore",
            "localvoxtralTestSupport",
            "localvoxtralWidgetUI",
        ],
        // Golden fixtures are read through `#filePath`, not the bundle.
        exclude: ["Fixtures"],
        swiftSettings: harnessSwiftSettings
    ),
]
#endif

let package = Package(
    name: "localvoxtral",
    platforms: [
        .macOS(.v15),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
