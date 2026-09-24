import Foundation
import XCTest

@testable import localvoxtral

/// Replays a user's stored dictations (the opt-in audio store) through two
/// setups on identical input, so a gain from learning is measured rather than
/// read off a trend:
///
///   stored WAV -> live speechd ASR (once) -> polish through the production
///   stop-commit path, twice:
///     day 0   Names and terms only, no learned terms
///     today   Names and terms plus every confirmed learned term
///
/// Each output is scored against the text the dictation actually inserted:
/// word accuracy, and recall of the terms that text spells. The transcript
/// row scores the ASR output alone. The inserted text is what polishing
/// produced at the time, not a hand-checked reference: a later edit the user
/// made in the target app is not in the history (that signal is #520).
///
/// Run with `./scripts/remote-build.sh eval-e2e --replay
/// EvalRecordings/replay/<set>` after `package`; the set comes from
/// `scripts/export-dictation-replay.sh` on the Mac that dictated. Only
/// Overlay Buffer dictations are replayed: Live Auto-Paste never polishes, so
/// learned terms cannot reach it. The log carries numbers only.
extension AgentDictationE2EEvalTests {
    func testReplayStoredDictations() async throws {
        let enablement = try resolveEnablementOrSkip()
        guard let replayPath = enablement.replayDirectory else {
            throw XCTSkip("no replay set: run ./scripts/remote-build.sh eval-e2e --replay <set>")
        }
        guard enablement.provider == .speechd else {
            throw XCTSkip("the replay runs on the local speech and polishing services only")
        }
        let set = try DictationReplaySupport.loadSet(
            at: repoRoot.appendingPathComponent(replayPath, isDirectory: true))
        guard let history = DictationSessionStore(url: set.storeURL) else {
            throw EvalInfraError("the replay set's default.store does not open")
        }
        let audioStore = DictationAudioStore(directoryURL: set.audioDirectory)
        let stored = audioStore.storedIDs()
        let entries = await history.entries(since: nil)
            // Only text that reached the target app is a reference.
            .filter {
                stored.contains($0.id) && $0.commitSucceeded
                    && $0.outputMode == DictationOutputMode.overlayBuffer.rawValue
            }
            .reversed()  // oldest first, the order they were spoken in
        guard !entries.isEmpty else {
            throw EvalInfraError("no Overlay Buffer dictation in the set has audio")
        }

        let configStore = try makeReplayConfigStore()
        let polishConfiguration = try await localPolishConfiguration(enablement)
        await warmPromptPrefixes(configStore: configStore, configuration: polishConfiguration)

        let terms = set.speakerTerms + set.learnedTerms
        var transcriptScore = DictationReplaySupport.ArmScore()
        var dayZeroScore = DictationReplaySupport.ArmScore()
        var todayScore = DictationReplaySupport.ArmScore()
        var seconds = 0
        var failures = 0
        for (index, entry) in entries.enumerated() {
            do {
                let wav = try Data(contentsOf: audioStore.fileURL(for: entry.id))
                let pcm = try AgentDictationE2EEvalSupport.recordedPCM16(fromWAVData: wav)
                seconds += pcm.count / AudioChunkBuffer.bytesPerSecond
                let transcript = try await transcribe(pcm: pcm, enablement: enablement)
                let dayZero = try await replayPolish(
                    transcript, entry: entry, learnedTerms: [], speakerTerms: set.speakerTerms,
                    configuration: polishConfiguration, configStore: configStore)
                let today = try await replayPolish(
                    transcript, entry: entry, learnedTerms: set.learnedTerms,
                    speakerTerms: set.speakerTerms,
                    configuration: polishConfiguration, configStore: configStore)
                let reference = entry.finalText
                transcriptScore.add(reference: reference, output: transcript, terms: terms)
                dayZeroScore.add(reference: reference, output: dayZero, terms: terms)
                todayScore.add(reference: reference, output: today, terms: terms)
                print("replay [\(index + 1)/\(entries.count)] ok")
            } catch {
                failures += 1
                // The error's type, never its message: a backend that echoes
                // the request would put the user's words in the log.
                print("replay [\(index + 1)/\(entries.count)] failed: \(type(of: error))")
            }
        }

        print(DictationReplaySupport.renderScoreboard(
            header: "\(entries.count - failures) of \(entries.count) dictations, \(seconds) s of audio, "
                + "\(set.learnedTerms.count) learned terms, \(set.speakerTerms.count) Names and terms, "
                + "asr \(enablement.asrModel), polish \(polishConfiguration.model)",
            arms: [
                ("transcript", transcriptScore),
                ("day 0", dayZeroScore),
                ("today", todayScore),
            ]))
        fflush(stdout)
        XCTAssertEqual(failures, 0, "every stored dictation replays")
    }

    /// The polish half of the replay: the production stop-commit path with
    /// polishing on, the dictation's own target app (so its prompt profile),
    /// and the learned terms of one arm under the shared project. Every
    /// other context source is off: a replay has no screen, clipboard or
    /// terminal from the time.
    private func replayPolish(
        _ transcript: String,
        entry: DictationHistoryEntry,
        learnedTerms: [String],
        speakerTerms: [String],
        configuration: LLMPolishingConfiguration,
        configStore: AppConfigStore
    ) async throws -> String {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .externalURL
        settings.llmPolishingEndpointURL = configuration.endpointURL.absoluteString
        settings.agentPolishProfileEnabled = true
        settings.polishSpeakerTerms = speakerTerms
        // The gate the learned-terms project hangs off: the fake below reports
        // "no repository", which is the shared project.
        settings.repoVocabularyEnabled = true

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = configStore
        let service = EvalRecordingPolishingService(configuration: configuration)
        viewModel.llmPolishingService = service
        viewModel.stubCommitTarget { entry.targetAppBundleID }
        viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding(
            outcome: nil, root: nil)
        let learned = LearnedTermStore(fileURL: nil)
        for _ in 0..<LearnedTerms.confirmedDictations {
            learned.record(
                learnedTerms.map { LearnedTermObservation(term: $0, source: .learned) },
                project: LearnedTermProjectResolver.shared)
        }
        learned.waitForPendingWrites()
        viewModel.learnedTermStore = learned
        // Never a real modal alert on the build host.
        viewModel.session.isShowingConnectionFailureAlert = true

        var savedRecord: DictationSessionRecord?
        viewModel.dependencies.onSessionRecord = { savedRecord = $0 }
        retainForTestProcessLifetime(viewModel)

        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = transcript
        viewModel.session.finishStoppedSession(promotePendingSegment: false)
        await viewModel.session.polishAndCommitTask?.value
        if savedRecord?.status == DictationSessionStatus.llmFailed.rawValue {
            throw EvalInfraError("polish failed")
        }
        return viewModel.transcript.currentDictationEventText
    }

    private func makeReplayConfigStore() throws -> AppConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-replay-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppConfigStore(configDirectoryOverride: directory)
    }

    /// The bundled helper, or the external endpoint the marker names: the
    /// same two choices the corpus scoreboard offers for the local arm.
    private func localPolishConfiguration(
        _ enablement: AgentDictationE2EEvalSupport.Enablement
    ) async throws -> LLMPolishingConfiguration {
        if let endpoint = enablement.polishEndpoint {
            return LLMPolishEvalSupport.configuration(
                endpointURL: endpoint,
                apiKey: "",
                model: enablement.polishModel,
                requestShapeModel: PolishModelCatalog.defaultOption.repoID
            )
        }
        let binary = try resolveHelperBinary(enablement.helperPath)
        try await ensureModelCached(enablement.polishModel)
        let helper = try await launchHelper(binary: binary, model: enablement.polishModel)
        addTeardownBlock { await Self.reap(helper.process) }
        return LLMPolishEvalSupport.configuration(
            endpointURL: URL(string: "http://127.0.0.1:\(helper.port)/v1/chat/completions")!,
            apiKey: "",
            model: enablement.polishModel
        )
    }
}
