#if LOCALVOXTRAL_DOGFOOD

import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

final class DogfoodAudioFileSourceTests: XCTestCase {
    // MARK: - WAV parsing

    func testParsesMono16BitPCMAt16kHz() throws {
        let samples = Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00])
        XCTAssertEqual(try DogfoodAudioFileSource.pcm16(fromWAV: Self.wav(pcm: samples)), samples)
    }

    func testParsesASliceWhoseIndicesDoNotStartAtZero() throws {
        let samples = Data([0x01, 0x00, 0x02, 0x00])
        let slice = (Data([0xFF]) + Self.wav(pcm: samples)).dropFirst()
        XCTAssertEqual(slice.startIndex, 1)
        XCTAssertEqual(try DogfoodAudioFileSource.pcm16(fromWAV: slice), samples)
    }

    func testSkipsAnOddSizedChunkBeforeTheData() throws {
        // RIFF pads an odd-sized chunk to an even offset. A parser that forgets
        // the pad byte reads the next chunk header one byte early.
        let samples = Data([0x0A, 0x00, 0x0B, 0x00])
        let wav = Self.wav(pcm: samples, extraChunkBeforeData: ("LIST", Data([1, 2, 3])))
        XCTAssertEqual(try DogfoodAudioFileSource.pcm16(fromWAV: wav), samples)
    }

    func testRefusesWhatItWouldHaveToResample() {
        let samples = Data(count: 64)
        let cases: [(String, Data)] = [
            ("stereo", Self.wav(pcm: samples, channels: 2)),
            ("44.1 kHz", Self.wav(pcm: samples, sampleRate: 44_100)),
            ("8-bit", Self.wav(pcm: samples, bitsPerSample: 8)),
            ("float", Self.wav(pcm: samples, formatCode: 3)),
        ]
        for (name, wav) in cases {
            XCTAssertThrowsError(try DogfoodAudioFileSource.pcm16(fromWAV: wav), name) { error in
                XCTAssertEqual(error as? DogfoodAudioFileSource.LoadError, .unsupportedFormat, name)
            }
        }
    }

    func testRefusesMalformedFiles() {
        let valid = Self.wav(pcm: Data(count: 64))
        let cases: [(String, Data, DogfoodAudioFileSource.LoadError)] = [
            ("not RIFF", Data("hello, this is not audio".utf8), .notWAV),
            ("too short", Data([0x52, 0x49]), .notWAV),
            ("truncated data chunk", valid.dropLast(10), .truncatedChunk),
            ("no fmt chunk", Self.wav(pcm: Data(count: 64), includeFormat: false), .missingFormat),
            ("no samples", Self.wav(pcm: Data()), .noSamples),
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
        let collector = ChunkCollector()
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
        let collector = ChunkCollector()
        let gate = SleepGate()
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
        let gate = SleepGate()
        let source = DogfoodAudioFileSource(pcm: pcm) { _ in try await gate.sleep() }

        let first = ChunkCollector()
        source.start { first.append($0) }
        await gate.waitForEntries(1)
        let firstProducer = source.currentTask

        let second = ChunkCollector()
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

    // MARK: - View model

    @MainActor
    func testAFileFedSessionNeverTouchesTheMicrophone() async throws {
        let chunkBytes = DogfoodAudioFileSource.chunkByteCount
        let pcm = Data(repeating: 9, count: chunkBytes)
        let url = try writeTemporaryWAV(pcm: pcm)
        let viewModel = makeViewModel()
        viewModel.audio.dogfoodAudioFileURL = url
        let gate = SleepGate()
        viewModel.audio.dogfoodAudioFileSleep = { _ in try await gate.sleep() }

        XCTAssertFalse(viewModel.capturesFromMicrophone)
        XCTAssertEqual(viewModel.currentMicrophoneAuthorizationStatus(), .authorized)

        let collector = ChunkCollector()
        try viewModel.audio.startSessionAudioCapture(preferredDeviceID: nil) { collector.append($0) }
        await gate.waitForEntries(1)
        let producer = viewModel.audio.dogfoodAudioFileSource?.currentTask
        XCTAssertNotNil(producer)
        viewModel.audio.stopSessionAudioCapture()
        gate.release()
        await producer?.value

        XCTAssertEqual(collector.chunks, [pcm])
        XCTAssertNil(viewModel.audio.dogfoodAudioFileSource)
        XCTAssertFalse(viewModel.audio.hasInitializedMicrophone)
    }

    /// Falling back to the microphone would let an end-to-end run pass or fail
    /// on the room's noise, so an unusable file fails the session start.
    @MainActor
    func testAnUnusableFileFailsTheStartInsteadOfFallingBackToTheMicrophone() throws {
        let viewModel = makeViewModel()
        viewModel.audio.dogfoodAudioFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-audio-missing-\(UUID().uuidString).wav")

        XCTAssertThrowsError(
            try viewModel.audio.startSessionAudioCapture(preferredDeviceID: nil) { _ in }
        ) { error in
            XCTAssertEqual(error as? DogfoodAudioFileSource.LoadError, .unreadable)
        }
        XCTAssertNil(viewModel.audio.dogfoodAudioFileSource)
        XCTAssertFalse(viewModel.audio.hasInitializedMicrophone)
    }

    @MainActor
    func testWithoutAFileTheMicrophoneStaysTheSource() {
        let viewModel = makeViewModel()
        viewModel.audio.dogfoodAudioFileURL = nil
        XCTAssertTrue(viewModel.capturesFromMicrophone)
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.DogfoodAudioFileSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        return DictationViewModel(settings: settings, startRuntimeServices: false)
    }

    private func writeTemporaryWAV(pcm: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-audio-\(UUID().uuidString).wav")
        try Self.wav(pcm: pcm).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static func wav(
        pcm: Data,
        formatCode: UInt16 = 1,
        channels: UInt16 = 1,
        sampleRate: UInt32 = 16_000,
        bitsPerSample: UInt16 = 16,
        includeFormat: Bool = true,
        extraChunkBeforeData: (id: String, body: Data)? = nil
    ) -> Data {
        func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
        func le32(_ value: UInt32) -> Data {
            Data((0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
        }
        func chunk(_ id: String, _ body: Data) -> Data {
            var data = Data(id.utf8) + le32(UInt32(body.count)) + body
            if !body.count.isMultiple(of: 2) { data.append(0) }
            return data
        }

        var body = Data("WAVE".utf8)
        if includeFormat {
            let blockAlign = channels * bitsPerSample / 8
            body += chunk(
                "fmt ",
                le16(formatCode) + le16(channels) + le32(sampleRate)
                    + le32(sampleRate * UInt32(blockAlign)) + le16(blockAlign)
                    + le16(bitsPerSample))
        }
        if let extraChunkBeforeData {
            body += chunk(extraChunkBeforeData.id, extraChunkBeforeData.body)
        }
        body += chunk("data", pcm)
        return Data("RIFF".utf8) + le32(UInt32(body.count)) + body
    }
}

/// A sleep that parks the producer until the test releases it, and IGNORES
/// cancellation while parked: the worst sleep a stop has to hold against. Once
/// released, a parked sleep returns normally and any later sleep throws, so a
/// producer that outlived its stop delivers one more chunk and then ends,
/// which fails the count assertion instead of hanging the suite.
private final class SleepGate: Sendable {
    private struct State {
        var entries = 0
        var released = false
        var sleepers: [CheckedContinuation<Void, Never>] = []
        var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    func sleep() async throws {
        if state.withLock({ $0.released }) { throw CancellationError() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (resumeNow, reached) = state.withLock {
                state -> (Bool, [CheckedContinuation<Void, Never>]) in
                state.entries += 1
                let reached = state.entryWaiters.filter { $0.count <= state.entries }
                state.entryWaiters.removeAll { $0.count <= state.entries }
                if state.released { return (true, reached.map(\.continuation)) }
                state.sleepers.append(continuation)
                return (false, reached.map(\.continuation))
            }
            reached.forEach { $0.resume() }
            if resumeNow { continuation.resume() }
        }
    }

    /// Returns once `count` sleeps have been entered, which is also once
    /// `count` chunks have been delivered by producers that are now parked.
    func waitForEntries(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard state.entries < count else { return true }
                state.entryWaiters.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let sleepers = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.sleepers = [] }
            return state.sleepers
        }
        sleepers.forEach { $0.resume() }
    }
}

private final class ChunkCollector: Sendable {
    private struct State {
        var chunks: [Data] = []
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var chunks: [Data] { state.withLock { $0.chunks } }

    func append(_ chunk: Data) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.chunks.append(chunk)
            let reached = state.waiters.filter { $0.count <= state.chunks.count }
            state.waiters.removeAll { $0.count <= state.chunks.count }
            return reached.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    func waitForChunks(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard state.chunks.count < count else { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

#endif
