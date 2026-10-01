import Foundation
import XCTest
@testable import localvoxtral

final class WidgetSnapshotAssemblerTests: XCTestCase {
    /// A second-pass transcription (#317) bills as speech, but its audio was
    /// already counted by the realtime socket, so it adds cost and no seconds.
    func testARetranscriptionCountsAsSpeechSpendWithoutAddingAudio() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let entries = [
            UsageEntry(date: now, kind: .dictation, model: "voxtral-mini-transcribe-realtime-2602", audioSeconds: 60, costEUR: 0.006),
            UsageEntry(date: now, kind: .retranscription, model: "voxtral-mini-latest", costEUR: 0.003),
        ]

        let spend = WidgetSnapshotAssembler.mistralSpend(entries, now: now, calendar: calendar)

        XCTAssertEqual(spend.speechTodayEUR, 0.009, accuracy: 1e-9)
        XCTAssertEqual(spend.speechLast30DaysEUR, 0.009, accuracy: 1e-9)
        XCTAssertEqual(spend.audioSecondsToday, 60)
        XCTAssertEqual(spend.polishTodayEUR, 0)
        XCTAssertEqual(spend.polishesToday, 0)
    }

    /// A quick capture is polished in the Inbox after it was recorded: its
    /// polish took none of the time spoken, as Insights counts it.
    func testQuickCapturePolishDoesNotReduceSpeakingTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let capture = DictationHistoryEntry(
            id: UUID(), startedAt: now.addingTimeInterval(-60), finishedAt: now.addingTimeInterval(-40),
            rawText: "buy milk", polishedText: "Buy milk.", polishingDurationSeconds: 9,
            provider: "test", model: "test", outputMode: DictationSessionRecord.quickCaptureOutputMode,
            targetAppBundleID: nil, status: .completed, commitSucceeded: true,
            polishProfile: nil, polishContextSummary: nil)

        let history = WidgetSnapshotAssembler.history(entries: [capture], terms: [], now: now, calendar: calendar)

        XCTAssertEqual(history.dictation.days.map(\.dictatingSeconds), [20])
    }
}
