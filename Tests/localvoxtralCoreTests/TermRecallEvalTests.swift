import Foundation
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

/// The term-recall eval (#315): does the speech engine spell the owner's
/// technical terms right, and does it write listed terms nobody said. No
/// polish in the loop, so a speech-engine change is measured alone.
///
/// Marker-gated like the other live evals; `scripts/remote-build.sh
/// eval-term-recall` writes `.term-recall-eval-enable.json` into the synced
/// tree. Three modes:
///
/// - `audio`: each case's text spoken by `say` (or a human recording), sent
///   through the production realtime client to one speech test service. On
///   Linux, where there is no `say`, only a recording set, and the service is
///   the dev box's vLLM (`scripts/linux/voxtral-vllm.sh`).
/// - `hypotheses`: text from a JSONL file of `{"id", "text"}` rows, e.g. a
///   second-pass transcript or a polished one (#524).
/// - `compare`: two earlier run files, paired per case.
///
/// The cases (`EvalRecordings/term-recall/cases.json`) come from the owner's
/// transcripts and are private. The scoreboard prints counts only; the run
/// file, which holds case text, is written under `EvalRecordings/` and
/// printed between run sentinels so `remote-build.sh` can copy it back.
final class TermRecallEvalTests: XCTestCase {
    static let markerFileName = ".term-recall-eval-enable.json"
    static let casesPath = "EvalRecordings/term-recall/cases.json"
    static let runsDirectory = "EvalRecordings/term-recall/runs"
    private static let asrTimeout: TimeInterval = 90

    struct MarkerConfig: Decodable, Equatable {
        enum Mode: String, Decodable {
            case audio
            case hypotheses
            case compare
        }

        var mode: Mode
        var label: String?
        /// audio: the speech service's row name, endpoint and pinned repo.
        var asr: String?
        var endpoint: String?
        var asrModel: String?
        /// audio: only `none` until an engine accepts a list (#316, #521).
        var bias: String?
        /// audio: `EvalRecordings/term-recall/<set>` with a manifest.json in
        /// the agent-dictation format. Absent = `say`.
        var recordingDirectory: String?
        /// hypotheses: a JSONL file under `EvalRecordings/term-recall/`.
        var hypothesesFile: String?
        /// compare: two run files under `EvalRecordings/term-recall/runs/`.
        var before: String?
        var after: String?
        var limit: Int?
        var caseIDs: [String]?
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testTermRecallEval() async throws {
        let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("Term-recall eval disabled; run ./scripts/remote-build.sh eval-term-recall")
        }
        let config = try JSONDecoder().decode(MarkerConfig.self, from: Data(contentsOf: markerURL))

        if config.mode == .compare {
            try runComparison(config)
            return
        }

        let caseFile = try loadCaseFile()
        var cases = caseFile.cases
        if let ids = config.caseIDs, !ids.isEmpty {
            let wanted = Set(ids)
            cases = cases.filter { wanted.contains($0.id) }
        }
        if let limit = config.limit {
            // Spread a short run over both languages rather than taking the
            // first N English cases.
            cases = Array(interleavedByLanguage(cases).prefix(limit))
        }
        XCTAssertFalse(cases.isEmpty, "no cases selected")

        let run: TermRecallRun
        switch config.mode {
        case .audio:
            run = try await runAudio(config, cases: cases, noiseTerms: caseFile.noiseTerms)
        case .hypotheses:
            run = try runHypotheses(config, cases: cases, noiseTerms: caseFile.noiseTerms)
        case .compare:
            return
        }

        let jsonLines = try run.jsonLines()
        let runsURL = repoRoot.appendingPathComponent(Self.runsDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: runsURL, withIntermediateDirectories: true)
        try Data(jsonLines.utf8).write(
            to: runsURL.appendingPathComponent("\(run.header.label).jsonl"), options: .atomic
        )
        print(TermRecallReport.runBegin)
        print(jsonLines, terminator: "")
        print(TermRecallReport.runEnd)
        print(TermRecallReport.scoreboard(run))
        // XCTest writes assertion diagnostics to the same descriptor; flush
        // the run file first, or a failure below lands inside a JSON line
        // (as in the agent-dictation eval). `nil` flushes every stream: Glibc's
        // `stdout` is a mutable global that strict concurrency refuses.
        fflush(nil)

        XCTAssertEqual(
            run.header.unscoredCases, 0,
            "\(run.header.unscoredCases) case(s) left unscored; the FAILED lines in the log say why"
        )
        let corpusErrors = TermRecallScorer.tally(run.scores)["all"]?.corpusErrors ?? 0
        XCTAssertEqual(corpusErrors, 0, "listed terms missing from their case text; re-harvest")
    }

    // MARK: - Modes

    private func runAudio(
        _ config: MarkerConfig,
        cases: [TermRecallCase],
        noiseTerms: [String]
    ) async throws -> TermRecallRun {
        guard let asr = config.asr, let endpointString = config.endpoint,
            let endpointURL = URL(string: endpointString), let model = config.asrModel
        else {
            throw EvalSpeechStage.Failure("audio mode needs asr, endpoint and asrModel in the marker")
        }
        let bias = config.bias ?? "none"
        guard bias == "none" else {
            throw EvalSpeechStage.Failure(
                "bias=\(bias): no speech engine accepts a term list yet (#316, #521)"
            )
        }

        let recordings = try config.recordingDirectory.map { try loadRecordings($0, cases: cases) }
        // English falls back to the system voice, as in the agent-dictation
        // eval; French has no fallback, since an English voice reading French
        // would measure the voice.
        #if os(macOS)
        var englishVoice: String?
        var frenchVoice: String?
        if recordings == nil {
            englishVoice = EvalSpeechStage.resolveVoice(
                languagePrefix: "en", preferred: EvalSpeechStage.englishVoicePreference
            )
            frenchVoice = EvalSpeechStage.resolveVoice(
                languagePrefix: "fr", preferred: EvalSpeechStage.frenchVoicePreference
            )
            progress("term-recall: voices en=\(englishVoice ?? "default") fr=\(frenchVoice ?? "none")")
        }
        #else
        guard recordings != nil else {
            throw EvalSpeechStage.Failure("audio mode needs recordingDirectory here: `say` is macOS-only")
        }
        #endif

        let endpoint = EvalSpeechStage.Endpoint(url: endpointURL, apiKey: "", model: model)
        var scores: [TermRecallCaseScore] = []
        var unscored = 0
        for (index, evalCase) in cases.enumerated() {
            let hypothesis: String
            do {
                let pcm: Data
                if let recordings {
                    guard let recorded = recordings.pcmByID[evalCase.id] else {
                        progress("term-recall: [\(index + 1)/\(cases.count)] \(evalCase.id) no recording, skipped")
                        continue
                    }
                    pcm = recorded
                } else {
                    #if os(macOS)
                    let voice = evalCase.language == "fr" ? frenchVoice : englishVoice
                    if evalCase.language == "fr", voice == nil {
                        throw EvalSpeechStage.Failure("no French voice installed (say -v ?)")
                    }
                    pcm = try EvalSpeechStage.synthesizedPCM16(text: evalCase.text, voice: voice)
                    #else
                    throw EvalSpeechStage.Failure("`say` is macOS-only")
                    #endif
                }
                hypothesis = try await EvalSpeechStage.transcribe(
                    pcm: pcm,
                    client: RealtimeAPIWebSocketClient(),
                    endpoint: endpoint,
                    timeout: Self.asrTimeout
                )
            } catch {
                // Infrastructure, not a score: the case id and the error, no
                // case text.
                progress("term-recall: [\(index + 1)/\(cases.count)] \(evalCase.id) FAILED: \(error)")
                unscored += 1
                continue
            }
            scores.append(TermRecallScorer.score(evalCase, hypothesis: hypothesis, noiseTerms: noiseTerms))
            progress("term-recall: [\(index + 1)/\(cases.count)] \(evalCase.id) done")
        }
        let audio = recordings?.audio ?? "say"
        return TermRecallRun(
            header: .init(
                label: config.label ?? "\(asr)-\(bias)", source: asr, model: model, bias: bias, audio: audio,
                unscoredCases: unscored
            ),
            scores: scores
        )
    }

    private func runHypotheses(
        _ config: MarkerConfig,
        cases: [TermRecallCase],
        noiseTerms: [String]
    ) throws -> TermRecallRun {
        guard let path = config.hypothesesFile else {
            throw EvalSpeechStage.Failure("hypotheses mode needs hypothesesFile in the marker")
        }
        struct Row: Decodable {
            let id: String
            let text: String
        }
        let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        var byID: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let row = try JSONDecoder().decode(Row.self, from: Data(line.utf8))
            byID[row.id] = row.text
        }
        let scored = cases.filter { byID[$0.id] != nil }
        progress("term-recall: \(scored.count) of \(cases.count) selected case(s) have a hypothesis")
        return TermRecallRun(
            header: .init(
                label: config.label ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                source: "hypotheses",
                model: nil,
                bias: config.bias ?? "none",
                audio: "none"
            ),
            scores: scored.map { TermRecallScorer.score($0, hypothesis: byID[$0.id]!, noiseTerms: noiseTerms) }
        )
    }

    private func runComparison(_ config: MarkerConfig) throws {
        guard let before = config.before, let after = config.after else {
            throw EvalSpeechStage.Failure("compare mode needs before and after run files in the marker")
        }
        func load(_ path: String) throws -> TermRecallRun {
            do {
                return try TermRecallRun.parse(
                    jsonLines: String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
                )
            } catch let error as DecodingError {
                throw EvalSpeechStage.Failure(
                    "\(path) does not decode (\(error)); a run file from an older scorer, so run it again"
                )
            }
        }
        print(TermRecallReport.comparison(before: try load(before), after: try load(after)))
    }

    /// A progress line, flushed so a long run shows where it is.
    private func progress(_ line: String) {
        print(line)
        fflush(nil)
    }

    // MARK: - Inputs

    private func loadCaseFile() throws -> TermRecallCaseFile {
        let url = repoRoot.appendingPathComponent(Self.casesPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EvalSpeechStage.Failure(
                "\(Self.casesPath) missing; run scripts/harvest-term-recall-cases.py on the transcript box"
            )
        }
        let file = try JSONDecoder().decode(TermRecallCaseFile.self, from: Data(contentsOf: url))
        guard file.schemaVersion == 2 else {
            throw EvalSpeechStage.Failure("cases.json schemaVersion \(file.schemaVersion); re-harvest (want 2)")
        }
        return file
    }

    /// PCM by case id from a recording set in the agent-dictation manifest
    /// format. A partial set is allowed; its missing cases are skipped, never
    /// filled with `say`.
    /// The set's PCM by case id, and its audio label for the run header.
    private func loadRecordings(
        _ directory: String,
        cases: [TermRecallCase]
    ) throws -> (pcmByID: [String: Data], audio: String) {
        let directoryURL = repoRoot.appendingPathComponent(directory, isDirectory: true)
        let manifest = try RecordedAudioSet.parseManifest(
            Data(contentsOf: directoryURL.appendingPathComponent(RecordedAudioSet.manifestFileName))
        )
        let expected = try cases.map { evalCase -> RecordedAudioSet.Expectation in
            guard let lang = RecordedAudioSet.Language(rawValue: evalCase.language) else {
                throw EvalSpeechStage.Failure("case \(evalCase.id) has language \(evalCase.language)")
            }
            return .init(id: evalCase.id, lang: lang, spokenForm: evalCase.text)
        }
        // Recordings of cases outside this run (a --limit, a --case) are not
        // stale, just unselected.
        let selected = Set(cases.map(\.id))
        let recordings = try RecordedAudioSet.validateManifest(
            .init(
                schemaVersion: manifest.schemaVersion,
                dataFormat: manifest.dataFormat,
                recordings: manifest.recordings.filter { selected.contains($0.id) }
            ),
            expected: expected,
            allowSubset: true
        )
        var pcmByID: [String: Data] = [:]
        for (id, recording) in recordings {
            let wav = try Data(contentsOf: directoryURL.appendingPathComponent(recording.file))
            guard PortableSHA256.hex(of: wav) == recording.sha256 else {
                throw EvalSpeechStage.Failure("recording \(id) does not match its manifest hash")
            }
            pcmByID[id] = try RecordedAudioSet.pcm16(fromWAVData: wav)
        }
        return (pcmByID, manifest.audioLabel(setName: directoryURL.lastPathComponent))
    }

    private func interleavedByLanguage(_ cases: [TermRecallCase]) -> [TermRecallCase] {
        let english = cases.filter { $0.language != "fr" }
        let french = cases.filter { $0.language == "fr" }
        var result: [TermRecallCase] = []
        for index in 0..<max(english.count, french.count) {
            if index < english.count { result.append(english[index]) }
            if index < french.count { result.append(french[index]) }
        }
        return result
    }
}
