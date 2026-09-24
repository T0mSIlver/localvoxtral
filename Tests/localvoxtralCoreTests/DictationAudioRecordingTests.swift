import Foundation
import XCTest
@testable import localvoxtralCore

final class DictationAudioRecordingTests: XCTestCase {
    func testAnEnabledRecordingKeepsEveryChunkInOrder() {
        let recording = DictationAudioRecording()
        recording.begin(enabled: true)
        recording.append(Data([1, 2]))
        recording.append(Data([3, 4]))

        XCTAssertEqual(recording.finish(), Data([1, 2, 3, 4]))
        // Finished: nothing more is kept until the next begin.
        recording.append(Data([5, 6]))
        XCTAssertNil(recording.finish())
    }

    func testADisabledRecordingKeepsNothing() {
        let recording = DictationAudioRecording()
        recording.begin(enabled: false)
        recording.append(Data([1, 2]))

        XCTAssertNil(recording.finish())
    }

    func testBeginDropsWhatAnUnfinishedSessionLeft() {
        let recording = DictationAudioRecording()
        recording.begin(enabled: true)
        recording.append(Data([1, 2]))
        recording.begin(enabled: true)
        recording.append(Data([3, 4]))

        XCTAssertEqual(recording.finish(), Data([3, 4]))
    }

    func testARecordingPastTheCapIsNotKeptAtAll() {
        let recording = DictationAudioRecording(maxBytes: 4)
        recording.begin(enabled: true)
        recording.append(Data([1, 2, 3, 4]))
        recording.append(Data([5, 6]))
        recording.append(Data([7, 8]))

        // A cut recording would replay as a shorter dictation than the text
        // it is scored against.
        XCTAssertNil(recording.finish())
    }

    func testTheWAVHeaderDescribesSixteenKilohertzMonoPCM16() {
        let pcm = Data([0x10, 0x00, 0xF0, 0xFF])
        let wav = DictationAudioRecording.wav(fromPCM16: pcm)

        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<16], encoding: .ascii), "WAVEfmt ")
        XCTAssertEqual(uint32(wav, 4), UInt32(36 + pcm.count))
        XCTAssertEqual(uint16(wav, 20), 1)  // PCM
        XCTAssertEqual(uint16(wav, 22), 1)  // mono
        XCTAssertEqual(uint32(wav, 24), 16_000)
        XCTAssertEqual(uint32(wav, 28), 32_000)
        XCTAssertEqual(uint16(wav, 34), 16)
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(uint32(wav, 40), UInt32(pcm.count))
        XCTAssertEqual(wav[44...], pcm)
    }

    private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }
}
