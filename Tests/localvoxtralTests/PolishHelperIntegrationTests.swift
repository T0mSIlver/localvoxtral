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

    private struct ModelProvisioningError: Error, CustomStringConvertible {
        let description: String
    }

    /// The helper never downloads (missing model = hard error by design), so
    /// the suite provisions the shared HF cache itself when the model is
    /// absent — the same cache layout + include patterns as the app's
    /// HFModelDownloader, idempotent, ~0.9 GB once per build host/user.
    /// Provisioning failures are test FAILURES, not skips: this suite only
    /// runs when explicitly enabled, and a green skip would hide broken infra.
    private func ensureModelCached(_ repoID: String) async throws {
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let repoDir = cacheRoot.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        )
        let snapshotsDir = repoDir.appendingPathComponent("snapshots")

        // Completeness marker is refs/main, which is written LAST below (and
        // is what HFCacheModelLocator prefers). Keying on config.json alone
        // would let a cancelled half-download (config present, weights
        // missing) poison the cache into a permanently-failing suite.
        let mainRef = repoDir.appendingPathComponent("refs/main")
        if let revision = try? String(contentsOf: mainRef, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty,
            FileManager.default.fileExists(
                atPath: snapshotsDir.appendingPathComponent("\(revision)/config.json").path
            )
        {
            return
        }

        print("polishd integration: downloading \(repoID) into \(cacheRoot.path)")
        struct RepoInfo: Decodable {
            struct Sibling: Decodable { let rfilename: String }
            let sha: String
            let siblings: [Sibling]
        }
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repoID)/revision/main")!
        let (infoData, infoResponse) = try await URLSession.shared.data(from: apiURL)
        guard (infoResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw ModelProvisioningError(
                description: "HF API unreachable for \(repoID): \(infoResponse)"
            )
        }
        let info = try JSONDecoder().decode(RepoInfo.self, from: infoData)

        // Same include patterns as BackendManager.modelPreparationRequest.
        let patterns = [
            "*.json", "model*.safetensors", "*.py", "tokenizer.model",
            "*.tiktoken", "tiktoken.model", "*.txt", "*.jsonl", "*.jinja",
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

        let refsDir = repoDir.appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try Data("\(info.sha)\n".utf8).write(to: mainRef)
        print("polishd integration: model provisioned (\(wanted.count) files)")
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
    ) async throws -> (process: Process, port: UInt16, stderrLog: LineLog) {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--model", model, "--port", "0"] + extraArguments

        let stderr = Pipe()
        process.standardError = stderr
        // Fulfilled on the ready line OR on early exit, so a crashing helper
        // fails in seconds with its stderr instead of a 300 s silent timeout.
        let readyOrExited = expectation(description: "helper ready or exited")
        readyOrExited.assertForOverFulfill = false
        let portBox = PortBox()
        let stderrLog = LineLog()
        let reader = PipeLineReader(fileHandle: stderr.fileHandleForReading) { line in
            stderrLog.append(line)
            if let range = line.range(of: "ready on 127.0.0.1:"),
               let port = UInt16(line[range.upperBound...].prefix(while: \.isNumber))
            {
                if portBox.set(port) {
                    readyOrExited.fulfill()
                }
            }
        }
        process.terminationHandler = { _ in readyOrExited.fulfill() }

        try process.run()
        reader.start()
        addTeardownBlock {
            await Self.reap(process)
        }

        await fulfillment(of: [readyOrExited], timeout: Self.readyTimeout)
        guard let port = portBox.get() else {
            let status = process.isRunning
                ? "still running, no ready line after \(Int(Self.readyTimeout))s"
                : "exited with status \(process.terminationStatus)"
            XCTFail(
                """
                Helper failed to become ready (\(status)). stderr tail:
                \(stderrLog.tail(30))
                """
            )
            throw XCTSkip("helper did not become ready")
        }
        return (process, port, stderrLog)
    }

    /// Reap, don't just signal: SIGTERM is asynchronous, so `terminate()`
    /// alone lets the caller move on while the helper is still dying — in
    /// teardown that costs the CI runner ~105 s of orphan cleanup (#111),
    /// and between back-to-back launches it would briefly keep TWO copies
    /// of the model in memory on the shared runner. Wait for the exit
    /// (bounded), and escalate to SIGKILL if it never comes. Idempotent for
    /// an already-exited process.
    private static func reap(_ process: Process) async {
        if process.isRunning {
            process.terminate()
        }
        let reaped = XCTestExpectation(description: "helper exited after SIGTERM")
        DispatchQueue.global().async {
            process.waitUntilExit()  // returns immediately if already exited
            reaped.fulfill()
        }
        _ = await XCTWaiter.fulfillment(of: [reaped], timeout: 10)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
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

        func countOfLines(containing substring: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return lines.count { $0.contains(substring) }
        }
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
        try await ensureModelCached(model)
        let (process, port, stderrLog) = try await launchHelper(binary: binary, model: model)

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (_, healthResponse) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)

        // Mirror production: SettingsStore attaches the catalog entry's
        // sampling defaults and chat-template kwargs for the managed model.
        let option = PolishModelCatalog.option(forRepoID: model)
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            apiKey: "",
            model: model,
            samplingDefaults: option?.samplingDefaults,
            chatTemplateArguments: option?.chatTemplateArguments
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

        // The prompt-prefix cache must actually engage: every eval request
        // shares [system, instructions] and varies only the transcript
        // message, so the first request checkpoints the prefix and the rest
        // reuse it. A "full prefill" fallback line would mean the template
        // boundary math broke and the cache silently turned itself off —
        // fail loudly instead of shipping the perf regression.
        XCTAssertEqual(
            stderrLog.countOfLines(containing: "prompt cache: checkpointed"), 1,
            "expected exactly one prefix checkpoint across the eval corpus"
        )
        XCTAssertGreaterThan(
            stderrLog.countOfLines(containing: "prompt cache: hit"), 0,
            "no request reused the prefix checkpoint"
        )
        XCTAssertEqual(
            stderrLog.countOfLines(containing: "full prefill"), 0,
            "prefix cache fell back to full prefill — templated prefix no longer a token prefix"
        )

        XCTAssertTrue(process.isRunning)
        process.terminate()
    }

    /// Regression-style demonstration for the app-side prompt-prefix warmup:
    /// two cold helper launches — one where the first real polish pays the
    /// full static-prefix prefill, one where the app's exact warmup request
    /// (`PolishPromptWarmup.request`, max_tokens=1) lands first. Asserts the
    /// BEHAVIOR (the warmup checkpoints the prefix; the first real polish is
    /// then a cache hit, zero full-prefill fallbacks, identical output) and
    /// prints the measured latencies informationally — no timing assertions
    /// (no-wall-clock rule).
    func testAppWarmupRequestPrimesPromptCacheForFirstRealPolish() async throws {
        let (binary, model) = try helperConfiguration()
        try await ensureModelCached(model)
        let option = PolishModelCatalog.option(forRepoID: model)
        let (templates, cleanup) = try LLMPolishEvalSupport.defaultPromptTemplates()
        addTeardownBlock { cleanup() }
        let service = LLMPolishingService()

        // A required eval case: its polished output is deterministic and
        // stable, so the cold and warmed runs must agree on it.
        let transcript = "Are you coming to the meeting tomorrow ?"
        let expectedNormalized = LLMPolishEvalSupport.normalized(
            "Are you coming to the meeting tomorrow?"
        )
        func configuration(port: UInt16) -> LLMPolishingConfiguration {
            LLMPolishingConfiguration(
                endpointURL: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
                apiKey: "",
                model: model,
                samplingDefaults: option?.samplingDefaults,
                chatTemplateArguments: option?.chatTemplateArguments
            )
        }
        let realPolishRequest = LLMPolishingRequest(
            inputText: transcript,
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(
                inputText: transcript,
                replacementDictionary: ""
            )
        )

        // Baseline: cold helper, the first real polish pays the full prefill.
        let cold = try await launchHelper(binary: binary, model: model)
        let coldResult = try await service.polish(
            request: realPolishRequest,
            configuration: configuration(port: cold.port)
        )
        // Reap the cold helper BEFORE launching the second one: terminate()
        // is only an asynchronous SIGTERM, and overlapping two helpers would
        // briefly double the model's memory on the shared runner (~2x 4 GB
        // with the 4B) — same reap-don't-signal rule as teardown (#111).
        await Self.reap(cold.process)

        // Warmed: cold helper again, the app's warmup request lands first.
        let warmed = try await launchHelper(binary: binary, model: model)
        let warmupRequest = PolishPromptWarmup.request(templates: templates)
        var warmupDuration = Double.nan
        do {
            warmupDuration = try await service.polish(
                request: warmupRequest,
                configuration: configuration(port: warmed.port)
            ).durationSeconds
        } catch LLMPolishingError.invalidResponse {
            // A 1-token generation can trim to an empty response; the
            // checkpoint exists server-side either way and the assertions
            // below prove it (the production warmup is log-only too).
        }
        let warmResult = try await service.polish(
            request: realPolishRequest,
            configuration: configuration(port: warmed.port)
        )
        // Worst-case serialization cost for a real polish that lands behind
        // an in-flight warmup: the warmup's post-checkpoint work, measured
        // here as a second warmup request against the warm cache.
        let queuedWarmupDuration = try? await service.polish(
            request: warmupRequest,
            configuration: configuration(port: warmed.port)
        ).durationSeconds

        // Warmup checkpointed the prefix once; the first real polish reused
        // it instead of re-checkpointing, and nothing fell back to a full
        // prefill in either launch.
        XCTAssertEqual(
            warmed.stderrLog.countOfLines(containing: "prompt cache: checkpointed"), 1,
            "expected exactly one checkpoint (the warmup's) across the warmed launch"
        )
        XCTAssertGreaterThan(
            warmed.stderrLog.countOfLines(containing: "prompt cache: hit"), 0,
            "the first real polish after warmup did not reuse the warmed prefix"
        )
        XCTAssertEqual(warmed.stderrLog.countOfLines(containing: "full prefill"), 0)
        XCTAssertEqual(cold.stderrLog.countOfLines(containing: "full prefill"), 0)

        // Cache reuse must not change polish output.
        XCTAssertEqual(LLMPolishEvalSupport.normalized(coldResult.polishedText), expectedNormalized)
        XCTAssertEqual(LLMPolishEvalSupport.normalized(warmResult.polishedText), expectedNormalized)

        print(
            """
            == polishd prompt-prefix warmup: first-polish latency (model: \(model)) ==
            without warmup (cold cache):            \(String(format: "%.3f", coldResult.durationSeconds))s
            warmup request itself (cold cache):     \(String(format: "%.3f", warmupDuration))s
            first real polish after warmup:         \(String(format: "%.3f", warmResult.durationSeconds))s
            worst-case queue-behind-warmup (proxy): \(String(format: "%.3f", queuedWarmupDuration ?? .nan))s
            """
        )
        warmed.process.terminate()
    }

    /// EXPERIMENT (2026-07-09, print-only — no score assertions): run the
    /// same corpus with the Qwen3.5 model card's recommended non-thinking
    /// text sampling (temperature 1.0, top_p 1.0, top_k 20, min_p 0,
    /// presence_penalty 2.0) instead of the production temperature-0.3
    /// request, to test the hypothesis that the recommended set — tuned for
    /// open-ended generation — hurts a copy-editing task where the output
    /// should mostly repeat the input (presence_penalty penalizes exactly
    /// that repetition). Compare this scoreboard against the baseline test's.
    func testEvalScoreboardWithQwenRecommendedSampling() async throws {
        let (binary, model) = try helperConfiguration()
        try await ensureModelCached(model)
        let (process, port, _) = try await launchHelper(binary: binary, model: model)

        // Catalog chat-template kwargs still apply (the experiment varies
        // sampling only, not templating).
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
            apiKey: "",
            model: model,
            chatTemplateArguments: PolishModelCatalog.option(forRepoID: model)?.chatTemplateArguments
        )
        let (templates, cleanup) = try LLMPolishEvalSupport.defaultPromptTemplates()
        addTeardownBlock { cleanup() }

        let result = await LLMPolishEvalSupport.runScoreboard(
            service: QwenRecommendedSamplingPolishingService(),
            templates: templates,
            configuration: configuration
        )
        LLMPolishEvalSupport.printScoreboard(
            result,
            configuration: configuration,
            header: "polishd EXPERIMENT: Qwen recommended non-thinking sampling (temp 1.0, top_k 20, presence 2.0)"
        )

        XCTAssertTrue(process.isRunning)
        process.terminate()
    }

    /// The memory-contract proof: when the process that passed --parent-pid
    /// dies, the helper exits on its own (freeing all model memory), exactly
    /// like the old fork's Python watchdog.
    func testHelperExitsWhenParentPIDDies() async throws {
        let (binary, model) = try helperConfiguration()
        try await ensureModelCached(model)

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

        let (helper, _, _) = try await launchHelper(
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

/// The production request with the sampling fields swapped for the Qwen3.5
/// model card's recommended non-thinking text values. Request/response
/// handling mirrors `LLMPolishingService.polish`.
private struct QwenRecommendedSamplingPolishingService: LLMPolishingServicing {
    func polish(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        var urlRequest = URLRequest(url: configuration.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 60

        let messages = [["role": "system", "content": request.systemPrompt]]
            + request.userPrompts.map { ["role": "user", "content": $0] }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "temperature": 1.0,
            "top_p": 1.0,
            "top_k": 20,
            "min_p": 0.0,
            "presence_penalty": 2.0,
        ]
        if let chatTemplateArguments = configuration.chatTemplateArguments {
            body["chat_template_kwargs"] = chatTemplateArguments
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw LLMPolishingError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(decoding: data.prefix(500), as: UTF8.self)
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMPolishingError.invalidResponse
        }

        return LLMPolishingResult(
            rawText: request.inputText,
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
            durationSeconds: 0
        )
    }
}
