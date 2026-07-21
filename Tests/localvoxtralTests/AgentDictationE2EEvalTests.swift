import AppKit
import Darwin
import Foundation
import XCTest

@testable import localvoxtral

/// The agent-dictation END-TO-END eval (Phase 2 of the eval effort — the
/// corpus and its contract are Phase 1, `EvalCorpus/agent-dictation/`):
///
///   recorded human WAV OR TTS(spokenForm, /usr/bin/say)
///     -> production websocket ASR (speechd STT service)
///     -> production polish stop-commit path (bundled polishd helper or an
///        explicitly selected OpenAI-compatible endpoint)
///     -> corpus-contract scoring -> scoreboard
///
/// What each stage exercises (documented per the Phase-2 contract):
/// - ASR: the production `RealtimeAPIWebSocketClient` against a live speechd STT
///   service (same chunking + final-transcript assembly as the tier-1 integration
///   suite). The live-session transcript MERGE (DictationViewModel+
///   RealtimeEvents overlap merge) is NOT in the loop — finals are joined
///   directly; a Phase-3 candidate.
/// - Polish: the REAL `DictationViewModel.finishStoppedSession` stop-commit
///   path on a view model built with `startRuntimeServices: false` —
///   replacement dictionary -> clipboard-paste macro -> profile selection ->
///   clipboard context -> repo vocabulary -> `LLMPolishingRequest` ->
///   raw model output -> explicit paste-placeholder integrity/substitution ->
///   commit.
///   Prompt templates load through the production `AppConfigStore`
///   (configDirectoryOverride seeded with the bundled files). Existing DEBUG
///   seams only: target-bundle override (profile routing), pasteboard stubs
///   (never the runner's real pasteboard), and the repo-vocabulary PIPELINE
///   seam, which still runs the production title -> cwd -> git-index -> match
///   pipeline against a real git-inited fixture repo (only the AX window-title
///   read is replaced). The polish service wrapper forwards to the production
///   `LLMPolishingService` with the catalog-aware configuration production's
///   managed mode builds (`SettingsStore.llmPolishingConfiguration` managed
///   branch) — only the port differs (ephemeral helper port, never 8472, so a
///   running app instance can't collide). No new seams were added.
///
/// Eval policy (owner, 2026-07-11 — non-negotiable): nightly + manual, never
/// per-PR; `required` cases asserted individually (currently the 7 migrated
/// punctuation cases, all polish-only); everything else XFAIL; WER
/// informational; no probabilistic pass bars. Phase 3 calibration promotes
/// cross-server-state-stable cases to required.
///
/// Enablement (never in tier 0 — also skipped via UNIT_TEST_SKIPS in
/// remote-build.sh):
/// - env: LV_AGENT_EVAL_E2E_ENABLE=1 (optional LV_AGENT_EVAL_E2E_HELPER_PATH,
///   LV_AGENT_EVAL_E2E_VOXMLX_ENDPOINT, LV_AGENT_EVAL_E2E_ASR_MODEL,
///   LV_AGENT_EVAL_E2E_POLISH_MODEL), used by eval-e2e.yml
///   LV_AGENT_EVAL_E2E_RECORDING_DIRECTORY selects a strict human recording
///   set; every speech-running case must be present and corpus-current unless
///   LV_AGENT_EVAL_E2E_RECORDING_SUBSET=1 explicitly selects an exploratory
///   partial-set run. LV_AGENT_EVAL_E2E_POLISH_ENDPOINT bypasses the bundled
///   helper while preserving the production Qwen 4B sampling/template shape.
/// - marker file `.agent-eval-e2e-enable.json` at the repo root, written by
///   `./scripts/remote-build.sh eval-e2e` (the SSH gate can't pass env, so
///   enablement rides the rsynced tree — the PolishHelperIntegrationTests
///   pattern)
///
/// Synthesized WAVs are cached under
/// `~/Library/Caches/localvoxtral-eval/wav/<sha256(text|voice|format)>.wav`
/// — nothing committed to the repo; a rerun over an unchanged corpus skips
/// `say` entirely.
@MainActor
final class AgentDictationE2EEvalTests: XCTestCase {
    private typealias Support = AgentDictationE2EEvalSupport

    // DictationViewModel owns app-lifetime services; retain instances for the
    // process lifetime (the token-guard suite pattern).
    private static var retainedViewModels: [DictationViewModel] = []

    /// Generous: the first request after a cold Metal JIT cache can pay
    /// kernel-compilation time on top of model load.
    private static let helperReadyTimeout: TimeInterval = 300
    private static let asrTimeout: TimeInterval = 90
    /// Per-case stop-commit deadline: live 4B inference, possibly behind a
    /// profile-prefix prefill.
    private static let polishCommitDeadline: Duration = .seconds(240)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    // MARK: - The eval

    func testAgentDictationE2EEvalScoreboard() async throws {
        let enablement = try resolveEnablementOrSkip()
        let binary: URL?
        if enablement.polishEndpoint == nil {
            binary = try resolveHelperBinary(enablement.helperPath)
        } else {
            binary = nil
        }
        let strata = try AgentDictationEvalCorpus.loadStrata()
        let fixtures = try AgentDictationEvalCorpus.loadRepoFixtures()
        // Validate the entire human set before loading either model. A bad or
        // partial set must fail cheaply and must never become a mixed
        // human/TTS baseline.
        let recordedAudio = try resolveRecordedAudioSet(
            enablement.recordingDirectory,
            strata: strata,
            allowSubset: enablement.recordingSubset
        )

        // Fixture repos: git-inited at runtime from the corpus specs (paths
        // are the vocabulary; the branch is part of it too).
        var fixtureRepos: [String: URL] = [:]
        for (name, fixture) in fixtures {
            fixtureRepos[name] = try makeFixtureRepo(fixture)
        }

        // Prompt templates through the production config path: a fresh
        // override directory gets seeded with the bundled files.
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-agent-e2e-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDirectory) }
        let configStore = AppConfigStore(configDirectoryOverride: configDirectory)

        let polishConfiguration: LLMPolishingConfiguration
        let polishBackend: String
        if let endpoint = enablement.polishEndpoint {
            // The external alias may not be a catalog repo ID (llama.cpp uses
            // aliases such as qwen35-4b), but this experiment must still send
            // the shipped 4B request shape: greedy sampling and thinking off.
            polishConfiguration = LLMPolishEvalSupport.configuration(
                endpointURL: endpoint,
                apiKey: "",
                model: enablement.polishModel,
                requestShapeModel: PolishModelCatalog.defaultOption.repoID
            )
            polishBackend = "external \(endpoint.absoluteString)"
            print(
                "agent-e2e: polish=external model=\(enablement.polishModel) "
                    + "temperature=0 top_p=1 top_k=0 min_p=0 presence_penalty=0 "
                    + "enable_thinking=false"
            )
        } else {
            guard let binary else { throw EvalInfraError("missing bundled helper path") }
            try await ensureModelCached(enablement.polishModel)
            let helper = try await launchHelper(binary: binary, model: enablement.polishModel)
            addTeardownBlock { await Self.reap(helper.process) }
            polishConfiguration = LLMPolishEvalSupport.configuration(
                endpointURL: URL(
                    string: "http://127.0.0.1:\(helper.port)/v1/chat/completions"
                )!,
                apiKey: "",
                model: enablement.polishModel
            )
            polishBackend = "helper \(binary.path)"
        }
        // Pay each profile's prompt-prefix prefill up front (two cache slots,
        // one per profile) so no case's polish request times out behind a cold
        // prefill — the CI failure mode of 2026-07-11.
        await warmPromptPrefixes(configStore: configStore, configuration: polishConfiguration)

        let enVoice = recordedAudio == nil
            ? Self.resolveVoice(languagePrefix: "en", preferred: ["Samantha", "Alex"])
            : nil
        let frVoice = recordedAudio == nil
            ? Self.resolveVoice(
                languagePrefix: "fr", preferred: ["Thomas", "Amélie", "Aurélie", "Audrey"]
            )
            : nil
        if let recordedAudio {
            print(
                "agent-e2e: audio=human-recorded set=\(recordedAudio.name) "
                    + "cases=\(recordedAudio.pcmByCaseID.count)"
                    + (recordedAudio.isSubset ? " subset=true" : "")
            )
        } else {
            print(
                "agent-e2e: audio=tts voices en=\(enVoice ?? "<system default>") "
                    + "fr=\(frVoice ?? "<none — fr TTS cases skip>")"
            )
        }

        let vocabularyCache = RepoVocabularyCache()
        let allCaseIDs = Set(strata.flatMap { $0.stratum.cases.map(\.id) })
        if let requested = enablement.caseIDs {
            let unknown = requested.subtracting(allCaseIDs).sorted()
            guard unknown.isEmpty else {
                throw EvalInfraError(
                    "unknown focused eval case id(s): \(unknown.joined(separator: ", "))"
                )
            }
        }
        let selectedCaseIDs = enablement.caseIDs ?? Support.selectedCaseIDs(
            strata: strata,
            recordedCaseIDs: Set(recordedAudio?.pcmByCaseID.keys.map { $0 } ?? []),
            isSubset: recordedAudio?.isSubset == true
        )
        let totalCases = strata.reduce(0) { total, loaded in
            total + loaded.stratum.cases.filter {
                selectedCaseIDs?.contains($0.id) ?? true
            }.count
        }
        var results: [Support.CaseResult] = []
        var reports: [Support.CaseReportRecord] = []
        var reportSystemPrompts: [String] = []
        var caseIndex = 0

        for loaded in strata {
            let stratum = loaded.stratum
            let plan = Support.stagePlan(for: stratum.resolvedPipeline)
            for evalCase in stratum.cases {
                if let selectedCaseIDs, !selectedCaseIDs.contains(evalCase.id) { continue }
                caseIndex += 1
                print("agent-e2e [\(caseIndex)/\(totalCases)] \(evalCase.id)")
                let run = await runCase(
                    evalCase,
                    stratumName: stratum.stratum,
                    pipeline: stratum.resolvedPipeline,
                    plan: plan,
                    enablement: enablement,
                    polishConfiguration: polishConfiguration,
                    configStore: configStore,
                    fixtureRepos: fixtureRepos,
                    vocabularyCache: vocabularyCache,
                    recordedAudio: recordedAudio,
                    enVoice: enVoice,
                    frVoice: frVoice
                )
                results.append(run.result)

                var systemPromptIndex: Int?
                if let prompt = run.capture.polishSystemPrompt {
                    if let existing = reportSystemPrompts.firstIndex(of: prompt) {
                        systemPromptIndex = existing
                    } else {
                        reportSystemPrompts.append(prompt)
                        systemPromptIndex = reportSystemPrompts.count - 1
                    }
                }
                reports.append(
                    Support.makeReportRecord(
                        evalCase: evalCase,
                        result: run.result,
                        capture: run.capture,
                        systemPromptIndex: systemPromptIndex
                    )
                )
            }
        }

        let board = Support.renderScoreboard(
            results: results,
            header: "polish model: \(enablement.polishModel), "
                + "asr: \(enablement.asrModel) @ \(enablement.voxmlxEndpoint), "
                + "audio: \(recordedAudio.map { "human-recorded/\($0.name)" } ?? "macOS say"), "
                + "polish backend: \(polishBackend)"
        )
        print(board.text)

        // Per-case inspection report: the remote log is the only channel back
        // from the build host (the SSH gate has no file fetch-back), so print
        // it between sentinels for offline extraction and inspection.
        do {
            let report = try Support.renderReport(
                header: Support.ReportHeader(
                    polishModel: enablement.polishModel,
                    asrModel: enablement.asrModel,
                    audioSource: recordedAudio.map { "human-recorded/\($0.name)" } ?? "macOS say",
                    systemPrompts: reportSystemPrompts
                ),
                records: reports
            )
            print(report)
            // `print` uses stdio buffering while XCTest writes assertion
            // diagnostics to the same descriptor. Flush the complete report
            // before any XCTFail below can splice its status line into a long
            // JSON record (observed on the first 163-case human run).
            fflush(stdout)
        } catch {
            print("agent-e2e: inspection report rendering failed: \(error)")
        }

        // Owner policy: required cases assert INDIVIDUALLY (one failure = red
        // suite); infra rot fails too (a dead backend must redden the nightly
        // lane, not silently degrade it); everything else stays XFAIL.
        for failure in board.requiredFailures {
            XCTFail(failure)
        }
        for failure in board.infraFailures {
            XCTFail(failure)
        }
    }

    // MARK: - Per-case run

    private func runCase(
        _ evalCase: AgentDictationEvalCorpus.Case,
        stratumName: String,
        pipeline: AgentDictationEvalCorpus.Pipeline,
        plan: Support.StagePlan,
        enablement: Support.Enablement,
        polishConfiguration: LLMPolishingConfiguration,
        configStore: AppConfigStore,
        fixtureRepos: [String: URL],
        vocabularyCache: RepoVocabularyCache,
        recordedAudio: RecordedAudioSet?,
        enVoice: String?,
        frVoice: String?
    ) async -> (result: Support.CaseResult, capture: Support.CaseCapture) {
        var result = Support.CaseResult(
            caseID: evalCase.id,
            stratum: stratumName,
            pipeline: pipeline,
            lang: evalCase.lang,
            statusByMetric: evalCase.status
        )
        var capture = Support.CaseCapture()

        do {
            var polishInput = evalCase.spokenForm
            if plan.runsSpeechRecognition {
                let pcm: Data
                if let recordedAudio {
                    pcm = try recordedPCM16(for: evalCase, in: recordedAudio)
                } else {
                    let voice: String?
                    switch evalCase.lang {
                    case .en:
                        voice = enVoice
                    case .fr:
                        guard let frVoice else {
                            result.skipReason = "no French TTS voice installed (say -v ?)"
                            return (result, capture)
                        }
                        voice = frVoice
                    }
                    pcm = try synthesizedPCM16(text: evalCase.spokenForm, voice: voice)
                }
                polishInput = try await transcribe(pcm: pcm, enablement: enablement)
                capture.transcript = polishInput
            }

            var finalOutput = polishInput
            if plan.runsPolish {
                let polish = try await runPolishStage(
                    input: polishInput,
                    evalCase: evalCase,
                    stratumName: stratumName,
                    polishConfiguration: polishConfiguration,
                    configStore: configStore,
                    fixtureRepos: fixtureRepos,
                    vocabularyCache: vocabularyCache
                )
                finalOutput = polish.committedText
                capture.polishSystemPrompt = polish.request?.systemPrompt
                capture.polishUserPrompts = polish.request?.userPrompts
                capture.polishInputText = polish.request?.inputText
                capture.rawModelOutput = polish.rawModelOutput

                // Raw-model diagnostic column: the SAME run's model output
                // before clipboard safety checks, at zero extra inference.
                // Macro-positive cases additionally apply the commit-time
                // payload substitution; scoring the placeholder form against
                // payload-bearing required tokens would create false failures.
                if var guardOffOutput = polish.rawModelOutput {
                    if evalCase.features?.macro == true,
                        let clipboard = evalCase.features?.clipboard,
                        let payload = PolishContextClipboardReader.readableSanitizedString(
                            from: PasteboardStub(string: clipboard)
                        )
                    {
                        guardOffOutput = ClipboardPayloadMacro.substitutePayload(
                            in: guardOffOutput, payload: payload
                        )
                    }
                    capture.guardOffOutput = guardOffOutput
                    result.guardOffTokensFailures = Support.tokensFailures(
                        output: guardOffOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                        evalCase: evalCase
                    )
                }
            }

            let trimmed = finalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            result.output = trimmed
            result.tokensFailures = Support.tokensFailures(output: trimmed, evalCase: evalCase)
            if plan.runsPolish,
                let rewrite = Support.antiRewriteFailure(
                    polishInput: polishInput, output: trimmed, evalCase: evalCase
                )
            {
                result.tokensFailures.append(rewrite)
                result.rewriteFailure = rewrite
                result.rewriteIsFatal = evalCase.status.values.contains(.required)
            }
            if evalCase.status["exactText"] != nil {
                result.exactTextFailures =
                    Support.exactTextFailure(output: trimmed, evalCase: evalCase).map { [$0] } ?? []
            }
            result.wordAccuracyVsIntended = IntegrationTestSupport.wordAccuracy(
                expected: evalCase.intendedText, actual: trimmed
            )
        } catch {
            result.infraFailure = "\(error)"
        }
        return (result, capture)
    }

    // MARK: - Polish stage (production stop-commit path)

    private struct PolishStageOutcome {
        let committedText: String
        /// The raw model output before explicit paste-placeholder integrity and
        /// payload substitution. Macro cases still carry the placeholder here;
        /// the diagnostic column substitutes it before scoring.
        let rawModelOutput: String?
        /// The polish request exactly as the production stop-commit path
        /// assembled it (system prompt, user prompts, input text) — recorded
        /// for the inspection report.
        let request: LLMPolishingRequest?
    }

    private func runPolishStage(
        input: String,
        evalCase: AgentDictationEvalCorpus.Case,
        stratumName: String,
        polishConfiguration: LLMPolishingConfiguration,
        configStore: AppConfigStore,
        fixtureRepos: [String: URL],
        vocabularyCache: RepoVocabularyCache
    ) async throws -> PolishStageOutcome {
        let settings = makeSettings()
        settings.llmPolishingEnabled = true
        // External-URL mode carries the ephemeral helper port through the
        // loopback privacy gates (clipboard context / repo vocabulary); the
        // request itself uses the catalog-aware configuration below.
        settings.polishingBackendMode = .externalURL
        settings.llmPolishingEndpointURL = polishConfiguration.endpointURL.absoluteString
        settings.agentPolishProfileEnabled = true

        let service = EvalRecordingPolishingService(configuration: polishConfiguration)
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: EvalOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = configStore
        viewModel.llmPolishingService = service
        viewModel.debugResolveTargetAppBundleIDOverride = {
            Support.polishTargetBundleID(forStratum: stratumName)
        }
        // Never the runner's real pasteboard: the polish-failure alert is also
        // pre-latched (presentConnectionFailureAlert would otherwise run a
        // REAL modal NSAlert — the suite-hang class AGENTS.md warns about).
        viewModel.isShowingConnectionFailureAlert = true

        if let features = evalCase.features {
            if features.macro != nil {
                // Macro stratum (positives AND explicit negatives): the
                // setting is on, the payload is staged; whether the macro
                // fires is exactly what the case scores.
                settings.clipboardPayloadMacroEnabled = true
                let payload = features.clipboard
                viewModel.debugClipboardPayloadPasteboardReaderOverride = {
                    PasteboardStub(string: payload)
                }
            } else if let clipboard = features.clipboard {
                settings.polishClipboardContextEnabled = true
                viewModel.debugPolishContextPasteboardReaderOverride = {
                    PasteboardStub(string: clipboard)
                }
            }
            if let repo = features.repo {
                guard let repoURL = fixtureRepos[repo.fixture] else {
                    throw EvalInfraError("fixture repo '\(repo.fixture)' was not prepared")
                }
                settings.repoVocabularyEnabled = true
                // Pipeline seam replaces ONLY the AX window-title read; the
                // production title -> cwd -> git-index -> match pipeline runs
                // for real against the git-inited fixture.
                let title = "eval@mac: \(repoURL.path) — zsh"
                viewModel.debugRepoVocabularyPipelineOverride = { transcript in
                    await RepoVocabularyService.entries(
                        forWindowTitle: title, transcript: transcript, cache: vocabularyCache
                    )
                }
            }
        }

        var savedRecord: DictationSessionRecord?
        viewModel.debugSavedSessionRecordSink = { savedRecord = $0 }
        Self.retainedViewModels.append(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = input

        viewModel.finishStoppedSession(promotePendingSegment: false)
        let deadline = ContinuousClock.now + Self.polishCommitDeadline
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !viewModel.isCompletingStoppedSession else {
            throw EvalInfraError("polish stop-commit did not complete within \(Self.polishCommitDeadline)")
        }
        if savedRecord?.status == DictationSessionStatus.llmFailed.rawValue {
            throw EvalInfraError(
                "polish request failed: \(viewModel.lastError ?? "unknown error")"
            )
        }
        let raw = await service.lastRawPolishedText
        let request = await service.lastRequest
        return PolishStageOutcome(
            committedText: viewModel.currentDictationEventText,
            rawModelOutput: raw,
            request: request
        )
    }

    // MARK: - TTS (cached)

    private struct RecordedAudioSet {
        let name: String
        let isSubset: Bool
        /// Exact manifest-verified bytes retained after preflight. Keeping
        /// them in memory prevents a long eval from observing a take changed
        /// on disk after its hash was checked.
        let pcmByCaseID: [String: Data]
    }

    private func resolveRecordedAudioSet(
        _ requestedPath: String?,
        strata: [AgentDictationEvalCorpus.LoadedStratum],
        allowSubset: Bool
    ) throws -> RecordedAudioSet? {
        guard let requestedPath else { return nil }
        let directory: URL
        if requestedPath.hasPrefix("/") {
            directory = URL(fileURLWithPath: requestedPath, isDirectory: true)
        } else {
            directory = repoRoot.appendingPathComponent(requestedPath, isDirectory: true)
        }
        let standardized = directory.standardizedFileURL
        let manifestURL = standardized.appendingPathComponent(Support.recordingManifestFileName)
        let manifest: Support.RecordingManifest
        do {
            manifest = try Support.parseRecordingManifest(Data(contentsOf: manifestURL))
        } catch {
            throw Support.RecordingSetError(
                message: "cannot read human recording manifest at \(manifestURL.path): \(error)"
            )
        }

        let allExpected = strata.flatMap { loaded -> [Support.RecordingExpectation] in
            guard Support.stagePlan(for: loaded.stratum.resolvedPipeline).runsSpeechRecognition
            else { return [] }
            return loaded.stratum.cases.map {
                Support.RecordingExpectation(id: $0.id, lang: $0.lang, spokenForm: $0.spokenForm)
            }
        }
        let recordings = try Support.validateRecordingManifest(
            manifest, expected: allExpected, allowSubset: allowSubset
        )
        let expected = allExpected.filter { recordings[$0.id] != nil }
        // Integrity + audio-format preflight for every case, before model load.
        // Retain the verified PCM so the bytes scored cannot change later.
        var pcmByCaseID: [String: Data] = [:]
        for item in expected {
            guard let recording = recordings[item.id] else { continue }
            let wavURL = standardized.appendingPathComponent(recording.file)
            let wav: Data
            do {
                wav = try Data(contentsOf: wavURL)
            } catch {
                throw Support.RecordingSetError(
                    message: "cannot read recording \(recording.id): \(error)"
                )
            }
            guard Support.sha256Hex(wav) == recording.sha256 else {
                throw Support.RecordingSetError(
                    message: "recording \(recording.id) does not match its manifest SHA-256"
                )
            }
            do {
                pcmByCaseID[item.id] = try Support.recordedPCM16(fromWAVData: wav)
            } catch {
                throw Support.RecordingSetError(
                    message: "recording \(recording.id) is invalid: \(error.localizedDescription)"
                )
            }
        }
        return RecordedAudioSet(
            name: standardized.lastPathComponent,
            isSubset: allowSubset,
            pcmByCaseID: pcmByCaseID
        )
    }

    private func recordedPCM16(
        for evalCase: AgentDictationEvalCorpus.Case,
        in set: RecordedAudioSet
    ) throws -> Data {
        guard let pcm = set.pcmByCaseID[evalCase.id] else {
            throw Support.RecordingSetError(message: "missing recording: \(evalCase.id)")
        }
        return pcm
    }

    private func synthesizedPCM16(text: String, voice: String?) throws -> Data {
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/localvoxtral-eval/wav", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
        let key = Support.wavCacheKey(text: text, voice: voice)
        let wavURL = cacheDirectory.appendingPathComponent("\(key).wav")

        if FileManager.default.fileExists(atPath: wavURL.path) {
            // A corrupt cached file (crash mid-write on an old run) must not
            // poison the cache: fall through to re-synthesis.
            if let pcm = try? IntegrationTestSupport.extractPCMDataFromWAV(at: wavURL),
                !pcm.isEmpty
            {
                return pcm
            }
            try? FileManager.default.removeItem(at: wavURL)
        }

        // Synthesize to a temp name, then move into place, so a crash
        // mid-`say` never leaves a half-written file under the final key.
        let temporary = cacheDirectory.appendingPathComponent("tmp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var arguments = [
            "-o", temporary.path,
            "--file-format=WAVE",
            "--data-format=\(Support.ttsDataFormat)",
        ]
        if let voice {
            arguments += ["-v", voice]
        }
        arguments.append(text)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EvalInfraError(
                "say failed (status \(process.terminationStatus)) for voice \(voice ?? "default")"
            )
        }
        try FileManager.default.moveItem(at: temporary, to: wavURL)
        return try IntegrationTestSupport.extractPCMDataFromWAV(at: wavURL)
    }

    /// `say -v ?` through a temp file (no pipes — descriptor-safe by
    /// construction), parsed by the unit-tested picker.
    private static func resolveVoice(languagePrefix: String, preferred: [String]) -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-agent-e2e-voices-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outputURL) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        try? handle.close()
        guard process.terminationStatus == 0,
            let output = try? String(contentsOf: outputURL, encoding: .utf8)
        else { return nil }
        return Support.pickVoice(
            fromSayVoicesOutput: output, languagePrefix: languagePrefix, preferred: preferred
        )
    }

    // MARK: - ASR (production websocket client vs live speechd STT service)

    private func transcribe(
        pcm: Data,
        enablement: Support.Enablement
    ) async throws -> String {
        let chunks = IntegrationTestSupport.splitPCM16IntoChunks(pcm, chunkSizeBytes: 3_200)
        let client = RealtimeAPIWebSocketClient()
        let finals = LockedStrings()
        let socketErrors = LockedStrings()
        let firstFinal = XCTestExpectation(description: "final transcript")
        firstFinal.assertForOverFulfill = false

        client.setEventHandler { event in
            switch event {
            case .connected:
                // Safe to enqueue before session.created; the client gates
                // outbound sends until session readiness (tier-1 pattern).
                for chunk in chunks {
                    client.sendAudioChunk(chunk)
                }
                client.sendCommit(final: false)
                client.sendCommit(final: true)
            case .finalTranscript(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                finals.append(trimmed)
                firstFinal.fulfill()
            case .error(let message):
                socketErrors.append(message)
                firstFinal.fulfill()  // fail fast, don't wait the full timeout
            default:
                break
            }
        }

        try client.connect(
            configuration: .init(
                endpoint: enablement.voxmlxEndpoint,
                apiKey: "",
                model: enablement.asrModel
            )
        )
        let outcome = await XCTWaiter.fulfillment(of: [firstFinal], timeout: Self.asrTimeout)
        // Short grace so trailing final segments of a longer utterance land.
        try? await Task.sleep(for: .seconds(1))
        client.disconnect()

        let transcript = finals.snapshot().joined(separator: " ")
        if !transcript.isEmpty {
            return transcript
        }
        let errors = socketErrors.snapshot()
        if !errors.isEmpty {
            throw EvalInfraError("realtime socket error: \(errors.joined(separator: " | "))")
        }
        if outcome != .completed {
            throw EvalInfraError(
                "no final transcript within \(Int(Self.asrTimeout))s from \(enablement.voxmlxEndpoint)"
            )
        }
        throw EvalInfraError("empty final transcript from \(enablement.voxmlxEndpoint)")
    }

    // MARK: - Fixture repos (real git, env-isolated)

    @discardableResult
    private func runGit(_ args: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        // Isolate from the build user's global gitconfig / signing / hooks
        // (RepoVocabularyIndexerEndToEndTests pattern).
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["HOME"] = directory.path
        process.environment = env
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeFixtureRepo(_ fixture: AgentDictationEvalCorpus.RepoFixture) throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-agent-e2e-repo-\(fixture.name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }

        guard runGit(["init", "-b", "main"], in: repo) == 0 else {
            throw EvalInfraError("git init failed for fixture \(fixture.name)")
        }
        runGit(["config", "user.email", "eval@example.com"], in: repo)
        runGit(["config", "user.name", "Agent Eval"], in: repo)
        runGit(["config", "commit.gpgsign", "false"], in: repo)

        for path in fixture.files {
            let fileURL = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Content is irrelevant to the vocabulary index; paths are the
            // vocabulary (corpus fixture contract).
            try "eval fixture\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        guard runGit(["add", "-A"], in: repo) == 0,
            runGit(["commit", "-m", "fixture"], in: repo) == 0
        else {
            throw EvalInfraError("git commit failed for fixture \(fixture.name)")
        }
        if fixture.branch != "main" {
            guard runGit(["checkout", "-b", fixture.branch], in: repo) == 0 else {
                throw EvalInfraError(
                    "git checkout -b \(fixture.branch) failed for fixture \(fixture.name)"
                )
            }
        }
        return repo
    }

    // MARK: - Enablement

    private func resolveEnablementOrSkip() throws -> Support.Enablement {
        let markerURL = repoRoot.appendingPathComponent(Support.markerFileName)
        var marker: Support.MarkerConfig?
        if FileManager.default.fileExists(atPath: markerURL.path) {
            marker = try Support.parseMarker(Data(contentsOf: markerURL))
        }
        guard
            let enablement = Support.resolveEnablement(
                environment: ProcessInfo.processInfo.environment,
                marker: marker
            )
        else {
            throw XCTSkip(
                """
                Agent-dictation E2E eval is disabled (nightly + manual lane, never tier 0).
                Enable with \(Support.enableEnvKey)=1 or run \
                ./scripts/remote-build.sh eval-e2e from the dev box \
                (after a `package` run has built the polishing helper). \
                Expect many minutes: ~150 TTS+ASR cases plus live 4B polish inference.
                """
            )
        }
        return enablement
    }

    private func resolveHelperBinary(_ helperPath: String) throws -> URL {
        let binary =
            helperPath.hasPrefix("/")
            ? URL(fileURLWithPath: helperPath)
            : repoRoot.appendingPathComponent(helperPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail(
                """
                Polishing helper binary missing at \(binary.path).
                Build it first: ./scripts/remote-build.sh package
                """
            )
            throw XCTSkip("helper binary missing")
        }
        return binary
    }

    // MARK: - Helper process (mirrors PolishHelperIntegrationTests)

    /// The helper never downloads (missing model = hard error by design), so
    /// the suite provisions the shared HF cache itself when the model is
    /// absent — same cache layout + include patterns as the app's
    /// HFModelDownloader, idempotent. Mirrors
    /// `PolishHelperIntegrationTests.ensureModelCached` (kept private there;
    /// the two suites wait on different plumbing, so the copy is deliberate).
    private func ensureModelCached(_ repoID: String) async throws {
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        let repoDir = cacheRoot.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        )
        let snapshotsDir = repoDir.appendingPathComponent("snapshots")

        // Provision the revision the app PINS, not whatever main points at:
        // the helper refuses any other snapshot (see HFCacheModelLocator).
        let pinnedRevision = PolishModelCatalog.option(forRepoID: repoID)?.revision

        // Completeness marker is a sentinel inside the snapshot, written LAST
        // below (never refs/main — a sha-pinned download writes no ref, and
        // rewriting the SHARED cache's main ref would lie to other tools on
        // the host). Same scheme as PolishHelperIntegrationTests.
        if let pinnedRevision {
            if PolishHelperIntegrationTests.snapshotIsProvisioned(
                snapshotsDir.appendingPathComponent(pinnedRevision)
            ) {
                return
            }
        } else if let revision = try? String(
            contentsOf: repoDir.appendingPathComponent("refs/main"),
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty,
            PolishHelperIntegrationTests.snapshotIsProvisioned(
                snapshotsDir.appendingPathComponent(revision)
            )
        {
            return
        }

        print("agent-e2e: downloading \(repoID) into \(cacheRoot.path)")
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
            throw EvalInfraError("HF API unreachable for \(repoID): \(infoResponse)")
        }
        let info = try JSONDecoder().decode(RepoInfo.self, from: infoData)
        if let pinnedRevision, info.sha != pinnedRevision {
            throw EvalInfraError(
                "HF resolved \(repoID)@\(pinnedRevision) to sha \(info.sha) — pin is not a commit"
            )
        }

        // Same include patterns as BackendManager.modelPreparationRequest.
        let patterns = [
            "*.json", "model*.safetensors", "*.py", "tokenizer.model",
            "*.tiktoken", "tiktoken.model", "*.txt", "*.jsonl", "*.jinja",
        ]
        let wanted = info.siblings.map(\.rfilename).filter { name in
            patterns.contains { fnmatch($0, name, 0) == 0 }
        }
        guard !wanted.isEmpty else {
            throw EvalInfraError("HF listing for \(repoID) matched no files")
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
                throw EvalInfraError("download failed for \(name): \(response)")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }

        if pinnedRevision == nil {
            let refsDir = repoDir.appendingPathComponent("refs")
            try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
            try Data("\(info.sha)\n".utf8).write(to: repoDir.appendingPathComponent("refs/main"))
        }
        try Data().write(
            to: snapshotDir.appendingPathComponent(PolishHelperIntegrationTests.provisionedSentinel)
        )
        print("agent-e2e: model provisioned (\(wanted.count) files)")
    }

    /// Spawns the helper on an ephemeral port (--port 0) and waits for its
    /// stderr readiness line. Event-driven via the descriptor-safe
    /// PipeLineReader (never FileHandle.availableData — PR #60).
    private func launchHelper(
        binary: URL,
        model: String
    ) async throws -> (process: Process, port: UInt16) {
        let process = Process()
        process.executableURL = binary
        // Mirror BackendManager.arguments(for:): the app pins the revision.
        var arguments = ["--model", model, "--port", "0"]
        if let revision = PolishModelCatalog.option(forRepoID: model)?.revision {
            arguments.append(contentsOf: ["--model-revision", revision])
        }
        process.arguments = arguments

        let stderr = Pipe()
        process.standardError = stderr
        let readyOrExited = XCTestExpectation(description: "helper ready or exited")
        readyOrExited.assertForOverFulfill = false
        let portBox = PortBox()
        let stderrLog = LockedStrings()
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

        _ = await XCTWaiter.fulfillment(of: [readyOrExited], timeout: Self.helperReadyTimeout)
        guard let port = portBox.get() else {
            let status =
                process.isRunning
                ? "still running, no ready line after \(Int(Self.helperReadyTimeout))s"
                : "exited with status \(process.terminationStatus)"
            await Self.reap(process)
            throw EvalInfraError(
                """
                Helper failed to become ready (\(status)). stderr tail:
                \(stderrLog.snapshot().suffix(30).joined(separator: "\n"))
                """
            )
        }
        return (process, port)
    }

    /// Reap, don't just signal (#111): bounded wait for the exit, escalate to
    /// SIGKILL, idempotent for an already-exited process.
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

    /// One warmup request per prompt profile (the helper keeps two prefix
    /// slots): bounded retries — a client-side timeout still leaves the
    /// helper prefilling, so the next attempt (and the eval) hits the warm
    /// checkpoint. Mirrors testHelperAgentProfileScoreboard's warmup.
    private func warmPromptPrefixes(
        configStore: AppConfigStore,
        configuration: LLMPolishingConfiguration
    ) async {
        let service = LLMPolishingService()
        for profile in [PolishPromptProfile.standard, PolishPromptProfile.agent] {
            let templates = configStore.loadLLMPromptTemplates(profile: profile)
            let request = PolishPromptWarmup.request(templates: templates)
            for _ in 0..<3 {
                do {
                    _ = try await service.polish(request: request, configuration: configuration)
                    break
                } catch LLMPolishingError.networkError {
                    continue  // client-side timeout; the helper keeps prefilling
                } catch {
                    break  // request completed (e.g. 1-token trim): prefix is warm
                }
            }
        }
    }

    // MARK: - Settings

    private func makeSettings() -> SettingsStore {
        let suiteName = "localvoxtral.AgentDictationE2EEvalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = .overlayBuffer
        return settings
    }
}

// MARK: - Local doubles

/// Forwards to the production `LLMPolishingService` with the catalog-aware
/// configuration production's managed mode builds (only the port differs —
/// the ephemeral helper port), and records the raw model output (diagnostic
/// column) plus the request itself (inspection report). The
/// request is assembled by the production stop-commit path; this wrapper
/// adds no request shaping.
private actor EvalRecordingPolishingService: LLMPolishingServicing {
    private let underlying = LLMPolishingService()
    private let configuration: LLMPolishingConfiguration
    private(set) var lastRawPolishedText: String?
    private(set) var lastRequest: LLMPolishingRequest?

    init(configuration: LLMPolishingConfiguration) {
        self.configuration = configuration
    }

    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        lastRequest = request
        let result = try await underlying.polish(request: request, configuration: configuration)
        lastRawPolishedText = result.polishedText
        return result
    }
}

/// Overlay coordinator double: the commit itself (AX insertion / pasteboard)
/// is out of scope for the eval — the scored artifact is the committed TEXT,
/// read from the view model exactly like the token-guard suite does.
@MainActor
private final class EvalOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor _: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText _: String, commitBufferText _: String) {}
    func refresh(displayBufferText _: String, commitBufferText _: String) {}

    func commitIfNeeded(
        using _: OverlayTextCommitting,
        autoCopyEnabled _: Bool
    ) -> OverlayBufferCommitOutcome {
        .succeeded
    }

    func dismissAfterHold(minimumVisibility _: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}

private struct EvalInfraError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Thread-safe string collector for socket/stderr callbacks.
private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
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
