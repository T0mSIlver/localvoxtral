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
