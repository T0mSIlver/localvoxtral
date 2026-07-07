import Foundation
import XCTest

@testable import localvoxtral

/// Integration tests for the bundled MLX Swift polishing helper
/// (localvoxtral-polishd): spawn the real xcodebuild-built binary with the
/// real pinned model, drive it through the production `LLMPolishingService`,
/// and hold it to the same eval baseline as the old mlx-lm server
/// (`LLMPolishEvalSupport`). Also proves the parent-PID tether end to end.
///
/// Enablement (needs a Metal-capable Mac with the model in the HF cache and
/// a helper binary from `./scripts/remote-build.sh package`):
/// - env: LOCALVOXTRAL_POLISHD_TEST_ENABLE=1, optional
///   LOCALVOXTRAL_POLISHD_TEST_PATH / LOCALVOXTRAL_POLISHD_TEST_MODEL
/// - marker file `.polishd-integration-enable.json` at the repo root,
///   written by `./scripts/remote-build.sh integration-polishd` (the build
///   gate pins env prefixes per-command, so enablement travels in the tree).
@MainActor
final class PolishHelperIntegrationTests: XCTestCase {
    private static let enableEnv = "LOCALVOXTRAL_POLISHD_TEST_ENABLE"
    private static let pathEnv = "LOCALVOXTRAL_POLISHD_TEST_PATH"
    private static let modelEnv = "LOCALVOXTRAL_POLISHD_TEST_MODEL"
    private static let markerFileName = ".polishd-integration-enable.json"
    private static let defaultHelperPath =
        "PolishHelper/.build/xcode/Build/Products/Release/localvoxtral-polishd"

    /// Generous because the first request after a cold Metal JIT cache can
    /// pay kernel-compilation time on top of model load.
    private static let readyTimeout: TimeInterval = 300

    private struct MarkerConfig: Decodable {
        let helperPath: String?
        let model: String?
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // localvoxtralTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func helperConfiguration() throws -> (binary: URL, model: String) {
        let env = ProcessInfo.processInfo.environment
        var helperPath: String?
        var model: String?

        if env[Self.enableEnv] == "1" {
            helperPath = env[Self.pathEnv]
            model = env[Self.modelEnv]
        } else {
            let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
            guard FileManager.default.fileExists(atPath: markerURL.path) else {
                throw XCTSkip(
                    """
                    Polishing-helper integration tests are disabled.
                    Enable with \(Self.enableEnv)=1 (optional \(Self.pathEnv), \
                    \(Self.modelEnv)) or run \
                    ./scripts/remote-build.sh integration-polishd from the dev box
                    (after a `package` run has built the helper).
                    """
                )
            }
            let marker = try JSONDecoder().decode(
                MarkerConfig.self,
                from: Data(contentsOf: markerURL)
            )
            helperPath = marker.helperPath
            model = marker.model
        }

        let resolvedPath = helperPath?.isEmpty == false ? helperPath! : Self.defaultHelperPath
        let binary = resolvedPath.hasPrefix("/")
            ? URL(fileURLWithPath: resolvedPath)
            : repoRoot.appendingPathComponent(resolvedPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail(
                """
                Helper binary missing at \(binary.path).
                Build it first: ./scripts/remote-build.sh package
                """
            )
            throw XCTSkip("helper binary missing")
        }
        return (binary, model?.isEmpty == false ? model! : SettingsStore.defaultLLMPolishingModel)
    }

    /// Spawns the helper and waits for its stderr readiness line
    /// ("ready on 127.0.0.1:<port>"), which carries the ephemeral port when
    /// launched with --port 0. Event-driven via the same descriptor-safe
    /// PipeLineReader the app's installer uses (never
    /// FileHandle.availableData — PR #60).
    private func launchHelper(
        binary: URL,
        model: String,
        extraArguments: [String] = []
    ) throws -> (process: Process, port: UInt16) {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--model", model, "--port", "0"] + extraArguments

        let stderr = Pipe()
        process.standardError = stderr
        let ready = expectation(description: "helper reported ready")
        let portBox = PortBox()
        let reader = PipeLineReader(fileHandle: stderr.fileHandleForReading) { line in
            if let range = line.range(of: "ready on 127.0.0.1:"),
               let port = UInt16(line[range.upperBound...].prefix(while: \.isNumber))
            {
                if portBox.set(port) {
                    ready.fulfill()
                }
            }
        }

        try process.run()
        reader.start()
        addTeardownBlock {
            if process.isRunning {
                process.terminate()
            }
        }

        wait(for: [ready], timeout: Self.readyTimeout)
        guard let port = portBox.get() else {
            throw XCTSkip("helper never reported a port")
        }
        return (process, port)
    }

    private final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var port: UInt16?

        func set(_ value: UInt16) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard port == nil else { return false }
            port = value
            return true
        }

        func get() -> UInt16? {
            lock.lock()
            defer { lock.unlock() }
            return port
        }
    }

    /// The parity proof: /health answers, and the production polish request
    /// path scores the SAME eval corpus the mlx-lm server was held to. A
    /// required-case failure here means the engine swap changed polish
    /// behavior — investigate before shipping, do not relax the corpus.
    func testHelperMatchesPolishEvalBaselineThroughProductionRequestPath() async throws {
        let (binary, model) = try helperConfiguration()
        let (process, port) = try launchHelper(binary: binary, model: model)

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (_, healthResponse) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)

        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            apiKey: "",
            model: model
        )
        let (templates, cleanup) = try LLMPolishEvalSupport.defaultPromptTemplates()
        addTeardownBlock { cleanup() }

        let result = await LLMPolishEvalSupport.runScoreboard(
            service: LLMPolishingService(),
            templates: templates,
            configuration: configuration
        )
        LLMPolishEvalSupport.printScoreboard(
            result,
            configuration: configuration,
            header: "polishd (bundled MLX Swift helper) eval"
        )

        XCTAssertTrue(
            result.failedRequiredCases.isEmpty,
            "Bundled helper regressed required polish cases vs the mlx-lm baseline: \(result.failedRequiredCases.joined(separator: ", "))"
        )

        XCTAssertTrue(process.isRunning)
        process.terminate()
    }

    /// The memory-contract proof: when the process that passed --parent-pid
    /// dies, the helper exits on its own (freeing all model memory), exactly
    /// like the old fork's Python watchdog.
    func testHelperExitsWhenParentPIDDies() async throws {
        let (binary, model) = try helperConfiguration()

        // A stand-in "app" process the test fully controls: /bin/cat with an
        // open stdin pipe blocks until terminated.
        let decoyParent = Process()
        decoyParent.executableURL = URL(fileURLWithPath: "/bin/cat")
        decoyParent.standardInput = Pipe()
        try decoyParent.run()
        addTeardownBlock {
            if decoyParent.isRunning {
                decoyParent.terminate()
            }
        }

        let (helper, _) = try launchHelper(
            binary: binary,
            model: model,
            extraArguments: ["--parent-pid", "\(decoyParent.processIdentifier)"]
        )

        let helperExited = expectation(description: "helper exited after parent death")
        helper.terminationHandler = { _ in helperExited.fulfill() }

        decoyParent.terminate()
        await fulfillment(of: [helperExited], timeout: 30)
        XCTAssertFalse(helper.isRunning)
    }
}
