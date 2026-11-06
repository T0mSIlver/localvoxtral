import XCTest

@testable import SpeechEngineText

final class SpeechASREngineKindTests: XCTestCase {
    func testRepoIDsMapToTheirEngine() {
        XCTAssertEqual(
            SpeechASREngineKind.infer(
                fromModelID: "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead"
            ),
            .voxtral
        )
        XCTAssertEqual(
            SpeechASREngineKind.infer(
                fromModelID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
            ),
            .nemotron
        )
        // Case-insensitive, because repo ids are not.
        XCTAssertEqual(
            SpeechASREngineKind.infer(fromModelID: "mlx-community/Nemotron-3.5-ASR-streaming-0.6b"),
            .nemotron
        )
    }

    /// The catalog's `--engine` decides, whatever the repo id is called.
    func testANamedEngineWinsOverTheModelID() {
        XCTAssertEqual(
            SpeechASREngineKind.resolve(
                named: .nemotron, modelID: "someone/custom-asr", modelDirectory: nil
            ),
            .nemotron
        )
        XCTAssertEqual(
            SpeechASREngineKind.resolve(
                named: .voxtral, modelID: "mlx-community/nemotron-3.5-asr", modelDirectory: nil
            ),
            .voxtral
        )
        XCTAssertEqual(
            SpeechASREngineKind.resolve(
                named: nil, modelID: "mlx-community/nemotron-3.5-asr", modelDirectory: nil
            ),
            .nemotron
        )
    }

    func testAnUnknownOrAbsentModelIDKeepsTheVoxtralDefault() {
        XCTAssertEqual(SpeechASREngineKind.infer(fromModelID: nil), .voxtral)
        XCTAssertEqual(SpeechASREngineKind.infer(fromModelID: "someone/custom-asr"), .voxtral)
    }

    func testAModelDirectoryIsClassifiedByItsConfigModelType() throws {
        XCTAssertEqual(
            SpeechASREngineKind.infer(
                fromModelDirectory: try makeCheckpoint(#"{"model_type":"nemotron_asr"}"#)
            ),
            .nemotron
        )
        XCTAssertEqual(
            SpeechASREngineKind.infer(
                fromModelDirectory: try makeCheckpoint(#"{"model_type":"voxtral_realtime"}"#)
            ),
            .voxtral
        )
    }

    /// A directory the helper cannot classify must behave exactly as it did
    /// before a second engine existed.
    func testAnUnreadableCheckpointKeepsTheVoxtralDefault() throws {
        XCTAssertEqual(
            SpeechASREngineKind.infer(fromModelDirectory: try makeCheckpoint("not json")),
            .voxtral
        )
        XCTAssertEqual(
            SpeechASREngineKind.infer(
                fromModelDirectory: FileManager.default.temporaryDirectory
                    .appending(path: "speech-engine-kind-missing-\(UUID().uuidString)")
            ),
            .voxtral
        )
    }

    private func makeCheckpoint(_ config: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "speech-engine-kind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(config.utf8).write(to: directory.appending(path: "config.json"))
        return directory
    }
}

final class NemotronChunkLadderTests: XCTestCase {
    func testEveryRungMapsToItself() {
        for rung in NemotronChunkLadder.supportedMilliseconds {
            XCTAssertEqual(
                NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: rung),
                rung
            )
        }
    }

    /// The chunk is how long the engine holds text back, so it must never
    /// exceed the delay the caller asked for.
    func testABetweenRungsDelayRoundsDown() {
        XCTAssertEqual(NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: 159), 80)
        XCTAssertEqual(NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: 500), 320)
        XCTAssertEqual(NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: 5_000), 1_120)
    }

    func testADelayUnderTheBottomRungGetsTheBottomRung() {
        XCTAssertEqual(NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: 1), 80)
    }

    func testNoDelayGetsTheDefault() {
        XCTAssertEqual(
            NemotronChunkLadder.chunkMilliseconds(forTranscriptionDelayMs: nil),
            NemotronChunkLadder.defaultMilliseconds
        )
        XCTAssertTrue(
            NemotronChunkLadder.supportedMilliseconds
                .contains(NemotronChunkLadder.defaultMilliseconds)
        )
    }
}

final class NemotronUnifiedLayoutTests: XCTestCase {
    private func frames(_ delay: Int?) -> [Int] {
        NemotronUnifiedLayout.frames(forTranscriptionDelayMs: delay)
    }

    /// Unified takes every 80 ms step from 160 to 2080 ms, not 3.5's rungs: the
    /// latency (chunk + right) is the delay rounded down to a frame.
    func testEveryEightyMillisecondStepKeepsItsLatency() {
        for step in stride(from: 160, through: 2080, by: 80) {
            for delay in [step, step + 79] {
                let f = frames(delay)
                XCTAssertEqual(f[0], 70, "\(delay) ms")
                XCTAssertEqual((f[1] + f[2]) * 80, step, "\(delay) ms")
                XCTAssertGreaterThanOrEqual(f[1], 1, "\(delay) ms")
                XCTAssertGreaterThanOrEqual(f[2], 1, "\(delay) ms")
            }
        }
    }

    /// NVIDIA's rows, except 320 ms (speechd's default) on a 2-frame chunk; a latency
    /// between rows takes the lower row's chunk; outside 160-2080 ms it clamps.
    func testNvidiasRowsSpeechdsDefaultAndTheClamp() {
        XCTAssertEqual(frames(nil), [70, 2, 2])
        XCTAssertEqual(frames(320), [70, 2, 2])
        XCTAssertEqual(frames(160), [70, 1, 1])
        XCTAssertEqual(frames(240), [70, 1, 2])
        XCTAssertEqual(frames(560), [70, 2, 5])
        XCTAssertEqual(frames(1120), [70, 7, 7])
        XCTAssertEqual(frames(2080), [70, 13, 13])
        XCTAssertEqual(frames(400), [70, 2, 3])
        XCTAssertEqual(frames(1600), [70, 7, 13])
        XCTAssertEqual(frames(80), [70, 1, 1])
        XCTAssertEqual(frames(5000), [70, 13, 13])
    }

    func testRecognizesABufferedCheckpointFromItsConfig() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "unified-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ style: String) throws {
            let json = #"{"model_type":"nemotron_asr","encoder":{"att_context_style":"\#(style)"}}"#
            try Data(json.utf8).write(to: root.appending(path: "config.json"))
        }
        try write("chunked_limited_with_rc")
        XCTAssertTrue(NemotronUnifiedLayout.isBufferedCheckpoint(directory: root))
        try write("chunked_limited")
        XCTAssertFalse(NemotronUnifiedLayout.isBufferedCheckpoint(directory: root))
        XCTAssertFalse(NemotronUnifiedLayout.isBufferedCheckpoint(directory: root.appending(path: "missing")))
    }
}
