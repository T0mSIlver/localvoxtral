// swift-tools-version: 6.2

import PackageDescription
import Foundation

/// Opt-in dogfooding instrumentation (`Sources/localvoxtral/Dogfood`), compiled
/// ONLY when the environment asks for it: `LOCALVOXTRAL_DOGFOOD=1 swift build`.
///
/// It is a compile gate rather than a settings-only feature on purpose. The
/// capture writes repository contents, terminal screen text, clipboard text, and
/// fully rendered prompts to disk — exactly the material the shipped app refuses
/// to log. Keeping it out of the released binary makes "this build cannot record
/// your context" a property of the artifact instead of a promise about a
/// default, and leaves the README's privacy section literally true.
///
/// Inside such a build the capture is still off until the runtime opt-in is
/// armed. Two locks, and the outer one is not a checkbox.
/// Enablement travels EITHER as the environment variable (local builds, CI)
/// OR as a gitignored marker file in the package root — the same dual form the
/// LLM eval lanes use, and for the same reason: the Mac build gate allowlists
/// exact `swift test …` payloads, so an env prefix cannot cross the SSH
/// boundary. `remote-build.sh dogfood` writes the marker, syncs, and removes it
/// again on exit.
///
/// The marker cannot leak into a release: `release.yml` builds from a clean
/// checkout, the file is gitignored, and `package_app.sh` prints which mode it
/// built in and stamps `LVXDogfoodCapture` into the bundle's Info.plist.
let dogfoodMarkerURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent(".dogfood-capture-enable")
let dogfoodCaptureEnabled =
    ProcessInfo.processInfo.environment["LOCALVOXTRAL_DOGFOOD"] == "1"
    || FileManager.default.fileExists(atPath: dogfoodMarkerURL.path)
let dogfoodSwiftSettings: [SwiftSetting] =
    dogfoodCaptureEnabled ? [.define("LOCALVOXTRAL_DOGFOOD")] : []

/// Everything but the app and its suite, which need AppKit and are declared on
/// macOS only below. On Linux, `scripts/core-tests-linux.sh` builds the test
/// product and runs the core's tests.
var products: [Product] = [
    // The Claude Code hook publisher. Dependency-free (Foundation +
    // Darwin/Glibc), meant to build for a remote Linux host too; with Swift
    // 6.2 ClaudeHookPublisherCore does not compile there (Darwin-only
    // sysctl/kinfo_proc/devname), which is why the Linux script builds only
    // the test product.
    .executable(name: "localvoxtral-claude-hook", targets: ["localvoxtral-claude-hook"]),
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
    // What the app computes without AppKit: the transcript merge, the text
    // merging algorithms, the polish token guard, the payload macro, the
    // polish-outcome and connection-failure classifiers, the session clock
    // (#432 step 9). The app re-exports it.
    .target(name: "localvoxtralCore"),
    .testTarget(
        name: "localvoxtralCoreTests",
        dependencies: ["localvoxtralCore"]
    ),
]

#if os(macOS)
products.insert(.executable(name: "localvoxtral", targets: ["localvoxtral"]), at: 0)
dependencies.append(.package(url: "https://github.com/Kentzo/ShortcutRecorder.git", from: "3.4.0"))
targets += [
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
        swiftSettings: dogfoodSwiftSettings
    ),
    .testTarget(
        name: "localvoxtralTests",
        dependencies: [
            "localvoxtral",
            "localvoxtralCore",
            "ClaudeContextWire",
            "ClaudeHookPublisherCore",
        ],
        // Golden fixtures are read through `#filePath`, not the bundle.
        exclude: ["Fixtures"],
        swiftSettings: dogfoodSwiftSettings
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
