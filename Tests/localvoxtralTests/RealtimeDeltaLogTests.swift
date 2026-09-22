import XCTest
@testable import localvoxtral

/// The raw-delta log's own rules: nothing at all while the toggle is off, one
/// record per event while it is on, and a sequence that restarts with each
/// connected session. `DictationViewModelDeltaLoggingTests` proves the view
/// model routes every event through it.
final class RealtimeDeltaLogTests: XCTestCase {
    func testDisabledNeitherRecordsNorAdvancesTheSequence() {
        var log = RealtimeDeltaLog()
        var records: [DebugRealtimeDeltaLogRecord] = []

        for event in [RealtimeEvent.connected, .partialTranscript("a"), .finalTranscript("a.")] {
            log.record(event, isEnabled: false) { records.append($0) }
        }

        XCTAssertEqual(records, [])
        XCTAssertEqual(log.sequence, 0)
    }

    func testSequenceCountsEveryEventAndRestartsOnConnected() {
        var log = RealtimeDeltaLog()
        var records: [DebugRealtimeDeltaLogRecord] = []
        let events: [RealtimeEvent] = [
            .partialTranscript("a"), .connected, .partialTranscript("b"),
            .status("ready"), .connected, .transcriptionFinalized,
        ]

        for event in events {
            log.record(event, isEnabled: true) { records.append($0) }
        }

        XCTAssertEqual(records.map(\.sequence), [0, 0, 1, 2, 0, 1])
        XCTAssertEqual(log.sequence, 2)
    }

    func testTranscriptionStoppedIsRecordedAsAnErrorWithItsMessage() {
        var log = RealtimeDeltaLog()
        var records: [DebugRealtimeDeltaLogRecord] = []

        log.record(.transcriptionStopped("limit reached"), isEnabled: true) { records.append($0) }

        XCTAssertEqual(
            records,
            [DebugRealtimeDeltaLogRecord(kind: .error, sequence: 0, payload: "limit reached")]
        )
    }
}
