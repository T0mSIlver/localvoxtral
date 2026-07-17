import Foundation
import XCTest

@testable import localvoxtral

/// Integration tests for the packaged MLX Swift speech helper
/// (`localvoxtral-speechd`): launch the xcodebuild-built binary from the app
/// bundle, drive real audio through the production realtime client, and prove
/// the append-only delta and parent-PID contracts against the real model.
///
/// Enablement (needs a Metal-capable Mac and a prior `package` run):
/// - env: SPEECHD_INTEGRATION_TEST_ENABLE=1, optional
///   SPEECHD_INTEGRATION_TEST_PATH / SPEECHD_INTEGRATION_TEST_MODEL
/// - marker file `.speechd-integration-enable.json` at the repo root, written
///   by `./scripts/remote-build.sh integration-speechd` because the SSH build
///   gate cannot pass per-command environment variables.
@MainActor
final class SpeechHelperIntegrationTests: XCTestCase {
    private static let enableEnv = "SPEECHD_INTEGRATION_TEST_ENABLE"
    private static let pathEnv = "SPEECHD_INTEGRATION_TEST_PATH"
    private static let modelEnv = "SPEECHD_INTEGRATION_TEST_MODEL"
    private static let markerFileName = ".speechd-integration-enable.json"
    private static let defaultHelperPath =
        "dist/localvoxtral.app/Contents/MacOS/localvoxtral-speechd"
    /// The same pinned managed model the app downloads and launches.
    private static let defaultModel = SpeechModelCatalog.defaultOption.repoID

    /// Dedicated integration-only port, intentionally outside the app's
    /// production speechd/polishd ports (8471/8472).
    private static let testPort: UInt16 = 18_471
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
                    Speech-helper integration tests are disabled.
                    Enable with \(Self.enableEnv)=1 (optional \(Self.pathEnv), \
                    \(Self.modelEnv)) or run \
                    ./scripts/remote-build.sh integration-speechd from the dev box
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
                Packaged speech helper missing at \(binary.path).
                Build it first: ./scripts/remote-build.sh package
                """
            )
            throw XCTSkip("packaged speech helper missing")
        }

        return (binary, model?.isEmpty == false ? model! : Self.defaultModel)
    }

    private struct ModelProvisioningError: Error, CustomStringConvertible {
        let description: String
    }

    /// The helper deliberately never downloads weights. Provision the exact
    /// managed revision in the shared Hugging Face cache before launching it,
    /// using the same file set as BackendManager's progress-reporting download.
    /// Failures are failures rather than skips because this suite is explicitly
    /// enabled and a green skip would conceal broken first-run infrastructure.
    private func ensureModelCached(_ repoID: String) async throws {
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let repoDir = cacheRoot.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        )
        let snapshotsDir = repoDir.appendingPathComponent("snapshots")
        let pinnedRevision = SpeechModelCatalog.option(forRepoID: repoID)?.revision

        if let pinnedRevision {
            if Self.snapshotIsProvisioned(snapshotsDir.appendingPathComponent(pinnedRevision)) {
                return
            }
        } else if let revision = try? String(
            contentsOf: repoDir.appendingPathComponent("refs/main"),
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty,
            Self.snapshotIsProvisioned(snapshotsDir.appendingPathComponent(revision))
        {
            return
        }

        print("speechd integration: downloading \(repoID) into \(cacheRoot.path)")
        struct RepoInfo: Decodable {
            struct Sibling: Decodable { let rfilename: String }
            let sha: String
            let siblings: [Sibling]
        }
        let apiURL = URL(
            string:
                "https://huggingface.co/api/models/\(repoID)/revision/\(pinnedRevision ?? "main")"
        )!
        let (infoData, infoResponse) = try await URLSession.shared.data(from: apiURL)
        guard (infoResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw ModelProvisioningError(
                description: "HF API unreachable for \(repoID): \(infoResponse)"
            )
        }
        let info = try JSONDecoder().decode(RepoInfo.self, from: infoData)
        if let pinnedRevision, info.sha != pinnedRevision {
            throw ModelProvisioningError(
                description:
                    "HF resolved \(repoID)@\(pinnedRevision) to sha \(info.sha) — pin is not a commit"
            )
        }

        let patterns = [
            "config.json", "tekken.json", "tokenizer*.json",
            "model*.safetensors", "model.safetensors.index.json",
        ]
        let wanted = info.siblings.map(\.rfilename).filter { name in
            patterns.contains { fnmatch($0, name, 0) == 0 }
        }
        guard !wanted.isEmpty else {
            throw ModelProvisioningError(description: "HF listing for \(repoID) matched no files")
        }

        let snapshotDir = snapshotsDir.appendingPathComponent(info.sha)
        try FileManager.default.createDirectory(
            at: snapshotDir, withIntermediateDirectories: true
        )
        for name in wanted {
            let destination = snapshotDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let source = URL(
                string: "https://huggingface.co/\(repoID)/resolve/\(info.sha)/\(name)"
            )!
            let (temporary, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ModelProvisioningError(description: "download failed for \(name): \(response)")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }

        if pinnedRevision == nil {
            let refsDir = repoDir.appendingPathComponent("refs")
            try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
            try Data("\(info.sha)\n".utf8).write(to: repoDir.appendingPathComponent("refs/main"))
        }
        try Data().write(to: snapshotDir.appendingPathComponent(Self.provisionedSentinel))
        print("speechd integration: model provisioned (\(wanted.count) files)")
    }

    static let provisionedSentinel = ".localvoxtral-provisioned"

    static func snapshotIsProvisioned(_ snapshot: URL) -> Bool {
        let fileManager = FileManager.default
        let hasRequiredMetadata = fileManager.fileExists(
            atPath: snapshot.appendingPathComponent(provisionedSentinel).path
        )
            && fileManager.fileExists(atPath: snapshot.appendingPathComponent("config.json").path)
            && fileManager.fileExists(atPath: snapshot.appendingPathComponent("tekken.json").path)
        guard hasRequiredMetadata else { return false }
        if fileManager.fileExists(atPath: snapshot.appendingPathComponent("model.safetensors").path) {
            return true
        }
        guard fileManager.fileExists(
            atPath: snapshot.appendingPathComponent("model.safetensors.index.json").path
        ) else { return false }
        let names = (try? fileManager.contentsOfDirectory(atPath: snapshot.path)) ?? []
        return names.contains { fnmatch("model-*-of-*.safetensors", $0, 0) == 0 }
    }

    func testSnapshotProvisioningSentinelAcceptsShardedCheckpoint() throws {
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechd-sharded-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: snapshot) }
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for name in [
            Self.provisionedSentinel,
            "config.json",
            "tekken.json",
            "model.safetensors.index.json",
            "model-00001-of-00002.safetensors",
            "model-00002-of-00002.safetensors",
        ] {
            try Data().write(to: snapshot.appendingPathComponent(name))
        }

        XCTAssertTrue(Self.snapshotIsProvisioned(snapshot))
    }

    func testSnapshotProvisioningSentinelRejectsIndexWithoutShard() throws {
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechd-incomplete-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: snapshot) }
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for name in [
            Self.provisionedSentinel,
            "config.json",
            "tekken.json",
            "model.safetensors.index.json",
        ] {
            try Data().write(to: snapshot.appendingPathComponent(name))
        }

        XCTAssertFalse(Self.snapshotIsProvisioned(snapshot))
    }

    private func launchHelper(
        binary: URL,
        model: String,
        extraArguments: [String] = []
    ) async throws -> (process: Process, stderrLog: LineLog) {
        let process = Process()
        process.executableURL = binary
        var arguments = [
            "--model", model,
            "--port", "\(Self.testPort)",
        ]
        if let revision = SpeechModelCatalog.option(forRepoID: model)?.revision {
            arguments.append(contentsOf: ["--model-revision", revision])
        }
        process.arguments = arguments + extraArguments

        let stderr = Pipe()
        process.standardError = stderr
        let readyOrExited = expectation(description: "speech helper ready or exited")
        readyOrExited.assertForOverFulfill = false
        let ready = LockedFlag()
        let stderrLog = LineLog()
        let readyLine = "ready on 127.0.0.1:\(Self.testPort)"
        let reader = PipeLineReader(fileHandle: stderr.fileHandleForReading) { line in
            stderrLog.append(line)
            if line.contains(readyLine), ready.set() {
                readyOrExited.fulfill()
            }
        }
        process.terminationHandler = { _ in readyOrExited.fulfill() }

        try process.run()
        reader.start()
        addTeardownBlock {
            await Self.reap(process)
        }

        await fulfillment(of: [readyOrExited], timeout: Self.readyTimeout)
        guard ready.value else {
            let status = process.isRunning
                ? "still running, no ready line after \(Int(Self.readyTimeout))s"
                : "exited with status \(process.terminationStatus)"
            XCTFail(
                """
                Speech helper failed to become ready (\(status)). stderr tail:
                \(stderrLog.tail(30))
                """
            )
            throw XCTSkip("speech helper did not become ready")
        }
        return (process, stderrLog)
    }

    private static func reap(_ process: Process) async {
        if process.isRunning {
            process.terminate()
        }
        let reaped = XCTestExpectation(description: "speech helper exited after SIGTERM")
        DispatchQueue.global().async {
            process.waitUntilExit()
            reaped.fulfill()
        }
        _ = await XCTWaiter.fulfillment(of: [reaped], timeout: 10)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    func testRealAudioMeetsAccuracyAndAppendOnlyDeltaContract() async throws {
        let (binary, model) = try helperConfiguration()
        try await ensureModelCached(model)
        let (process, _) = try await launchHelper(binary: binary, model: model)

        let healthURL = URL(string: "http://127.0.0.1:\(Self.testPort)/health")!
        let (_, healthResponse) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)

        // Identical phrase, TTS fixture format, chunk size, and scoring method
        // to RealtimeAPIVLLMIntegrationTests' tier-1 quality assertion.
        let expected = [
            "hello from localvoxtral realtime test.",
            "this is a longer synthetic audio passage for integration testing.",
            "we are verifying that the vllm realtime server performs generation and returns transcript text.",
            "the websocket client sends pcm sixteen audio at sixteen kilohertz in sequential chunks.",
            "if this transcript is non empty, end to end processing is confirmed.",
        ].joined(separator: " ")
        let pcm16 = try makeSpokenPCM16Data(phrase: expected)
        XCTAssertGreaterThan(pcm16.count, 100_000)
        let chunks = IntegrationTestSupport.splitPCM16IntoChunks(pcm16, chunkSizeBytes: 3_200)

        let client = RealtimeAPIWebSocketClient()
        let transcript = TranscriptCapture()
        let connected = expectation(description: "connected")
        let sessionReady = expectation(description: "session ready")
        let finalTranscript = expectation(description: "final transcript")
        finalTranscript.assertForOverFulfill = false
        let transcriptionFinalized = expectation(description: "transcription finalized")
        transcriptionFinalized.assertForOverFulfill = false
        let disconnected = expectation(description: "disconnected")
        let realtimeError = expectation(description: "realtime error")
        realtimeError.isInverted = true

        client.setEventHandler { event in
            switch event {
            case .connected:
                connected.fulfill()
                for chunk in chunks {
                    client.sendAudioChunk(chunk)
                }
                client.sendCommit(final: false)
                client.sendCommit(final: true)
            case .status(let message):
                if message.localizedCaseInsensitiveContains("session ready") {
                    sessionReady.fulfill()
                }
            case .partialTranscript(let delta):
                transcript.append(delta: delta)
            case .finalTranscript(let text):
                transcript.append(doneText: text)
                finalTranscript.fulfill()
            case .transcriptionFinalized:
                transcriptionFinalized.fulfill()
            case .error:
                realtimeError.fulfill()
            case .disconnected:
                disconnected.fulfill()
            }
        }

        let configuration = RealtimeSessionConfiguration(
            endpoint: URL(string: "ws://127.0.0.1:\(Self.testPort)/v1/realtime")!,
            apiKey: "",
            model: model
        )
        try client.connect(configuration: configuration)
        await fulfillment(
            of: [connected, sessionReady, finalTranscript, transcriptionFinalized],
            timeout: 180
        )

        client.disconnect()
        await fulfillment(of: [disconnected], timeout: 5)
        await fulfillment(of: [realtimeError], timeout: 0.2)

        let snapshot = transcript.snapshot()
        let doneText = try XCTUnwrap(snapshot.doneTexts.only)
        var accumulated = ""
        for delta in snapshot.deltas {
            XCTAssertFalse(
                delta.contains("\u{FFFD}"),
                "A provisional split UTF-8 replacement character escaped onto the wire"
            )
            accumulated += delta
            XCTAssertTrue(
                doneText.hasPrefix(accumulated),
                "Delta stream requires un-typing: \(accumulated.debugDescription) is not a done-text prefix"
            )
        }
        XCTAssertFalse(snapshot.deltas.isEmpty, "Real ASR emitted no transcript deltas")
        XCTAssertEqual(
            accumulated,
            doneText,
            "Concatenating every transcript.delta must exactly equal transcript.done"
        )

        let accuracy = IntegrationTestSupport.wordAccuracy(expected: expected, actual: doneText)
        print(
            "speechd integration: word accuracy \(String(format: "%.3f", accuracy)); "
                + "transcript: \(doneText)"
        )
        XCTAssertGreaterThanOrEqual(
            accuracy,
            0.55,
            "Expected synthetic-audio transcript accuracy >= 0.55. Transcript: \(doneText)"
        )
        XCTAssertTrue(process.isRunning)
        process.terminate()
    }

    func testHelperExitsWhenParentPIDDies() async throws {
        let (binary, model) = try helperConfiguration()
        try await ensureModelCached(model)

        let decoyParent = Process()
        decoyParent.executableURL = URL(fileURLWithPath: "/bin/cat")
        decoyParent.standardInput = Pipe()
        try decoyParent.run()
        addTeardownBlock {
            if decoyParent.isRunning {
                decoyParent.terminate()
            }
        }

        let (helper, _) = try await launchHelper(
            binary: binary,
            model: model,
            extraArguments: ["--parent-pid", "\(decoyParent.processIdentifier)"]
        )
        let helperExited = expectation(description: "speech helper exited after parent death")
        helper.terminationHandler = { _ in helperExited.fulfill() }

        decoyParent.terminate()
        await fulfillment(of: [helperExited], timeout: 30)
        XCTAssertFalse(helper.isRunning)
    }

    private func makeSpokenPCM16Data(phrase: String) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechd-tts-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", tempURL.path,
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            phrase,
        ]
        do {
            try process.run()
        } catch {
            throw XCTSkip("Failed to execute /usr/bin/say: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("System TTS failed with status \(process.terminationStatus)")
        }
        return try IntegrationTestSupport.extractPCMDataFromWAV(at: tempURL)
    }
}

private final class TranscriptCapture: @unchecked Sendable {
    struct Snapshot {
        let deltas: [String]
        let doneTexts: [String]
    }

    private let lock = NSLock()
    private var deltas: [String] = []
    private var doneTexts: [String] = []

    func append(delta: String) {
        lock.lock()
        deltas.append(delta)
        lock.unlock()
    }

    func append(doneText: String) {
        lock.lock()
        doneTexts.append(doneText)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(deltas: deltas, doneTexts: doneTexts)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !storage else { return false }
        storage = true
        return true
    }
}

private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func tail(_ count: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(count).joined(separator: "\n")
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
