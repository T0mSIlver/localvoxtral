import Foundation
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

/// The speech stage of the agent-dictation eval alone: every corpus case
/// that runs speech recognition, from a recorded set, through the production
/// realtime client to one speech service. No polish, so it needs no Mac: on
/// Linux it runs against the dev box's vLLM (`scripts/linux/voxtral-vllm.sh`),
/// which is BF16 Voxtral, not the shipped 4-bit model. The end-to-end eval
/// (`AgentDictationE2EEvalTests`) stays the proof on the shipped engine.
///
/// Scored per case: word accuracy against what was said (`spokenForm`) and
/// against `intendedText`, and the `tokens` metric for the ASR-only stratum,
/// whose tokens are the engine's to get right. Required ASR-only cases assert
/// individually, as in the end-to-end eval. An empty transcript is a result
/// (word accuracy 0), not an infrastructure failure. The transcripts are the
/// owner's speech, so they go to a run file under the gitignored
/// `EvalRecordings/`, and the log prints counts only.
///
/// Marker-gated: `.agent-eval-asr-enable.json` at the checkout root, written
/// by hand (`EvalCorpus/agent-dictation/README.md`, "ASR-only runs on Linux").
final class AgentDictationASREvalTests: XCTestCase {
    static let markerFileName = ".agent-eval-asr-enable.json"
    static let runsDirectory = "EvalRecordings/agent-dictation/asr-runs"
    static let scoreboardBegin = "== agent-dictation ASR-only scoreboard =="
    static let scoreboardEnd = "== end agent-dictation ASR-only scoreboard =="
    private static let asrTimeout: TimeInterval = 90

    struct MarkerConfig: Decodable {
        var label: String
        /// The speech service's name in the scoreboard, e.g. `vllm-voxtral-bf16`.
        var asr: String
        var endpoint: String
        var asrModel: String
        /// A set in the recording manifest format, relative to the checkout.
        var recordingDirectory: String
        /// Run only the recorded cases; without it a missing recording fails
        /// the run, as in the end-to-end eval.
        var subset: Bool?
        var caseIDs: [String]?
    }

    struct CaseRecord: Codable {
        var id: String
        var stratum: String
        var lang: String
        var pipeline: String
        var transcript: String?
        var wordAccuracySpoken: Double?
        var wordAccuracyIntended: Double?
        /// Only for ASR-only cases; nil where polish owns the tokens.
        var tokensFailures: [String]?
        var tokensStatus: String?
        var infraFailure: String?
    }

    struct RunHeader: Codable {
        var label: String
        var asr: String
        var model: String
        var audio: String
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testAgentDictationASREval() async throws {
        let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("ASR-only agent-dictation eval disabled; see EvalCorpus/agent-dictation/README.md")
        }
        let config = try JSONDecoder().decode(MarkerConfig.self, from: Data(contentsOf: markerURL))
        guard let endpointURL = URL(string: config.endpoint) else {
            throw EvalSpeechStage.Failure("endpoint \(config.endpoint) is not a URL")
        }
        guard config.label.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw EvalSpeechStage.Failure("label must be [A-Za-z0-9._-]")
        }

        var speechCases: [(stratum: String, pipeline: AgentDictationEvalCorpus.Pipeline, evalCase: AgentDictationEvalCorpus.Case)] = []
        for loaded in try AgentDictationEvalCorpus.loadStrata() {
            let pipeline = loaded.stratum.resolvedPipeline
            guard AgentDictationEvalCorpus.stagePlan(for: pipeline).runsSpeechRecognition else { continue }
            for evalCase in loaded.stratum.cases {
                speechCases.append((loaded.stratum.stratum, pipeline, evalCase))
            }
        }
        if let ids = config.caseIDs, !ids.isEmpty {
            let wanted = Set(ids)
            let unknown = wanted.subtracting(speechCases.map(\.evalCase.id)).sorted()
            guard unknown.isEmpty else {
                throw EvalSpeechStage.Failure("not a speech case: \(unknown.joined(separator: ", "))")
            }
            speechCases = speechCases.filter { wanted.contains($0.evalCase.id) }
        }

        let pcmByID = try loadRecordings(config, cases: speechCases.map(\.evalCase))
        speechCases = speechCases.filter { pcmByID[$0.evalCase.id] != nil }
        XCTAssertFalse(speechCases.isEmpty, "no case selected")

        let endpoint = EvalSpeechStage.Endpoint(url: endpointURL, apiKey: "", model: config.asrModel)
        var records: [CaseRecord] = []
        for (index, item) in speechCases.enumerated() {
            let evalCase = item.evalCase
            var record = CaseRecord(
                id: evalCase.id, stratum: item.stratum, lang: evalCase.lang.rawValue,
                pipeline: item.pipeline.rawValue
            )
            do {
                let transcript = try await EvalSpeechStage.transcribe(
                    pcm: pcmByID[evalCase.id]!,
                    client: RealtimeAPIWebSocketClient(),
                    endpoint: endpoint,
                    timeout: Self.asrTimeout,
                    allowsEmptyTranscript: true
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                record.transcript = transcript
                record.wordAccuracySpoken = IntegrationTestSupport.wordAccuracy(
                    expected: evalCase.spokenForm, actual: transcript)
                record.wordAccuracyIntended = IntegrationTestSupport.wordAccuracy(
                    expected: evalCase.intendedText, actual: transcript)
                if item.pipeline == .asrOnly, let status = evalCase.status["tokens"] {
                    record.tokensFailures = AgentDictationEvalCorpus.tokensFailures(
                        output: transcript, evalCase: evalCase)
                    record.tokensStatus = status.rawValue
                }
            } catch {
                // Infrastructure, not a score: the case id and the error only.
                record.infraFailure = "\(error)"
            }
            records.append(record)
            progress("agent-asr: [\(index + 1)/\(speechCases.count)] \(evalCase.id) \(record.infraFailure == nil ? "done" : "FAILED: \(record.infraFailure!)")")
        }

        let header = RunHeader(
            label: config.label, asr: config.asr, model: config.asrModel,
            audio: "human/\(URL(fileURLWithPath: config.recordingDirectory).lastPathComponent)"
        )
        try writeRunFile(header: header, records: records)
        print(Self.scoreboard(header: header, records: records))
        // XCTest writes assertion diagnostics to the same descriptor; flush
        // the scoreboard first. `nil` flushes every stream: Glibc's `stdout`
        // is a mutable global that strict concurrency refuses.
        fflush(nil)

        for record in records {
            if let failure = record.infraFailure {
                XCTFail("\(record.id): \(failure)")
            }
            if record.tokensStatus == AgentDictationEvalCorpus.Status.required.rawValue,
                let failures = record.tokensFailures, !failures.isEmpty
            {
                // The failures name corpus tokens, which are public.
                XCTFail("\(record.id) (required): \(failures.joined(separator: "; "))")
            }
        }
    }

    // MARK: - Scoreboard

    static func scoreboard(header: RunHeader, records: [CaseRecord]) -> String {
        var lines = [
            scoreboardBegin,
            "run=\(header.label) asr=\(header.asr) model=\(header.model) audio=\(header.audio)",
            "lang  cases  word acc vs spoken  word acc vs intended  asr-only tokens (required, known-hard)  infra failures",
        ]
        for lang in ["en", "fr", "all"] {
            let rows = records.filter { lang == "all" || $0.lang == lang }
            guard !rows.isEmpty else { continue }
            let scored = rows.filter { $0.infraFailure == nil }
            func mean(_ values: [Double]) -> String {
                values.isEmpty ? "-" : String(format: "%.3f", values.reduce(0, +) / Double(values.count))
            }
            func tokens(_ status: AgentDictationEvalCorpus.Status) -> String {
                let graded = scored.filter { $0.tokensStatus == status.rawValue }
                let passed = graded.filter { $0.tokensFailures?.isEmpty == true }
                return "\(passed.count)/\(graded.count)"
            }
            lines.append(
                [
                    lang.padding(toLength: 6, withPad: " ", startingAt: 0),
                    "\(rows.count)".padding(toLength: 7, withPad: " ", startingAt: 0),
                    mean(scored.compactMap(\.wordAccuracySpoken)).padding(toLength: 20, withPad: " ", startingAt: 0),
                    mean(scored.compactMap(\.wordAccuracyIntended)).padding(toLength: 22, withPad: " ", startingAt: 0),
                    "\(tokens(.required)), \(tokens(.knownHard))".padding(toLength: 40, withPad: " ", startingAt: 0),
                    "\(rows.count - scored.count)",
                ].joined()
            )
        }
        lines.append(scoreboardEnd)
        return lines.joined(separator: "\n")
    }

    // MARK: - Inputs and outputs

    private func loadRecordings(
        _ config: MarkerConfig, cases: [AgentDictationEvalCorpus.Case]
    ) throws -> [String: Data] {
        let directoryURL = repoRoot.appendingPathComponent(config.recordingDirectory, isDirectory: true)
        let manifest = try RecordedAudioSet.parseManifest(
            Data(contentsOf: directoryURL.appendingPathComponent(RecordedAudioSet.manifestFileName))
        )
        // With `caseIDs`, recordings of the other cases are unselected, not
        // stale.
        let selected = Set(cases.map(\.id))
        let recordings = try RecordedAudioSet.validateManifest(
            config.caseIDs?.isEmpty == false
                ? .init(
                    schemaVersion: manifest.schemaVersion,
                    dataFormat: manifest.dataFormat,
                    recordings: manifest.recordings.filter { selected.contains($0.id) }
                )
                : manifest,
            expected: cases.map { .init(id: $0.id, lang: $0.lang, spokenForm: $0.spokenForm) },
            allowSubset: config.subset ?? false
        )
        var pcmByID: [String: Data] = [:]
        for (id, recording) in recordings {
            let wav = try Data(contentsOf: directoryURL.appendingPathComponent(recording.file))
            guard PortableSHA256.hex(of: wav) == recording.sha256 else {
                throw EvalSpeechStage.Failure("recording \(id) does not match its manifest hash")
            }
            pcmByID[id] = try RecordedAudioSet.pcm16(fromWAVData: wav)
        }
        progress("agent-asr: \(pcmByID.count) recording(s) for \(cases.count) speech case(s)")
        return pcmByID
    }

    private func writeRunFile(header: RunHeader, records: [CaseRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = [String(decoding: try encoder.encode(header), as: UTF8.self)]
        for record in records {
            lines.append(String(decoding: try encoder.encode(record), as: UTF8.self))
        }
        let runsURL = repoRoot.appendingPathComponent(Self.runsDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: runsURL, withIntermediateDirectories: true)
        let fileURL = runsURL.appendingPathComponent("\(header.label).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fileURL, options: .atomic)
        progress("agent-asr: run file \(Self.runsDirectory)/\(header.label).jsonl")
    }

    /// A progress line, flushed so a long run shows where it is.
    private func progress(_ line: String) {
        print(line)
        fflush(nil)
    }
}
