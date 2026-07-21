import Foundation
import XCTest

@testable import localvoxtral

/// Tier-0 unit coverage for the deterministic pieces of the agent-dictation
/// E2E eval harness (no gating, no network, no TTS): enablement resolution,
/// WAV-cache key derivation, pipeline/profile routing, corpus-contract
/// scoring, voice picking, and scoreboard rendering. @MainActor because two
/// assertions consult MainActor-isolated production types (SettingsStore's
/// default model pin, TerminalTargetDetector's allowlist).
@MainActor
final class AgentDictationE2EEvalSupportTests: XCTestCase {
    private typealias Support = AgentDictationE2EEvalSupport

    // MARK: - Marker parsing + enablement resolution

    func testParseMarkerReadsAllFields() throws {
        let data = Data(
            """
            {"helperPath": "/tmp/polishd", "voxmlxEndpoint": "ws://127.0.0.1:9000/v1/realtime",
             "asrModel": "acme/asr", "polishModel": "acme/polish",
             "polishEndpoint": "http://gpu:8080/v1/chat/completions",
             "recordingDirectory": "EvalRecordings/agent-dictation/owner",
             "recordingSubset": true}
            """.utf8
        )
        let marker = try Support.parseMarker(data)
        XCTAssertEqual(marker.helperPath, "/tmp/polishd")
        XCTAssertEqual(marker.voxmlxEndpoint, "ws://127.0.0.1:9000/v1/realtime")
        XCTAssertEqual(marker.asrModel, "acme/asr")
        XCTAssertEqual(marker.polishModel, "acme/polish")
        XCTAssertEqual(marker.polishEndpoint, "http://gpu:8080/v1/chat/completions")
        XCTAssertEqual(marker.recordingDirectory, "EvalRecordings/agent-dictation/owner")
        XCTAssertEqual(marker.recordingSubset, true)
    }

    func testParseMarkerToleratesMissingFields() throws {
        let marker = try Support.parseMarker(Data("{\"helperPath\": \"x\"}".utf8))
        XCTAssertEqual(marker.helperPath, "x")
        XCTAssertNil(marker.voxmlxEndpoint)
        XCTAssertNil(marker.asrModel)
        XCTAssertNil(marker.polishModel)
        XCTAssertNil(marker.polishEndpoint)
        XCTAssertNil(marker.recordingDirectory)
        XCTAssertNil(marker.recordingSubset)
    }

    func testEnablementNilWithoutEnvOrMarker() {
        XCTAssertNil(Support.resolveEnablement(environment: [:], marker: nil))
        // A "0" env value is not enablement either.
        XCTAssertNil(
            Support.resolveEnablement(
                environment: [Support.enableEnvKey: "0"], marker: nil
            )
        )
    }

    func testEnablementFromMarkerAppliesDefaultsFieldByField() throws {
        let enablement = try XCTUnwrap(
            Support.resolveEnablement(
                environment: [:],
                marker: Support.MarkerConfig(helperPath: "custom/polishd")
            )
        )
        XCTAssertEqual(enablement.helperPath, "custom/polishd")
        XCTAssertEqual(enablement.voxmlxEndpoint.absoluteString, Support.defaultVoxmlxEndpoint)
        XCTAssertEqual(enablement.asrModel, Support.defaultASRModel)
        XCTAssertEqual(enablement.polishModel, SettingsStore.defaultLLMPolishingModel)
        XCTAssertNil(enablement.polishEndpoint)
        XCTAssertFalse(enablement.recordingSubset)
    }

    func testEnablementFromEnvOverridesMarker() throws {
        let enablement = try XCTUnwrap(
            Support.resolveEnablement(
                environment: [
                    Support.enableEnvKey: "1",
                    Support.helperPathEnvKey: "/env/polishd",
                    Support.polishEndpointEnvKey: "http://gpu:8080/v1/chat/completions",
                    Support.recordingDirectoryEnvKey: "/env/recordings",
                    Support.recordingSubsetEnvKey: "1",
                    Support.caseIDsEnvKey: "one,two,one",
                ],
                marker: Support.MarkerConfig(
                    helperPath: "marker/polishd",
                    asrModel: "marker/asr",
                    recordingDirectory: "marker/recordings"
                )
            )
        )
        XCTAssertEqual(enablement.helperPath, "/env/polishd")
        // Fields the env does not carry still fall through to the marker.
        XCTAssertEqual(enablement.asrModel, "marker/asr")
        XCTAssertEqual(enablement.recordingDirectory, "/env/recordings")
        XCTAssertEqual(
            enablement.polishEndpoint?.absoluteString,
            "http://gpu:8080/v1/chat/completions"
        )
        XCTAssertTrue(enablement.recordingSubset)
        XCTAssertEqual(enablement.caseIDs, ["one", "two"])
    }

    // MARK: - WAV cache key

    func testWavCacheKeyIsDeterministicHex() {
        let first = Support.wavCacheKey(text: "open the dot env file", voice: "Samantha")
        let second = Support.wavCacheKey(text: "open the dot env file", voice: "Samantha")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testWavCacheKeyChangesWithEachInput() {
        let base = Support.wavCacheKey(text: "hello", voice: "Samantha")
        XCTAssertNotEqual(base, Support.wavCacheKey(text: "hello there", voice: "Samantha"))
        XCTAssertNotEqual(base, Support.wavCacheKey(text: "hello", voice: "Thomas"))
        XCTAssertNotEqual(base, Support.wavCacheKey(text: "hello", voice: nil))
        XCTAssertNotEqual(
            base, Support.wavCacheKey(text: "hello", voice: "Samantha", dataFormat: "LEI16@22050")
        )
    }

    /// Field boundaries must be unambiguous: text containing a would-be
    /// separator must not collide with a shifted voice value. (This test
    /// caught the original "|"-join derivation doing exactly that; fields are
    /// length-prefixed now.)
    func testWavCacheKeyFieldBoundariesDoNotCollide() {
        XCTAssertNotEqual(
            Support.wavCacheKey(text: "a|Samantha", voice: nil),
            Support.wavCacheKey(text: "a", voice: "Samantha|default")
        )
    }

    // MARK: - Human recording manifests + WAV validation

    private var recordingExpectation: Support.RecordingExpectation {
        Support.RecordingExpectation(
            id: "b-en-flag-force", lang: .en,
            spokenForm: "run it with dash dash force"
        )
    }

    private func recording(
        id: String = "b-en-flag-force",
        spokenForm: String = "run it with dash dash force",
        file: String? = nil,
        sha256: String = String(repeating: "a", count: 64)
    ) -> Support.Recording {
        Support.Recording(
            id: id,
            lang: .en,
            spokenForm: spokenForm,
            file: file ?? "\(id).wav",
            sha256: sha256
        )
    }

    func testRecordingManifestAcceptsExactCompleteCorpusBinding() throws {
        let manifest = Support.RecordingManifest(
            schemaVersion: Support.recordingSchemaVersion,
            dataFormat: Support.recordingDataFormat,
            recordings: [recording()]
        )
        XCTAssertEqual(
            try Support.validateRecordingManifest(
                manifest, expected: [recordingExpectation]
            )[recordingExpectation.id],
            recording()
        )
    }

    func testRecordingManifestSubsetIsExplicitAndNeverFallsBackToTTS() throws {
        let second = Support.RecordingExpectation(
            id: "a-en-websocket-timeout", lang: .en,
            spokenForm: "the websocket client times out"
        )
        let partial = Support.RecordingManifest(
            schemaVersion: Support.recordingSchemaVersion,
            dataFormat: Support.recordingDataFormat,
            recordings: [recording()]
        )
        XCTAssertThrowsError(
            try Support.validateRecordingManifest(
                partial, expected: [recordingExpectation, second]
            )
        ) { XCTAssertTrue($0.localizedDescription.contains("incomplete")) }
        XCTAssertEqual(
            try Support.validateRecordingManifest(
                partial,
                expected: [recordingExpectation, second],
                allowSubset: true
            ),
            [recordingExpectation.id: recording()]
        )

        let unknown = Support.RecordingManifest(
            schemaVersion: Support.recordingSchemaVersion,
            dataFormat: Support.recordingDataFormat,
            recordings: [recording(id: "unknown-case")]
        )
        XCTAssertThrowsError(
            try Support.validateRecordingManifest(
                unknown,
                expected: [recordingExpectation, second],
                allowSubset: true
            )
        ) { XCTAssertTrue($0.localizedDescription.contains("stale/unknown")) }
    }

    func testRecordingManifestRejectsPartialStaleAndDuplicateSets() {
        let empty = Support.RecordingManifest(
            schemaVersion: 1,
            dataFormat: Support.recordingDataFormat,
            recordings: []
        )
        XCTAssertThrowsError(
            try Support.validateRecordingManifest(empty, expected: [recordingExpectation])
        ) { XCTAssertTrue($0.localizedDescription.contains("incomplete")) }

        let stale = Support.RecordingManifest(
            schemaVersion: 1,
            dataFormat: Support.recordingDataFormat,
            recordings: [recording(spokenForm: "old phrase")]
        )
        XCTAssertThrowsError(
            try Support.validateRecordingManifest(stale, expected: [recordingExpectation])
        ) { XCTAssertTrue($0.localizedDescription.contains("stale")) }

        let duplicate = Support.RecordingManifest(
            schemaVersion: 1,
            dataFormat: Support.recordingDataFormat,
            recordings: [recording(), recording()]
        )
        XCTAssertThrowsError(
            try Support.validateRecordingManifest(duplicate, expected: [recordingExpectation])
        ) { XCTAssertTrue($0.localizedDescription.contains("duplicate")) }
    }

    func testRecordingManifestRejectsSchemaFormatExtraUnsafeAndMalformedHash() {
        let expected = [recordingExpectation]
        let wrongSchema = Support.RecordingManifest(
            schemaVersion: 2, dataFormat: Support.recordingDataFormat,
            recordings: [recording()]
        )
        XCTAssertThrowsError(try Support.validateRecordingManifest(wrongSchema, expected: expected)) {
            XCTAssertTrue($0.localizedDescription.contains("schemaVersion"))
        }
        let wrongFormat = Support.RecordingManifest(
            schemaVersion: 1, dataFormat: "pcm_s16le@44100Hz-stereo",
            recordings: [recording()]
        )
        XCTAssertThrowsError(try Support.validateRecordingManifest(wrongFormat, expected: expected)) {
            XCTAssertTrue($0.localizedDescription.contains("dataFormat"))
        }
        let extra = Support.RecordingManifest(
            schemaVersion: 1, dataFormat: Support.recordingDataFormat,
            recordings: [recording(), recording(id: "unknown-case")]
        )
        XCTAssertThrowsError(try Support.validateRecordingManifest(extra, expected: expected)) {
            XCTAssertTrue($0.localizedDescription.contains("stale/unknown"))
        }
        let unsafe = Support.RecordingManifest(
            schemaVersion: 1, dataFormat: Support.recordingDataFormat,
            recordings: [recording(file: "../take.wav")]
        )
        XCTAssertThrowsError(try Support.validateRecordingManifest(unsafe, expected: expected)) {
            XCTAssertTrue($0.localizedDescription.contains("unsafe"))
        }
        let malformedHash = Support.RecordingManifest(
            schemaVersion: 1, dataFormat: Support.recordingDataFormat,
            recordings: [recording(sha256: "NOT-A-HASH")]
        )
        XCTAssertThrowsError(
            try Support.validateRecordingManifest(malformedHash, expected: expected)
        ) { XCTAssertTrue($0.localizedDescription.contains("SHA-256")) }
    }

    func testRecordedWAVValidationAcceptsExactProductionFormat() throws {
        let wav = makeWAV(sampleRate: 16_000, channels: 1, bits: 16, pcmBytes: 8_000)
        XCTAssertEqual(try Support.recordedPCM16(fromWAVData: wav).count, 8_000)
        XCTAssertEqual(Support.sha256Hex(wav).count, 64)
    }

    /// ffmpeg's WAV muxer writes metadata chunks (normally LIST/INFO) that
    /// our synthetic minimal WAV omitted. Unknown chunks — including odd
    /// sizes with RIFF padding and chunks after data — must be skipped.
    func testRecordedWAVValidationAcceptsFFmpegStyleExtraChunks() throws {
        let wav = makeWAV(
            sampleRate: 16_000, channels: 1, bits: 16, pcmBytes: 8_000,
            chunksBeforeData: [("LIST", Data("abc".utf8))],
            chunksAfterData: [("JUNK", Data([1, 2, 3, 4]))]
        )
        XCTAssertEqual(try Support.recordedPCM16(fromWAVData: wav).count, 8_000)
    }

    func testRecordedWAVValidationRejectsWrongRateAndShortAudio() {
        XCTAssertThrowsError(
            try Support.recordedPCM16(
                fromWAVData: makeWAV(
                    sampleRate: 44_100, channels: 1, bits: 16, pcmBytes: 8_000
                )
            )
        ) { XCTAssertTrue($0.localizedDescription.contains("16000")) }
        XCTAssertThrowsError(
            try Support.recordedPCM16(
                fromWAVData: makeWAV(
                    sampleRate: 16_000, channels: 1, bits: 16, pcmBytes: 2_000
                )
            )
        ) { XCTAssertTrue($0.localizedDescription.contains("0.25")) }
        XCTAssertThrowsError(
            try Support.recordedPCM16(
                fromWAVData: makeWAV(
                    sampleRate: 16_000, channels: 1, bits: 16,
                    pcmBytes: 8_000, containsSignal: false
                )
            )
        ) { XCTAssertTrue($0.localizedDescription.contains("digitally silent")) }
    }

    /// The recorder is a standalone Swift script rather than a SwiftPM
    /// target. Exercise its non-recording list path in tier 0 so syntax/API
    /// drift or corpus-decoding drift cannot leave the operator workflow
    /// broken while app tests pass. This path intentionally needs no ffmpeg.
    func testHumanRecorderScriptCompilesAndListsEverySpeechCase() throws {
        let outputDirectory = recorderOutputDirectory(label: "smoke")
        addTeardownBlock { try? FileManager.default.removeItem(at: outputDirectory) }
        let run = try runRecorder(
            ["--list", "--output", outputDirectory.path]
        )
        XCTAssertEqual(run.status, 0, run.output)
        let expectedSpeechCases = try AgentDictationEvalCorpus.loadStrata().reduce(0) {
            $0 + (Support.stagePlan(for: $1.stratum.resolvedPipeline).runsSpeechRecognition
                ? $1.stratum.cases.count : 0)
        }
        XCTAssertTrue(
            run.output.contains("Corpus speech cases: \(expectedSpeechCases)"), run.output
        )
        XCTAssertEqual(
            run.output.split(separator: "\n").filter { $0.hasPrefix("TODO ") }.count,
            expectedSpeechCases,
            run.output
        )
        XCTAssertTrue(
            run.output.contains(
                "Manifest: schema \(Support.recordingSchemaVersion), "
                    + "format \(Support.recordingDataFormat)"
            ),
            run.output
        )
    }

    func testHumanRecorderAcceptsRepeatedCaseFilters() throws {
        let outputDirectory = recorderOutputDirectory(label: "focused-batch")
        addTeardownBlock { try? FileManager.default.removeItem(at: outputDirectory) }
        let selected = ["b-en-equals-assignment", "j-fr-git-dense"]
        let run = try runRecorder([
            "--list", "--output", outputDirectory.path,
            "--case", selected[0], "--case", selected[1],
        ])
        XCTAssertEqual(run.status, 0, run.output)
        let rows = run.output.split(separator: "\n").filter { $0.hasPrefix("TODO ") }
        XCTAssertEqual(rows.count, selected.count, run.output)
        for id in selected {
            XCTAssertTrue(run.output.contains("TODO \(id) "), run.output)
        }
    }

    /// Losing or corrupting the convenience manifest must not discard hours
    /// of accepted human speech. Older manifests are journaled on first run;
    /// subsequent runs reconstruct the manifest from that durable journal.
    func testHumanRecorderRecoveryJournalRebuildsCorruptManifest() throws {
        let outputDirectory = recorderOutputDirectory(label: "recovery")
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: outputDirectory) }

        let id = "a-en-websocket-timeout"
        let spokenForm = "the integration tests fail on main since yesterday. "
            + "the websocket client times out after ten seconds. look at the reconnect logic "
            + "and add a regression test before changing anything else."
        let wav = makeWAV(sampleRate: 16_000, channels: 1, bits: 16, pcmBytes: 8_000)
        try wav.write(to: outputDirectory.appendingPathComponent("\(id).wav"))
        let recording = Support.Recording(
            id: id, lang: .en, spokenForm: spokenForm,
            file: "\(id).wav", sha256: Support.sha256Hex(wav)
        )
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        let manifest = Support.RecordingManifest(
            schemaVersion: Support.recordingSchemaVersion,
            dataFormat: Support.recordingDataFormat,
            recordings: [recording]
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)

        let bootstrap = try runRecorder(
            ["--list", "--output", outputDirectory.path, "--case", id]
        )
        XCTAssertEqual(bootstrap.status, 0, bootstrap.output)
        XCTAssertTrue(bootstrap.output.contains("DONE \(id)"), bootstrap.output)
        let journalURL = outputDirectory.appendingPathComponent("accepted-recordings.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        try Data("deliberately corrupt".utf8).write(to: manifestURL)
        let recovered = try runRecorder(
            ["--list", "--output", outputDirectory.path, "--case", id]
        )
        XCTAssertEqual(recovered.status, 0, recovered.output)
        XCTAssertTrue(recovered.output.contains("manifest.json is unreadable"), recovered.output)
        XCTAssertTrue(recovered.output.contains("DONE \(id)"), recovered.output)
        XCTAssertTrue(recovered.output.contains("1 accepted take(s) protected"), recovered.output)
        XCTAssertEqual(
            try Support.parseRecordingManifest(Data(contentsOf: manifestURL)).recordings,
            [recording]
        )

        // Simulate termination after the replacement was journaled and its
        // normalized WAV was written, but before the atomic rename occurred.
        var replacementWAV = wav
        replacementWAV[44] = 2
        let replacement = Support.Recording(
            id: id, lang: .en, spokenForm: spokenForm,
            file: "\(id).wav", sha256: Support.sha256Hex(replacementWAV)
        )
        var journal = try Data(contentsOf: journalURL)
        journal.append(try JSONEncoder().encode(replacement))
        journal.append(0x0a)
        try journal.write(to: journalURL)
        let temporaryURL = outputDirectory.appendingPathComponent(".\(id).tmp.wav")
        try replacementWAV.write(to: temporaryURL)
        try Data("deliberately corrupt again".utf8).write(to: manifestURL)

        let interruptedSave = try runRecorder(
            ["--list", "--output", outputDirectory.path, "--case", id]
        )
        XCTAssertEqual(interruptedSave.status, 0, interruptedSave.output)
        XCTAssertTrue(
            interruptedSave.output.contains("Recovered interrupted save for \(id)"),
            interruptedSave.output
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertEqual(
            try Data(contentsOf: outputDirectory.appendingPathComponent("\(id).wav")),
            replacementWAV
        )
        XCTAssertEqual(
            try Support.parseRecordingManifest(Data(contentsOf: manifestURL)).recordings,
            [replacement]
        )
    }

    /// Regression: ffmpeg-backed enumeration could remain alive forever on
    /// macOS. The recorder now uses in-process AVFoundation discovery and
    /// must return without requiring ffmpeg or microphone capture.
    func testHumanRecorderListsAudioDevicesInProcess() throws {
        let run = try runRecorder(["--list-devices"])
        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("AVFoundation audio inputs:"), run.output)
        XCTAssertTrue(run.output.contains("[default] System default input"), run.output)
        XCTAssertFalse(run.output.contains("DeprecatedDeclaration"), run.output)
    }

    func testHumanRecorderAdvertisesFastDefaultReviewFlow() throws {
        let run = try runRecorder(["--help"])
        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("Playback is optional"), run.output)
        XCTAssertTrue(run.output.contains("Return\naccepts a take"), run.output)
    }

    func testHumanRecorderListCannotWriteOutsideGitignoredRecordings() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-recorder-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let run = try runRecorder(["--list", "--output", outputDirectory.path])
        XCTAssertNotEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("recording output must stay under"), run.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testRecordingSubsetStillRunsEveryAudioIndependentCase() throws {
        let strata = try AgentDictationEvalCorpus.loadStrata()
        let speechCase = try XCTUnwrap(
            strata.first {
                Support.stagePlan(for: $0.stratum.resolvedPipeline).runsSpeechRecognition
            }?.stratum.cases.first
        )
        let selected = try XCTUnwrap(
            Support.selectedCaseIDs(
                strata: strata, recordedCaseIDs: [speechCase.id], isSubset: true
            )
        )
        XCTAssertTrue(selected.contains(speechCase.id))
        for loaded in strata
        where !Support.stagePlan(for: loaded.stratum.resolvedPipeline).runsSpeechRecognition
        {
            XCTAssertTrue(Set(loaded.stratum.cases.map(\.id)).isSubset(of: selected))
        }
        let requiredCaseIDs = Set(
            strata.flatMap(\.stratum.cases)
                .filter { $0.status.values.contains(.required) }
                .map(\.id)
        )
        XCTAssertTrue(requiredCaseIDs.isSubset(of: selected))
        XCTAssertNil(
            Support.selectedCaseIDs(
                strata: strata, recordedCaseIDs: [speechCase.id], isSubset: false
            )
        )
    }

    func testHumanEvalHTMLReportShowsAudioAndPipelineStages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-agent-html-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = """
        {"schemaVersion":1,"dataFormat":"pcm_s16le@16000Hz-mono","recordings":[
          {"id":"r-en-report","lang":"en","spokenForm":"open less than unsafe","file":"r-en-report.wav","sha256":"\(String(repeating: "0", count: 64))"},
          {"id":"r-en-asr","lang":"en","spokenForm":"tests fail on main","file":"r-en-asr.wav","sha256":"\(String(repeating: "1", count: 64))"}
        ]}
        """
        try manifest.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )
        let log = """
        build noise
        \(Support.reportBeginSentinel)
        {"asrModel":"asr-model","audioSource":"human-recorded/owner","polishModel":"polish-model","systemPrompts":[]}
        {"caseID":"unrecoverable"
        {"caseID":"r-en-report","caseInsensitive":false,"forbiddenSubstrings":[],"exactTextFailures":["expected truth"],"guardOffOutput":"Open wrong.","guardOffTokensFailures":["missing token"],"intendedText":"Open <truth>.","lang":"en","output":"Open wrong.","pipeline":"full","polishInputText":"open wrong","rawModelOutput":"Fetch https://api.example.com/v2/users and cat /tmp/log, then open wr/Users/owner/localvoxtral/Tests/localvoxtralTests/AgentDictationE2EEvalTests.swift:275: error: -[localvoxtralTests.AgentDictationE2EEvalTests testScoreboard] : failed - infra error on r-en-report
        Test Case '-[localvoxtralTests.AgentDictationE2EEvalTests testScoreboard]' passed (12.3 seconds).
        Test Suite 'AgentDictationE2EEvalTests' passed at 2026-07-14 10:00:00.000.
        \t Executed 1 test, with 0 failures in 12.3 seconds
        ong.","requiredTokens":["truth"],"rewriteFailure":"word accuracy vs input 0.20 < 0.8 (rewrote the text)","rewriteIsFatal":false,"spokenForm":"open less than unsafe","statusByMetric":{"exactText":"known-hard","tokens":"known-hard"},"stratum":"filenames-backticks","tokensFailures":["missing truth"],"transcript":"open <unsafe>","wordAccuracyVsIntended":0.5}
        {"caseID":"r-en-asr","caseInsensitive":false,"forbiddenSubstrings":[],"intendedText":"Tests fail on main.","lang":"en","output":"Tests fail on me.","pipeline":"asr-only","requiredTokens":["tests"],"spokenForm":"tests fail on main","statusByMetric":{"tokens":"known-hard"},"stratum":"plain-asr-baseline","tokensFailures":[],"transcript":"Tests fail on me.","wordAccuracyVsIntended":0.75}
        \(Support.reportEndSentinel)
        trailing test output
        """
        let logURL = directory.appendingPathComponent("eval.log")
        try log.write(to: logURL, atomically: true, encoding: .utf8)

        let run = try runReportRenderer([logURL.path, directory.path])
        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertTrue(run.output.contains("skipped 1 malformed/interleaved report value"))
        let html = try String(
            contentsOf: directory.appendingPathComponent("eval-report.html"), encoding: .utf8
        )
        XCTAssertTrue(html.contains("src=\"r-en-report.wav\""), html)
        XCTAssertTrue(html.contains("ASR transcript"), html)
        XCTAssertTrue(html.contains("LLM polish"), html)
        XCTAssertTrue(html.contains("Final shown to user"), html)
        XCTAssertTrue(html.contains("Ground truth"), html)
        XCTAssertTrue(html.contains("ASR unrecovered"), html)
        XCTAssertTrue(html.contains(">rewrite<"), html)
        XCTAssertTrue(html.contains("ASR mismatch: 1"), html)
        XCTAssertTrue(html.contains("Open wrong."), html)
        XCTAssertTrue(html.contains("https://api.example.com/v2/users"), html)
        XCTAssertTrue(html.contains("cat /tmp/log"), html)
        XCTAssertFalse(html.contains("Test Suite &#39;AgentDictation"), html)
        XCTAssertTrue(html.contains("open &lt;unsafe&gt;"), html)
        XCTAssertFalse(html.contains("open <unsafe>"), html)

        let ablationHTML = directory.appendingPathComponent("ablation.html")
        let ablation = try runAblation([
            logURL.path,
            "--render-only",
            "--results", directory.appendingPathComponent("results.jsonl").path,
            "--html", ablationHTML.path,
        ])
        XCTAssertEqual(ablation.status, 0, ablation.output)
        XCTAssertTrue(ablation.output.contains("00 raw ASR: n=2"), ablation.output)
        let ablationPage = try String(contentsOf: ablationHTML, encoding: .utf8)
        XCTAssertTrue(ablationPage.contains("r-en-report"), ablationPage)
        XCTAssertTrue(ablationPage.contains("r-en-asr"), ablationPage)

        let duplicateManifest = manifest.replacingOccurrences(
            of: "]}",
            with: ",{\"id\":\"r-en-report\",\"lang\":\"en\","
                + "\"spokenForm\":\"duplicate\",\"file\":\"other.wav\","
                + "\"sha256\":\"\(String(repeating: "2", count: 64))\"}]}"
        )
        try duplicateManifest.write(
            to: directory.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )
        let duplicateRun = try runReportRenderer([logURL.path, directory.path])
        XCTAssertNotEqual(duplicateRun.status, 0)
        XCTAssertTrue(duplicateRun.output.contains("duplicate id: r-en-report"))
    }

    func testAblationCacheHashIncludesCaseEndpointAndProductionRequestShape() throws {
        let script = repoRoot.appendingPathComponent("scripts/ablate-agent-eval.py")
        let snippet = #"""
        import importlib.util, sys
        spec = importlib.util.spec_from_file_location("agent_ablation", sys.argv[1])
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        messages = [{"role": "user", "content": "hello"}]
        left = module.experiment_hash("case", "http://one/v1", "model", "variant", messages)
        right = module.experiment_hash("case", "http://two/v1", "model", "variant", messages)
        assert left != right
        payload = module.request_payload("model", messages)
        assert payload["temperature"] == 0.0
        assert payload["top_k"] == 0
        assert payload["chat_template_kwargs"] == {"enable_thinking": False}
        experiment = module.Experiment("case", "model", "variant", messages, left)
        filtered = module.current_results(
            {left: {"output": "current"}, right: {"output": "stale"}}, [experiment]
        )
        assert list(filtered) == [left]
        ceiling = module.Experiment("case", "ceiling", "variant", messages, right)
        arms = module.pending_model_arms([experiment, ceiling], ["model", "ceiling"])
        assert [(model, [item.model for item in items]) for model, items in arms] == [
            ("model", ["model"]), ("ceiling", ["ceiling"])
        ]
        records = [
            {"caseID": "case-one", "spokenForm": "same request"},
            {"caseID": "case-two", "spokenForm": "same request"},
        ]
        experiments = module.make_experiments(
            records, {}, "http://one/v1", ["model"], ["raw-focused"], {}
        )
        assert len({item.request_hash for item in experiments}) == 2
        """#
        let run = try runPython(["-c", snippet, script.path])
        XCTAssertEqual(run.status, 0, run.output)
    }

    func testAblationAppendRecoversAfterPartialFinalJSONLLine() throws {
        let script = repoRoot.appendingPathComponent("scripts/ablate-agent-eval.py")
        let snippet = #"""
        import contextlib, importlib.util, io, pathlib, sys, tempfile
        spec = importlib.util.spec_from_file_location("agent_ablation", sys.argv[1])
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)

        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "results.jsonl"
            path.write_text('{"caseID":"orphan"', encoding="utf-8")
            valid = {
                "caseID": "complete",
                "requestHash": "complete-hash",
                "output": "kept",
            }
            module.append_result(path, valid)
            warnings = io.StringIO()
            with contextlib.redirect_stderr(warnings):
                loaded = module.load_results(path)
            assert loaded == {"complete-hash": valid}
            assert "warning: skipped 1 malformed/interleaved result value(s)" in warnings.getvalue()
        """#
        let run = try runPython(["-c", snippet, script.path])
        XCTAssertEqual(run.status, 0, run.output)
    }

    func testAblationRendersCurrentPromptsAndAttributesTechnicalTermFailures() throws {
        let script = repoRoot.appendingPathComponent("scripts/ablate-agent-eval.py")
        let snippet = #"""
        import importlib.util, sys
        spec = importlib.util.spec_from_file_location("agent_ablation", sys.argv[1])
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)

        record = {
            "caseID": "i-en-name",
            "stratum": "repo-vocabulary",
            "intendedText": "Open DictationViewModel.swift.",
            "requiredTokens": ["DictationViewModel.swift"],
            "features": {"repo": {"fixture": "smallapp"}},
            "polishInputText": "Open Dictation View Model.",
            "userPrompts": [
                "old static prefix",
                "Reference context — text currently on the user's clipboard. Use it only as reference.\n"
                "---\nDictationViewModel.swift\n---\n\n"
                "Repository vocabulary (exact terms):\n"
                "- DictationViewModel.swift: Dictation View Model\n\n"
                "Working text:\nOpen Dictation View Model."
            ],
        }
        system = module.bundled_prompt_content("llm_system_prompt_agent.toml")
        user = module.bundled_prompt_content("llm_user_prompt_agent.toml")
        assert not system.startswith("\n")
        assert system.endswith("\n")
        assert not user.startswith("\n")
        assert user.endswith("\n")
        messages = module.current_production_messages(record, system, user)
        assert len(messages) == 3
        assert messages[0] == {"role": "system", "content": system}
        assert "Reference context" in messages[-1]["content"]
        assert "- DictationViewModel.swift: Dictation View Model" in messages[-1]["content"]
        assert "Working text:\nOpen Dictation View Model." in messages[-1]["content"]
        no_context = module.current_production_messages(
            record, system, user, include_vocabulary=False, include_context=False
        )
        assert "Reference context" not in no_context[-1]["content"]
        assert "Repository vocabulary" not in no_context[-1]["content"]
        vocabulary_only = module.current_production_messages(
            record, system, user, include_context=False
        )
        assert "Reference context" not in vocabulary_only[-1]["content"]
        assert "Repository vocabulary" in vocabulary_only[-1]["content"]
        context_only = module.current_production_messages(
            record, system, user, include_vocabulary=False
        )
        assert "Reference context" in context_only[-1]["content"]
        assert "Repository vocabulary" not in context_only[-1]["content"]
        oracle = module.current_production_messages(record, system, user, oracle=True)
        assert "Evaluation-only oracle technical spellings" in oracle[-1]["content"]
        assert "- DictationViewModel.swift" in oracle[-1]["content"]
        grounded = module.append_grounded_candidate_check(messages, record)
        assert len(grounded) == len(messages) + 1
        assert "src/auth/useAuth.ts" in grounded[-1]["content"]
        assert "Sources/App/DictationViewModel.swift" in grounded[-1]["content"]
        assert "Grounded technical-term check" in grounded[-1]["content"]
        strict = module.append_strict_oracle_check(oracle, record)
        assert len(strict) == len(oracle) + 1
        assert "must contain each one exactly" in strict[-1]["content"]
        assert "- DictationViewModel.swift" in strict[-1]["content"]
        grounded_repair = module.targeted_repair_messages(
            record, "Open uzoft.ts and add a null check.", oracle=False
        )
        assert len(grounded_repair) == 2
        assert "Current polished text:\nOpen uzoft.ts" in grounded_repair[-1]["content"]
        assert "src/auth/useAuth.ts" in grounded_repair[-1]["content"]
        oracle_repair = module.targeted_repair_messages(
            record, "Open uzoft.ts and add a null check.", oracle=True
        )
        assert "evaluation-only exact literals" in oracle_repair[-1]["content"]
        assert "- DictationViewModel.swift" in oracle_repair[-1]["content"]
        exact, heard, score = module.broad_repo_match(record)
        assert exact == "DictationViewModel.swift"
        assert heard == "Dictation View Model"
        assert score > 0.8
        ranked_repair = module.ranked_repo_repair_messages(
            record, "Open Dictation View Model."
        )
        assert "- exact: DictationViewModel.swift" in ranked_repair[-1]["content"]
        standard_system = module.bundled_prompt_content("llm_system_prompt.toml")
        standard_user = module.bundled_prompt_content("llm_user_prompt.toml")
        preapplied = module.messages_for(
            record, {}, "current-production-ranked-preapply", None,
            {"standard": (standard_system, standard_user), "agent": (system, user)},
        )
        assert "Working text:\nOpen DictationViewModel.swift." in preapplied[-1]["content"]
        unmapped = dict(
            record,
            caseID="i-en-useauth",
            polishInputText="Open uzoft.ts and add a null check.",
            userPrompts=["Working text:\nOpen uzoft.ts and add a null check."],
        )
        aligned = module.aligned_context_match(unmapped)
        assert aligned is not None
        assert aligned.exact == "useAuth.ts"
        assert aligned.heard == "uzoft.ts"
        assert module.apply_aligned_context_match(
            unmapped["polishInputText"], aligned
        ) == "Open useAuth.ts and add a null check."
        glued = dict(
            unmapped,
            polishInputText="Ouvreusot.ts et ajoute une vérification.",
            userPrompts=["Working text:\nOuvreusot.ts et ajoute une vérification."],
        )
        assert module.aligned_context_match(glued) is None
        unrelated = dict(
            unmapped,
            polishInputText="Please update the documentation.",
            userPrompts=["Working text:\nPlease update the documentation."],
        )
        assert module.aligned_context_match(unrelated) is None
        hinted = module.messages_for(
            unmapped, {}, "current-production-aligned-hint", None,
            {"standard": (standard_system, standard_user), "agent": (system, user)},
        )
        assert "- useAuth.ts: uzoft.ts" in hinted[-1]["content"]
        aligned_preapplied = module.messages_for(
            unmapped, {}, "current-production-aligned-preapply", None,
            {"standard": (standard_system, standard_user), "agent": (system, user)},
        )
        assert "Working text:\nOpen useAuth.ts and add a null check." in aligned_preapplied[-1]["content"]
        assert module.aligned_context_match(record) is None
        assert module.recorded_context_mappings(record) == [
            ("DictationViewModel.swift", "Dictation View Model")
        ]
        assert module.apply_recorded_context_mappings(
            record["polishInputText"], record
        ) == "Open DictationViewModel.swift."
        env_record = dict(record, userPrompts=[
            "Clipboard vocabulary (exact terms):\n- .env.example: env.example\n\n"
            "Working text:\nCopy .env.example."
        ], polishInputText="Copy .env.example.")
        assert module.apply_recorded_context_mappings(
            env_record["polishInputText"], env_record
        ) == "Copy .env.example."
        aliases_record = dict(record, userPrompts=[
            "Clipboard vocabulary (exact terms):\n"
            "- useAuth.ts: use auth, uzoft.ts\n\n"
            "Working text:\nOpen uzoft.ts."
        ], polishInputText="Open uzoft.ts.")
        assert module.recorded_context_mappings(aliases_record) == [
            ("useAuth.ts", "use auth"), ("useAuth.ts", "uzoft.ts")
        ]
        assert module.apply_recorded_context_mappings(
            aliases_record["polishInputText"], aliases_record
        ) == "Open useAuth.ts."
        original_candidates = module.context_candidates
        module.context_candidates = lambda _: [
            module.ContextCandidate("useAuth.ts", "first"),
            module.ContextCandidate("UseAuth.ts", "second"),
        ]
        ambiguous = dict(
            unmapped,
            polishInputText="Open use auth.ts.",
            userPrompts=["Working text:\nOpen use auth.ts."],
        )
        try:
            assert module.aligned_context_match(ambiguous) is None
        finally:
            module.context_candidates = original_candidates
        grounding_preapplied = module.messages_for(
            record, {}, "current-production-grounding-preapply", None,
            {"standard": (standard_system, standard_user), "agent": (system, user)},
        )
        assert "Working text:\nOpen DictationViewModel.swift." in grounding_preapplied[-1]["content"]
        standard_record = dict(record, stratum="punctuation-spacing-migration")
        routed = module.messages_for(
            standard_record, {}, "current-production", None,
            {"standard": (standard_system, standard_user), "agent": (system, user)},
        )
        assert routed[0]["content"] == standard_system

        malformed = dict(record, userPrompts=[
            "Repository vocabulary (exact terms):\nnot a list\n\n"
            "Working text:\nOpen Dictation View Model."
        ])
        try:
            module.make_experiments(
                [malformed], {}, "http://example.test", ["model"],
                ["current-production"],
                {"standard": (standard_system, standard_user), "agent": (system, user)},
            )
        except ValueError as error:
            assert "could not recover every vocabulary block" in str(error)
        else:
            raise AssertionError("current prompt reconstruction failure was swallowed")

        scored = module.score_output(
            {
                "intendedText": "Set NODE_ENV.",
                "requiredTokens": ["NODE_ENV"],
                "forbiddenSubstrings": ["underscore"],
                "caseInsensitive": True,
            },
            "Set node_env underscore.",
        )
        assert not scored["tokensPass"]
        assert scored["missingTokens"] == []
        assert scored["forbiddenTokens"] == ["underscore"]
        old_log_record = {
            "caseID": "b-en-flag-force",
            "intendedText": "Run the deploy script with --force and tell me if it complains.",
            "requiredTokens": ["--force"],
        }
        module.enrich_report_contract([old_log_record])
        assert old_log_record["forbiddenSubstrings"] == ["dash dash"]
        assert old_log_record["caseInsensitive"] is False

        rows = [
            {"caseID": "i-en-name", "stage": "00 raw ASR", "tokensPass": False,
             "matchedTokens": [], "requiredTokenCount": 1},
            {"caseID": "i-en-name", "stage": "25 qwen35-4b current-production", "tokensPass": False,
             "matchedTokens": [], "requiredTokenCount": 1},
            {"caseID": "i-en-name", "stage": "25 qwen36dense-27b current-production", "tokensPass": True,
             "matchedTokens": ["DictationViewModel.swift"], "requiredTokenCount": 1},
            {"caseID": "i-en-name", "stage": "25 qwen35-4b current-production-oracle", "tokensPass": True,
             "matchedTokens": ["DictationViewModel.swift"], "requiredTokenCount": 1},
            {"caseID": "i-en-name", "stage": "25 qwen36dense-27b current-production-oracle", "tokensPass": True,
             "matchedTokens": ["DictationViewModel.swift"], "requiredTokenCount": 1},
        ]
        attribution = module.technical_attribution(
            [record], rows, "qwen35-4b", "qwen36dense-27b", "current-production"
        )
        assert attribution["categories"] == {
            "ceiling recovers where primary misses": ["i-en-name"]
        }
        assert attribution["termCategories"] == {
            "exact evidence lets primary recover": ["i-en-name: DictationViewModel.swift"]
        }
        deltas = module.paired_variant_deltas([
            {"caseID": "a", "stage": "25 model current-production", "output": "wrong",
             "tokensPass": False,
             "matchedTokens": [], "accuracy": 0.5, "surfaceExact": False},
            {"caseID": "a", "stage": "25 model technique", "output": "term",
             "tokensPass": True,
             "matchedTokens": ["term"], "accuracy": 0.8, "surfaceExact": True},
        ])
        assert len(deltas) == 1
        delta = deltas[0]
        assert delta["model"] == "model"
        assert delta["variant"] == "technique"
        assert delta["cases"] == 1
        assert delta["caseGains"] == 1 and delta["caseLosses"] == 0
        assert delta["termGains"] == 1 and delta["termLosses"] == 0
        assert abs(delta["accuracyDelta"] - 0.3) < 1e-9
        assert delta["surfaceDelta"] == 1
        assert delta["largeAccuracyRegressions"] == 0
        assert delta["expansionsVsBaseline"] == 0
        """#
        let run = try runPython(["-c", snippet, script.path])
        XCTAssertEqual(run.status, 0, run.output)
    }

    private func runRecorder(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/record-agent-eval.sh")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func recorderOutputDirectory(label: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EvalRecordings/agent-dictation", isDirectory: true)
            .appendingPathComponent(
                ".tests-\(label)-\(UUID().uuidString)", isDirectory: true
            )
    }

    private func runReportRenderer(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/render-agent-eval-report.sh")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func runAblation(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/ablate-agent-eval.py")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runPython(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"], uniquingKeysWith: { _, testValue in testValue }
        )
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func makeWAV(
        sampleRate: UInt32,
        channels: UInt16,
        bits: UInt16,
        pcmBytes: Int,
        containsSignal: Bool = true,
        chunksBeforeData: [(String, Data)] = [],
        chunksAfterData: [(String, Data)] = []
    ) -> Data {
        var data = Data("RIFF".utf8)
        appendLE32(0, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLE32(16, to: &data)
        appendLE16(1, to: &data)
        appendLE16(channels, to: &data)
        appendLE32(sampleRate, to: &data)
        let blockAlign = channels * (bits / 8)
        appendLE32(sampleRate * UInt32(blockAlign), to: &data)
        appendLE16(blockAlign, to: &data)
        appendLE16(bits, to: &data)
        for chunk in chunksBeforeData { appendChunk(chunk, to: &data) }
        data.append(Data("data".utf8))
        appendLE32(UInt32(pcmBytes), to: &data)
        data.append(Data(repeating: 0, count: pcmBytes))
        if containsSignal, pcmBytes >= 2 { data[data.count - pcmBytes] = 1 }
        for chunk in chunksAfterData { appendChunk(chunk, to: &data) }
        var riffSize = Data()
        appendLE32(UInt32(data.count - 8), to: &riffSize)
        data.replaceSubrange(4..<8, with: riffSize)
        return data
    }

    private func appendChunk(_ chunk: (String, Data), to data: inout Data) {
        XCTAssertEqual(chunk.0.utf8.count, 4)
        data.append(Data(chunk.0.utf8))
        appendLE32(UInt32(chunk.1.count), to: &data)
        data.append(chunk.1)
        if !chunk.1.count.isMultiple(of: 2) { data.append(0) }
    }

    private func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    // MARK: - Pipeline routing

    func testStagePlanPerPipeline() {
        XCTAssertEqual(
            Support.stagePlan(for: .full),
            Support.StagePlan(runsSpeechRecognition: true, runsPolish: true)
        )
        XCTAssertEqual(
            Support.stagePlan(for: .asrOnly),
            Support.StagePlan(runsSpeechRecognition: true, runsPolish: false)
        )
        XCTAssertEqual(
            Support.stagePlan(for: .polishOnly),
            Support.StagePlan(runsSpeechRecognition: false, runsPolish: true)
        )
    }

    /// Every corpus stratum routes: the migration stratum keeps the STANDARD
    /// profile (its required-case baseline was established under the standard
    /// prompt), everything else is agent dictation and gets the terminal
    /// target -> agent profile.
    func testPolishProfileRoutingPerStratum() throws {
        XCTAssertEqual(
            Support.polishTargetBundleID(forStratum: "punctuation-spacing-migration"),
            Support.textFieldTargetBundleID
        )
        XCTAssertFalse(
            TerminalTargetDetector.isTerminalLikeBundleID(Support.textFieldTargetBundleID)
        )
        for stratum in AgentDictationEvalCorpus.expectedStrata
        where stratum != "punctuation-spacing-migration" {
            XCTAssertEqual(
                Support.polishTargetBundleID(forStratum: stratum),
                Support.terminalTargetBundleID
            )
        }
        XCTAssertTrue(
            TerminalTargetDetector.isTerminalLikeBundleID(Support.terminalTargetBundleID)
        )
    }

    // MARK: - Voice picking

    private let sampleVoices = """
        Alex                en_US    # Most people recognize me by my voice.
        Amélie              fr_CA    # Bonjour! Je m'appelle Amélie.
        Bad News            en_US    # The light you see at the end of the tunnel...
        Samantha            en_US    # Hello! My name is Samantha.
        Thomas              fr_FR    # Bonjour! Je m'appelle Thomas.
        """

    func testPickVoicePrefersNamedVoice() {
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: sampleVoices, languagePrefix: "fr",
                preferred: ["Thomas", "Amélie"]
            ),
            "Thomas"
        )
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: sampleVoices, languagePrefix: "en",
                preferred: ["Samantha"]
            ),
            "Samantha"
        )
    }

    func testPickVoiceFallsBackToFirstLanguageMatch() {
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: sampleVoices, languagePrefix: "fr",
                preferred: ["Nonexistent"]
            ),
            "Amélie"
        )
    }

    func testPickVoiceReturnsNilWhenLanguageAbsent() {
        XCTAssertNil(
            Support.pickVoice(
                fromSayVoicesOutput: sampleVoices, languagePrefix: "de", preferred: ["Anna"]
            )
        )
    }

    /// Multi-word names ("Bad News") parse whole, and hyphenated locales
    /// (fr-FR, seen on newer macOS) still match the language prefix.
    func testPickVoiceParsesMultiWordNamesAndHyphenLocales() {
        let output = """
            Bad News            en_US    # ...
            Jacques             fr-FR    # ...
            """
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: output, languagePrefix: "en", preferred: ["Bad News"]
            ),
            "Bad News"
        )
        XCTAssertEqual(
            Support.pickVoice(
                fromSayVoicesOutput: output, languagePrefix: "fr", preferred: []
            ),
            "Jacques"
        )
    }

    // MARK: - Scoring

    /// Cases are built through the loader's decoder (the custom init(from:)
    /// suppresses the memberwise init), which also keeps these tests honest
    /// about the schema.
    private func makeCase(
        id: String = "t-en-sample",
        lang: String = "en",
        spokenForm: String = "spoken",
        intendedText: String = "Intended text.",
        requiredTokens: [String] = ["Intended"],
        forbiddenSubstrings: [String]? = nil,
        caseInsensitive: Bool? = nil,
        featuresJSON: String? = nil,
        status: [String: String] = ["tokens": "known-hard"]
    ) throws -> AgentDictationEvalCorpus.Case {
        var fields: [String] = [
            "\"id\": \(jsonString(id))",
            "\"lang\": \(jsonString(lang))",
            "\"spokenForm\": \(jsonString(spokenForm))",
            "\"intendedText\": \(jsonString(intendedText))",
            "\"requiredTokens\": [\(requiredTokens.map(jsonString).joined(separator: ", "))]",
            "\"status\": {\(status.map { "\(jsonString($0.key)): \(jsonString($0.value))" }.joined(separator: ", "))}",
            "\"notes\": \"unit-test case\"",
        ]
        if let forbiddenSubstrings {
            fields.append(
                "\"forbiddenSubstrings\": [\(forbiddenSubstrings.map(jsonString).joined(separator: ", "))]"
            )
        }
        if let caseInsensitive {
            fields.append("\"caseInsensitive\": \(caseInsensitive)")
        }
        if let featuresJSON {
            fields.append("\"features\": \(featuresJSON)")
        }
        let json = "{\(fields.joined(separator: ", "))}"
        return try JSONDecoder().decode(
            AgentDictationEvalCorpus.Case.self, from: Data(json.utf8)
        )
    }

    private func jsonString(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    func testTokensRequiredAreCaseSensitiveByDefault() throws {
        let evalCase = try makeCase(requiredTokens: ["UserSessionManager.swift"])
        XCTAssertEqual(
            Support.tokensFailures(
                output: "Open UserSessionManager.swift now.", evalCase: evalCase
            ),
            []
        )
        XCTAssertEqual(
            Support.tokensFailures(
                output: "open usersessionmanager.swift now.", evalCase: evalCase
            ),
            ["missing \"UserSessionManager.swift\""]
        )
    }

    func testTokensRequiredHonorCaseInsensitiveFlag() throws {
        let evalCase = try makeCase(requiredTokens: ["tomorrow?"], caseInsensitive: true)
        XCTAssertEqual(
            Support.tokensFailures(output: "TOMORROW?", evalCase: evalCase),
            []
        )
    }

    func testForbiddenSubstringsAlwaysCaseInsensitive() throws {
        let evalCase = try makeCase(
            requiredTokens: ["retry"],
            forbiddenSubstrings: ["dash dash"]
        )
        XCTAssertEqual(
            Support.tokensFailures(output: "retry with DASH DASH force", evalCase: evalCase),
            ["contains forbidden \"dash dash\""]
        )
    }

    /// Spacing normalization applies to needle and haystack: a French narrow
    /// no-break space in the output satisfies a plain-space needle.
    func testTokensMatchAfterSpacingNormalization() throws {
        let evalCase = try makeCase(requiredTokens: ["plan :"])
        XCTAssertEqual(
            Support.tokensFailures(output: "Voici le plan\u{202F}: demain.", evalCase: evalCase),
            []
        )
    }

    func testExactTextComparesNormalizedWholeString() throws {
        let evalCase = try makeCase(intendedText: "Voici le plan : on commence.")
        XCTAssertNil(
            Support.exactTextFailure(
                output: "Voici le plan\u{202F}:  on commence.", evalCase: evalCase
            )
        )
        XCTAssertNotNil(
            Support.exactTextFailure(
                output: "Voici le plan : on commence. Extra.", evalCase: evalCase
            )
        )
        // Case-sensitive by default.
        XCTAssertNotNil(
            Support.exactTextFailure(
                output: "voici le plan : on commence.", evalCase: evalCase
            )
        )
    }

    func testExactTextHonorsCaseInsensitiveFlag() throws {
        let evalCase = try makeCase(intendedText: "Are you coming?", caseInsensitive: true)
        XCTAssertNil(
            Support.exactTextFailure(output: "are you coming?", evalCase: evalCase)
        )
    }

    func testAntiRewriteGuardTripsOnRewrite() throws {
        let evalCase = try makeCase()
        XCTAssertNotNil(
            Support.antiRewriteFailure(
                polishInput: "fix the bug in the auth module please",
                output: "Certainly! Here is a plan for your authentication improvements",
                evalCase: evalCase
            )
        )
        XCTAssertNil(
            Support.antiRewriteFailure(
                polishInput: "fix the bug in the auth module please",
                output: "Fix the bug in the auth module, please.",
                evalCase: evalCase
            )
        )
    }

    /// Positive macro cases embed the clipboard payload — a legitimate large
    /// insertion that must never trip the anti-rewrite floor.
    func testAntiRewriteGuardExemptsPositiveMacroCases() throws {
        let macroCase = try makeCase(
            featuresJSON: "{\"clipboard\": \"payload\", \"macro\": true}"
        )
        XCTAssertNil(
            Support.antiRewriteFailure(
                polishInput: "fix this $LV_CLIPBOARD_PAYLOAD now",
                output: "Fix this: a very long embedded clipboard payload with many words "
                    + "that dwarfs the dictated sentence entirely now",
                evalCase: macroCase
            )
        )
        // Negative macro cases (macro: false) keep the floor.
        let negativeCase = try makeCase(
            featuresJSON: "{\"clipboard\": \"payload\", \"macro\": false}"
        )
        XCTAssertNotNil(
            Support.antiRewriteFailure(
                polishInput: "do not paste anything",
                output: "Completely unrelated rewritten sentence about other things entirely",
                evalCase: negativeCase
            )
        )
    }

    // MARK: - Scoreboard rendering

    private func makeResult(
        caseID: String,
        stratum: String = "symbol-forms",
        status: [String: AgentDictationEvalCorpus.Status] = ["tokens": .knownHard]
    ) -> Support.CaseResult {
        Support.CaseResult(
            caseID: caseID,
            stratum: stratum,
            pipeline: .full,
            lang: .en,
            statusByMetric: status,
            output: "output text"
        )
    }

    func testScoreboardCollectsRequiredFailuresIndividually() {
        var failing = makeResult(
            caseID: "e-en-question",
            stratum: "punctuation-spacing-migration",
            status: ["tokens": .required, "exactText": .required]
        )
        failing.tokensFailures = ["missing \"tomorrow?\""]
        failing.exactTextFailures = []
        var passing = makeResult(
            caseID: "e-fr-colon",
            stratum: "punctuation-spacing-migration",
            status: ["tokens": .required, "exactText": .required]
        )
        passing.exactTextFailures = []

        let board = Support.renderScoreboard(
            results: [failing, passing], header: "unit test board"
        )
        XCTAssertEqual(board.requiredFailures.count, 1)
        XCTAssertTrue(board.requiredFailures[0].contains("e-en-question"))
        XCTAssertTrue(board.requiredFailures[0].contains("[tokens]"))
        XCTAssertTrue(board.requiredFailures[0].contains("missing \"tomorrow?\""))
        XCTAssertTrue(board.text.contains("FAIL e-en-question [required]"))
        XCTAssertTrue(board.text.contains("PASS e-fr-colon"))
        XCTAssertTrue(board.text.contains("required: 3/4 metric checks passed"))
    }

    func testScoreboardKnownHardFailureIsXFAILNotRequiredFailure() {
        var xfail = makeResult(caseID: "b-en-flag")
        xfail.tokensFailures = ["missing \"--force\""]
        var pass = makeResult(caseID: "b-en-port")
        pass.guardOffTokensFailures = ["missing \"8080\""]

        let board = Support.renderScoreboard(results: [xfail, pass], header: "h")
        XCTAssertTrue(board.requiredFailures.isEmpty)
        XCTAssertTrue(board.text.contains("XFAIL b-en-flag (known-hard)"))
        XCTAssertTrue(board.text.contains("PASS b-en-port"))
        // Raw-model column annotated, and a deterministic post-model change
        // counted (production pass, raw model output fail).
        XCTAssertTrue(board.text.contains("raw-model tokens: FAIL"))
        XCTAssertTrue(board.text.contains("post-model safety changed 1 case(s)"))
    }

    func testScoreboardSkipAndInfraErrorRows() {
        var skipped = makeResult(caseID: "b-fr-voice")
        skipped.skipReason = "no French TTS voice installed"
        var errored = makeResult(caseID: "b-en-conn")
        errored.infraFailure = "ASR websocket timed out"

        let board = Support.renderScoreboard(results: [skipped, errored], header: "h")
        XCTAssertTrue(board.text.contains("SKIP b-fr-voice — no French TTS voice installed"))
        XCTAssertTrue(board.text.contains("ERROR b-en-conn — ASR websocket timed out"))
        XCTAssertTrue(board.requiredFailures.isEmpty)
        XCTAssertEqual(board.infraFailures, ["infra error on b-en-conn: ASR websocket timed out"])
        XCTAssertTrue(board.text.contains("skipped 1, errors 1"))
    }

    /// Review finding (2026-07-12): a REQUIRED case that never ran
    /// (environmental skip, e.g. a missing TTS voice after Phase-3 promotes a
    /// TTS-dependent case) must count as a required failure — a required
    /// metric demands a measurement, and silence must never read as a pass.
    /// Known-hard skips stay non-fatal.
    func testScoreboardSkippedRequiredCaseCountsAsRequiredFailure() {
        var requiredSkipped = makeResult(
            caseID: "e-en-question",
            stratum: "punctuation-spacing-migration",
            status: ["tokens": .required, "exactText": .required]
        )
        requiredSkipped.skipReason = "no French TTS voice installed"
        var knownHardSkipped = makeResult(caseID: "b-fr-glob")
        knownHardSkipped.skipReason = "no French TTS voice installed"

        let board = Support.renderScoreboard(
            results: [requiredSkipped, knownHardSkipped], header: "h"
        )
        XCTAssertEqual(board.requiredFailures.count, 1)
        XCTAssertTrue(board.requiredFailures[0].contains("e-en-question"))
        XCTAssertTrue(board.requiredFailures[0].contains("skipped without running"))
        XCTAssertTrue(
            board.text.contains(
                "SKIP e-en-question — no French TTS voice installed "
                    + "[required case — skip counts as failure]"
            )
        )
        // The known-hard skip stays a plain, non-fatal SKIP line.
        XCTAssertTrue(board.text.contains("SKIP b-fr-glob — no French TTS voice installed"))
        XCTAssertFalse(board.text.contains("b-fr-glob — no French TTS voice installed [required"))
        XCTAssertTrue(board.text.contains("skipped 2"))
    }

    func testScoreboardWrapsInExtractionMarkers() {
        let board = Support.renderScoreboard(results: [makeResult(caseID: "x")], header: "h")
        XCTAssertTrue(board.text.hasPrefix(Support.scoreboardBeginMarker))
        XCTAssertTrue(board.text.hasSuffix(Support.scoreboardEndMarker))
    }

    func testScoreboardGroupsByStratumWithSummaries() {
        var a = makeResult(caseID: "a-en-one", stratum: "plain-asr-baseline")
        a.wordAccuracyVsIntended = 0.8
        var b = makeResult(caseID: "b-en-two", stratum: "symbol-forms")
        b.wordAccuracyVsIntended = 1.0
        b.exactTextFailures = []

        let board = Support.renderScoreboard(results: [a, b], header: "h")
        XCTAssertTrue(board.text.contains("-- plain-asr-baseline (pipeline full, 1 cases) --"))
        XCTAssertTrue(
            board.text.contains(
                "-- plain-asr-baseline summary: tokens 1/1, exactText 0/0, "
                    + "mean word-accuracy vs intended 0.80 --"
            )
        )
        XCTAssertTrue(
            board.text.contains(
                "-- symbol-forms summary: tokens 1/1, exactText 1/1, "
                    + "mean word-accuracy vs intended 1.00 --"
            )
        )
    }

    // MARK: - Inspection report

    func testInspectionReportRendersSentinelDelimitedJSONL() throws {
        let evalCase = try makeCase(
            id: "r-en-report",
            spokenForm: "open use auth dot t s",
            intendedText: "Open `useAuth.ts`.",
            requiredTokens: ["useAuth.ts"]
        )
        var result = makeResult(caseID: "r-en-report")
        result.output = "Open `useAuth.ts`."
        result.rewriteFailure = "word accuracy vs input 0.20 < 0.8 (rewrote the text)"
        result.rewriteIsFatal = false
        result.wordAccuracyVsIntended = 1.0
        var capture = Support.CaseCapture()
        capture.transcript = "open use auth dot t s"
        capture.polishSystemPrompt = "SYSTEM PROMPT"
        capture.polishUserPrompts = ["user prompt with\nnewline"]
        capture.polishInputText = "open use auth dot t s"
        capture.rawModelOutput = "Open `useAuth.ts`."

        let record = Support.makeReportRecord(
            evalCase: evalCase, result: result, capture: capture, systemPromptIndex: 0
        )
        let report = try Support.renderReport(
            header: Support.ReportHeader(
                polishModel: "polish-model", asrModel: "asr-model",
                audioSource: "human-recorded/owner",
                systemPrompts: ["SYSTEM PROMPT"]
            ),
            records: [record]
        )

        let lines = report.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, Support.reportBeginSentinel)
        XCTAssertEqual(lines.last, Support.reportEndSentinel)
        // Sentinels + header + one record, each JSON value on ONE line (the
        // remote log is line-oriented; embedded newlines must stay escaped).
        XCTAssertEqual(lines.count, 4)

        let header = try JSONDecoder().decode(
            Support.ReportHeader.self, from: Data(lines[1].utf8)
        )
        XCTAssertEqual(header.systemPrompts, ["SYSTEM PROMPT"])
        XCTAssertEqual(header.audioSource, "human-recorded/owner")

        let decoded = try JSONDecoder().decode(
            Support.CaseReportRecord.self, from: Data(lines[2].utf8)
        )
        XCTAssertEqual(decoded.caseID, "r-en-report")
        XCTAssertEqual(decoded.spokenForm, "open use auth dot t s")
        XCTAssertEqual(decoded.intendedText, "Open `useAuth.ts`.")
        XCTAssertEqual(decoded.forbiddenSubstrings, [])
        XCTAssertFalse(decoded.caseInsensitive)
        XCTAssertEqual(decoded.transcript, "open use auth dot t s")
        XCTAssertEqual(decoded.systemPromptIndex, 0)
        XCTAssertEqual(decoded.userPrompts, ["user prompt with\nnewline"])
        XCTAssertEqual(decoded.rawModelOutput, "Open `useAuth.ts`.")
        XCTAssertEqual(decoded.output, "Open `useAuth.ts`.")
        XCTAssertEqual(decoded.rewriteFailure, result.rewriteFailure)
        XCTAssertEqual(decoded.rewriteIsFatal, false)
        XCTAssertEqual(decoded.wordAccuracyVsIntended, 1.0)
    }
}
