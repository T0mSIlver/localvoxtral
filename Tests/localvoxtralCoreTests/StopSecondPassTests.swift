import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

final class StopSecondPassTests: XCTestCase {
    func testTheDeadlineGrowsWithTheAudio() {
        XCTAssertEqual(StopSecondPass.deadline(audioSeconds: 0), .milliseconds(2_500))
        XCTAssertEqual(StopSecondPass.deadline(audioSeconds: 15), .milliseconds(2_750))
        XCTAssertEqual(StopSecondPass.deadline(audioSeconds: 600), .milliseconds(12_500))
        // Each measured latency (see `baseDeadlineSeconds`) sits well inside.
        XCTAssertGreaterThan(StopSecondPass.deadline(audioSeconds: 60), .milliseconds(1_400 * 2))
        XCTAssertGreaterThan(StopSecondPass.deadline(audioSeconds: 600), .milliseconds(4_500 * 2))
    }

    func testLearnedTermsGoOnlyToATrustedEndpoint() {
        let untrusted = StopSecondPass.vocabulary(
            userTerms: ["Qwen"], dictionarySpellings: ["PostgreSQL"],
            learnedTerms: ["useAuth.ts"], contextTrusted: false)
        XCTAssertEqual(untrusted, ["Qwen", "PostgreSQL"])

        let trusted = StopSecondPass.vocabulary(
            userTerms: ["Qwen"], dictionarySpellings: ["PostgreSQL"],
            learnedTerms: ["useAuth.ts"], contextTrusted: true)
        XCTAssertEqual(trusted, ["Qwen", "PostgreSQL", "useAuth.ts"])
    }

    func testTheUsersOwnTermsAreTheLastToBeCut() {
        let learned = (0..<120).map { "learned\($0)" }
        let terms = StopSecondPass.vocabulary(
            userTerms: ["Qwen"], dictionarySpellings: ["PostgreSQL"],
            learnedTerms: learned, contextTrusted: true)
        XCTAssertEqual(terms.count, 100)
        XCTAssertEqual(Array(terms.prefix(2)), ["Qwen", "PostgreSQL"])
    }

    func testAnAnswerBeforeTheDeadlineReplacesTheText() async {
        let deadline = HeldSleep()
        let outcome = await StopSecondPass.run(
            deadline: .seconds(3), sleep: deadline.sleep,
            transcribe: { "  Look at localvoxtral. \n" }
        )
        XCTAssertEqual(outcome, .replaced("Look at localvoxtral."))
        XCTAssertEqual(deadline.cancelledCount, 1, "the losing deadline is cancelled")
    }

    func testTheDeadlineWinsOverASlowAnswerAndCancelsIt() async {
        let deadline = HeldSleep()
        let answer = HeldAnswer()
        let task = Task {
            await StopSecondPass.run(
                deadline: .seconds(3), sleep: deadline.sleep, transcribe: answer.wait)
        }
        await deadline.waitUntilSleeping()
        await answer.waitUntilAsked()
        deadline.fire()
        let outcome = await task.value
        XCTAssertEqual(outcome, .deadlinePassed)
        XCTAssertTrue(answer.wasCancelled, "the request that lost is cancelled")
        XCTAssertEqual(deadline.requested, [.seconds(3)])
    }

    func testAFailureFallsBack() async {
        struct Boom: Error {}
        let outcome = await StopSecondPass.run(
            deadline: .seconds(3), sleep: HeldSleep().sleep, transcribe: { throw Boom() })
        guard case .failed = outcome else { return XCTFail("got \(outcome)") }
    }

    func testABlankAnswerKeepsTheRealtimeText() async {
        let outcome = await StopSecondPass.run(
            deadline: .seconds(3), sleep: HeldSleep().sleep, transcribe: { " \n" })
        XCTAssertEqual(outcome, .empty)
    }

    func testACancelledCommitCommitsNothing() async {
        let deadline = HeldSleep()
        let answer = HeldAnswer()
        let task = Task {
            await StopSecondPass.run(
                deadline: .seconds(3), sleep: deadline.sleep, transcribe: answer.wait)
        }
        await deadline.waitUntilSleeping()
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(answer.wasCancelled)
    }
}

/// A deadline that passes only when the test fires it, or when its task is
/// cancelled. No wall clock.
private final class HeldSleep: Sendable {
    private struct State {
        var requested: [Duration] = []
        var continuation: CheckedContinuation<Void, Never>?
        var fired = false
        var cancelledCount = 0
        var sleepingWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    var requested: [Duration] { state.withLock { $0.requested } }
    var cancelledCount: Int { state.withLock { $0.cancelledCount } }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in await self.hold(duration) }
    }

    private func hold(_ duration: Duration) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let (resumeNow, waiters) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
                    s.requested.append(duration)
                    let waiters = s.sleepingWaiters
                    s.sleepingWaiters = []
                    if s.fired { return (true, waiters) }
                    s.continuation = continuation
                    return (false, waiters)
                }
                waiters.forEach { $0.resume() }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
                s.fired = true
                s.cancelledCount += 1
                defer { s.continuation = nil }
                return s.continuation
            }
            continuation?.resume()
        }
    }

    func waitUntilSleeping() async {
        await withCheckedContinuation { continuation in
            let sleeping = state.withLock { s -> Bool in
                if !s.requested.isEmpty { return true }
                s.sleepingWaiters.append(continuation)
                return false
            }
            if sleeping { continuation.resume() }
        }
    }

    func fire() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.fired = true
            defer { s.continuation = nil }
            return s.continuation
        }
        continuation?.resume()
    }
}

/// A transcription that never answers; it only notices being cancelled.
private final class HeldAnswer: Sendable {
    private struct State {
        var asked = false
        var cancelled = false
        var continuation: CheckedContinuation<Void, Never>?
        var askedWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    var wait: @Sendable () async throws -> String {
        { [self] in
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let (cancelled, waiters) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
                        s.asked = true
                        let waiters = s.askedWaiters
                        s.askedWaiters = []
                        if s.cancelled { return (true, waiters) }
                        s.continuation = continuation
                        return (false, waiters)
                    }
                    waiters.forEach { $0.resume() }
                    if cancelled { continuation.resume() }
                }
            } onCancel: {
                let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
                    s.cancelled = true
                    defer { s.continuation = nil }
                    return s.continuation
                }
                continuation?.resume()
            }
            throw CancellationError()
        }
    }

    func waitUntilAsked() async {
        await withCheckedContinuation { continuation in
            let asked = state.withLock { s -> Bool in
                if s.asked { return true }
                s.askedWaiters.append(continuation)
                return false
            }
            if asked { continuation.resume() }
        }
    }
}
