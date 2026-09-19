import XCTest
@testable import localvoxtral

final class MistralStreamHealthTests: XCTestCase {
    private let frame = 3_200  // 100 ms of 16 kHz s16le

    func testNoReportWhileTheServerAnswersWithinTheThreshold() {
        var health = MistralStreamHealth(openedAt: 0)
        for tick in 1...100 {
            let now = Double(tick) / 10
            XCTAssertNil(health.audioSent(bytes: frame, at: now))
            health.audioSendCompleted()
            if tick % 20 == 0 { XCTAssertNil(health.serverEvent(at: now)) }
        }
    }

    func testSilencePastTheThresholdIsReportedOnceWithWhatTheSocketWasDoing() {
        var health = MistralStreamHealth(openedAt: 0)
        health.sessionCreated(requestID: "ws-123")
        XCTAssertNil(health.serverEvent(at: 1.0))
        health.pingSent(at: 2.0)

        var reports: [MistralStreamHealth.StallReport] = []
        for tick in 11...80 {  // audio from 1.1 s to 8.0 s, sends never complete
            if let report = health.audioSent(bytes: frame, at: Double(tick) / 10) {
                reports.append(report)
            }
        }

        XCTAssertEqual(reports.count, 1)
        let report = reports[0]
        XCTAssertEqual(report.silentFor, 5.0, accuracy: 1e-9)
        XCTAssertEqual(report.audioSecondsSinceLastEvent, 5.0, accuracy: 1e-9)
        XCTAssertEqual(report.sendsAwaitingCompletion, 50)
        XCTAssertEqual(report.unansweredPingAge ?? -1, 4.0, accuracy: 1e-9)
        XCTAssertEqual(report.requestID, "ws-123")
    }

    func testAnsweredPingAndCompletedSendsReadAsHealthySocket() {
        var health = MistralStreamHealth(openedAt: 0)
        health.pingSent(at: 1.0)
        health.pongReceived()
        var report: MistralStreamHealth.StallReport?
        for tick in 1...60 {
            report = health.audioSent(bytes: frame, at: Double(tick) / 10) ?? report
            health.audioSendCompleted()
        }
        XCTAssertNil(report?.unansweredPingAge)
        XCTAssertEqual(report?.sendsAwaitingCompletion, 1)
    }

    func testTheEventEndingAReportedStallSaysHowLongItLastedAndRearmsTheReport() {
        var health = MistralStreamHealth(openedAt: 0)
        XCTAssertNotNil(health.audioSent(bytes: frame, at: 6.0))
        XCTAssertEqual(health.serverEvent(at: 9.5) ?? -1, 9.5, accuracy: 1e-9)
        XCTAssertNil(health.serverEvent(at: 10.0), "No stall was open")
        XCTAssertNil(health.audioSent(bytes: frame, at: 14.0))
        XCTAssertNotNil(health.audioSent(bytes: frame, at: 15.0))
    }

    func testClosingWhileDoneIsOwedNamesTheEndAgeAndRequest() {
        var health = MistralStreamHealth(openedAt: 0)
        health.sessionCreated(requestID: "ws-9")
        XCTAssertNil(health.serverEvent(at: 34.0))
        _ = health.audioSent(bytes: frame, at: 49.0)
        health.endSent(at: 50.0)
        XCTAssertEqual(
            health.closedAwaitingDone(at: 51.6),
            "end sent 1.60s ago, last server event 17.60s ago, 1 sends awaiting completion, request_id=ws-9"
        )
    }
}
