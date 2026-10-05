import Foundation
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// #1688: a polish request ends at its whole budget, also when the server
/// keeps it alive with a byte now and then.
@MainActor
final class PolishRequestDeadlineTests: XCTestCase {
    /// Never answers; returns only when cancelled, as a URLSession task does.
    nonisolated private static func neverAnswers() async throws -> String {
        // An empty stream that never finishes: its iteration ends only on
        // cancellation.
        let (stream, continuation) = AsyncStream<Never>.makeStream()
        for await _ in stream {}
        withExtendedLifetime(continuation) {}
        throw CancellationError()
    }

    nonisolated private static func polishThatNeverAnswers(sleep: @escaping @Sendable (Duration) async -> Void) async throws -> String {
        try await PolishRequestTimeout.enforcing(seconds: 40, sleep: sleep) { try await neverAnswers() }
    }

    func testARequestStillRunningAtItsDeadlineIsCancelledAndTimesOut() async throws {
        let clock = ManualSessionClock()
        let sleep = clock.clock.sleep
        let running = Task { try await Self.polishThatNeverAnswers(sleep: sleep) }
        await clock.waitForSleepers(1)
        clock.advance(by: 39)
        XCTAssertEqual(clock.pendingSleepers, 1, "not before its deadline")
        clock.advance(by: 1)

        do {
            _ = try await running.value
            XCTFail("a request past its deadline returned")
        } catch let error as PolishDeadlinePassed {
            XCTAssertEqual(error, PolishDeadlinePassed(seconds: 40))
        }
    }

    func testAnAnswerBeforeTheDeadlineWins() async throws {
        let clock = ManualSessionClock()
        let answer = try await PolishRequestTimeout.enforcing(seconds: 40, sleep: clock.clock.sleep) { "polished" }
        XCTAssertEqual(answer, "polished")
    }

    func testACancelledCallerIsNotReportedAsADeadline() async throws {
        let clock = ManualSessionClock()
        let sleep = clock.clock.sleep
        let running = Task { try await Self.polishThatNeverAnswers(sleep: sleep) }
        await clock.waitForSleepers(1)
        running.cancel()
        do {
            _ = try await running.value
            XCTFail("a cancelled request returned")
        } catch {
            XCTAssertFalse(error is PolishDeadlinePassed)
        }
    }
}
