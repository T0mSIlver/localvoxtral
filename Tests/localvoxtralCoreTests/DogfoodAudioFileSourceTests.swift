#if DEBUG || LOCALVOXTRAL_E2E_HARNESS

import Foundation
import Synchronization
import XCTest

import localvoxtralTestSupport
@testable import localvoxtralCore

final class DogfoodAudioFileSourceTests: XCTestCase {
    // MARK: - WAV parsing

    func testParsesMono16BitPCMAt16kHz() throws {
        let samples = Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00])
        XCTAssertEqual(try DogfoodAudioFileSource.pcm16(fromWAV: DogfoodWAV.make(pcm: samples)), samples)
    }

    func testParsesASliceWhoseIndicesDoNotStartAtZero() throws {
        let samples = Data([0x01, 0x00, 0x02, 0x00])
        let slice = (Data([0xFF]) + DogfoodWAV.make(pcm: samples)).dropFirst()
        XCTAssertEqual(slice.startIndex, 1)
        XCTAssertEqual(try DogfoodAudioFileSource.pcm16(fromWAV: slice), samples)
    }

    func testSkipsAnOddSizedChunkBeforeTheData() throws {
        // RIFF pads an odd-sized chunk to an even offset. A parser that forgets
        // the pad byte reads the next chunk header one byte early.
        let samples = Data([0x0A, 0x00, 0x0B, 0x00])
        let wav = DogfoodWAV.make(pcm: samples, extraChunkBeforeData: ("LIST", Data([1, 2, 3])))
        XCTAssertEqual(try DogfoodAudioFileSource.pcm16(fromWAV: wav), samples)
    }

    func testRefusesWhatItWouldHaveToResample() {
        let samples = Data(count: 64)
        let cases: [(String, Data)] = [
            ("stereo", DogfoodWAV.make(pcm: samples, channels: 2)),
            ("44.1 kHz", DogfoodWAV.make(pcm: samples, sampleRate: 44_100)),
            ("8-bit", DogfoodWAV.make(pcm: samples, bitsPerSample: 8)),
            ("float", DogfoodWAV.make(pcm: samples, formatCode: 3)),
        ]
        for (name, wav) in cases {
            XCTAssertThrowsError(try DogfoodAudioFileSource.pcm16(fromWAV: wav), name) { error in
                XCTAssertEqual(error as? DogfoodAudioFileSource.LoadError, .unsupportedFormat, name)
            }
        }
    }

    func testRefusesMalformedFiles() {
        let valid = DogfoodWAV.make(pcm: Data(count: 64))
        let cases: [(String, Data, DogfoodAudioFileSource.LoadError)] = [
            ("not RIFF", Data("hello, this is not audio".utf8), .notWAV),
            ("too short", Data([0x52, 0x49]), .notWAV),
            ("truncated data chunk", valid.dropLast(10), .truncatedChunk),
            ("no fmt chunk", DogfoodWAV.make(pcm: Data(count: 64), includeFormat: false), .missingFormat),
            ("no samples", DogfoodWAV.make(pcm: Data()), .noSamples),
        ]
        for (name, wav, expected) in cases {
            XCTAssertThrowsError(try DogfoodAudioFileSource.pcm16(fromWAV: Data(wav)), name) { error in
                XCTAssertEqual(error as? DogfoodAudioFileSource.LoadError, expected, name)
            }
        }
    }

    func testAMissingFileIsUnreadable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-audio-missing-\(UUID().uuidString).wav")
        XCTAssertThrowsError(try DogfoodAudioFileSource(contentsOf: url)) { error in
            XCTAssertEqual(error as? DogfoodAudioFileSource.LoadError, .unreadable)
        }
    }

    // MARK: - Environment

    func testTheEnvironmentNamesTheFileOnlyByAbsolutePath() {
        let key = DogfoodAudioFileSource.environmentKey
        XCTAssertNil(DogfoodAudioFileSource.fileURL(fromEnvironment: [:]))
        XCTAssertNil(DogfoodAudioFileSource.fileURL(fromEnvironment: [key: ""]))
        XCTAssertNil(DogfoodAudioFileSource.fileURL(fromEnvironment: [key: "fixtures/a.wav"]))
        XCTAssertEqual(
            DogfoodAudioFileSource.fileURL(fromEnvironment: [key: "/tmp/a.wav"])?.path,
            "/tmp/a.wav")
    }

    // MARK: - Delivery

    func testDeliversTheFileInRealTimeChunksThenSilence() async {
        let chunkBytes = DogfoodAudioFileSource.chunkByteCount
        let pcm = Data((0..<(chunkBytes * 2 + chunkBytes / 2)).map { UInt8($0 % 251 + 1) })
        let sleeps = Mutex<[Duration]>([])
        let collector = DogfoodChunkCollector()
        let source = DogfoodAudioFileSource(pcm: pcm) { duration in
            sleeps.withLock { $0.append(duration) }
            try Task.checkCancellation()
            await Task.yield()
        }

        source.start { collector.append($0) }
        await collector.waitForChunks(5)
        source.stop()

        let chunks = collector.chunks
        XCTAssertEqual(chunks[0], pcm.subdata(in: 0..<chunkBytes))
        XCTAssertEqual(chunks[1], pcm.subdata(in: chunkBytes..<(chunkBytes * 2)))
        XCTAssertEqual(chunks[2], pcm.subdata(in: (chunkBytes * 2)..<pcm.count))
        XCTAssertEqual(chunks[3], Data(count: chunkBytes))
        XCTAssertEqual(chunks[4], Data(count: chunkBytes))
        let recorded = sleeps.withLock { $0 }
        XCTAssertFalse(recorded.isEmpty)
        XCTAssertTrue(recorded.allSatisfy { $0 == DogfoodAudioFileSource.chunkDuration })
    }

    /// `stopDictation` flushes the chunk buffer right after stopping capture. A
    /// chunk delivered after `stop()` returned would sit in the buffer and be
    /// sent as the first audio of the NEXT dictation.
    func testNoChunkArrivesAfterStopReturns() async {
        let collector = DogfoodChunkCollector()
        let gate = DogfoodSleepGate()
        let source = DogfoodAudioFileSource(pcm: Data(count: 64)) { _ in try await gate.sleep() }

        source.start { collector.append($0) }
        await gate.waitForEntries(1)
        let producer = source.currentTask
        source.stop()
        gate.release()
        await producer?.value

        XCTAssertEqual(collector.chunks.count, 1)
    }

    func testRestartingPlaysTheFileFromItsBeginning() async {
        let chunkBytes = DogfoodAudioFileSource.chunkByteCount
        let pcm = Data(repeating: 7, count: chunkBytes)
        let gate = DogfoodSleepGate()
        let source = DogfoodAudioFileSource(pcm: pcm) { _ in try await gate.sleep() }

        let first = DogfoodChunkCollector()
        source.start { first.append($0) }
        await gate.waitForEntries(1)
        let firstProducer = source.currentTask

        let second = DogfoodChunkCollector()
        source.start { second.append($0) }
        await gate.waitForEntries(2)
        let secondProducer = source.currentTask
        source.stop()
        gate.release()
        await firstProducer?.value
        await secondProducer?.value

        XCTAssertEqual(first.chunks, [pcm])
        XCTAssertEqual(second.chunks, [pcm])
    }
}

#endif
