import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtralCore
import localvoxtralTestSupport
import Synchronization

final class StopSecondPassTests: XCTestCase {
    func testTheDeadlineGrowsWithTheAudio() {
        XCTAssertEqual(StopSecondPass.deadline(audioSeconds: 0), .milliseconds(2_500))
        XCTAssertEqual(StopSecondPass.deadline(audioSeconds: 15), .milliseconds(2_750))
        XCTAssertEqual(StopSecondPass.deadline(audioSeconds: 600), .milliseconds(12_500))
        // Each measured latency (see `baseDeadlineSeconds`) sits well inside.
        XCTAssertGreaterThan(StopSecondPass.deadline(audioSeconds: 60), .milliseconds(1_400 * 2))
        XCTAssertGreaterThan(StopSecondPass.deadline(audioSeconds: 600), .milliseconds(4_500 * 2))
    }

    private static let context = StopSecondPass.ContextTerms(
        session: ["StopCommitCoordinator"], repository: ["inkwell"], screen: ["useAuth.ts"])

    func testWithoutTrustOnlyTheUsersOwnTermsLeave() {
        let untrusted = StopSecondPass.vocabulary(
            userTerms: ["Qwen"], dictionarySpellings: ["PostgreSQL"],
            learnedTerms: ["herdr"], context: Self.context, contextTrusted: false)
        XCTAssertEqual(untrusted, ["Qwen", "PostgreSQL"])

        let trusted = StopSecondPass.vocabulary(
            userTerms: ["Qwen"], dictionarySpellings: ["PostgreSQL"],
            learnedTerms: ["herdr"], context: Self.context, contextTrusted: true)
        XCTAssertEqual(
            trusted, ["Qwen", "PostgreSQL", "herdr", "inkwell", "StopCommitCoordinator", "useAuth.ts"])
    }

    func testTheCapCutsTheScreenFirstAndTheUsersOwnTermsLast() {
        let screen = (0..<120).map { "screen\($0)" }
        let terms = StopSecondPass.vocabulary(
            userTerms: ["Qwen"], dictionarySpellings: ["PostgreSQL"], learnedTerms: ["herdr"],
            context: StopSecondPass.ContextTerms(
                session: ["StopCommitCoordinator"], repository: ["inkwell"], screen: screen),
            contextTrusted: true)
        XCTAssertEqual(terms.count, 100)
        XCTAssertEqual(
            Array(terms.prefix(6)),
            ["Qwen", "PostgreSQL", "herdr", "inkwell", "StopCommitCoordinator", "screen0"])
        XCTAssertEqual(terms.last, "screen94")
    }

    func testScreenTermsAreTheOnesSomeoneCouldSayNewestFirst() {
        let screen = """
            ~/work/quillmark $ swift test --filter PageComposerTests
            see https://example.com/docs/PageComposer for details
            Sources/Quill/useAuth.ts: SESSION_TOKEN_TTL not set, a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3
            """
        XCTAssertEqual(
            StopSecondPass.speakableTerms(in: screen, newestFirst: true),
            ["useAuth.ts", "SESSION_TOKEN_TTL", "quillmark", "PageComposerTests"])
    }

    func testAnAnswerBeforeTheDeadlineReplacesTheText() async {
        let clock = ManualSessionClock()
        let outcome = await StopSecondPass.run(
            deadline: .seconds(3), sleep: clock.clock.sleep,
            transcribe: { "  Look at localvoxtral. \n" }
        )
        XCTAssertEqual(outcome, .replaced("Look at localvoxtral."))
        XCTAssertEqual(clock.pendingSleepers, 0, "the losing deadline is cancelled")
    }

    func testTheDeadlineWinsOverASlowAnswerAndCancelsIt() async {
        let clock = ManualSessionClock()
        let answer = FakeBatchTranscriber(.held)
        let task = Task { await race(answer, clock: clock) }
        _ = await answer.called.value(failAfter: 10)
        await clock.waitForSleepers(1)
        clock.advance(by: 2.9)
        XCTAssertEqual(answer.cancelledCount, 0, "not before the deadline")
        clock.advance(by: 0.1)
        let outcome = await task.value
        XCTAssertEqual(outcome, .deadlinePassed)
        XCTAssertEqual(answer.cancelledCount, 1, "the request that lost is cancelled")
    }

    func testAFailureFallsBack() async {
        struct Boom: Error {}
        let outcome = await race(FakeBatchTranscriber(.failure(Boom())), clock: ManualSessionClock())
        guard case .failed = outcome else { return XCTFail("got \(outcome)") }
    }

    func testABlankAnswerKeepsTheRealtimeText() async {
        let outcome = await race(FakeBatchTranscriber(.text(" \n")), clock: ManualSessionClock())
        XCTAssertEqual(outcome, .empty)
    }

    func testACancelledCommitCommitsNothing() async {
        let clock = ManualSessionClock()
        let answer = FakeBatchTranscriber(.held)
        let task = Task { await race(answer, clock: clock) }
        _ = await answer.called.value(failAfter: 10)
        await clock.waitForSleepers(1)
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(answer.cancelledCount, 1)
    }

    // MARK: - Repository root (#705)

    func testALookupStuckPastTheBoundIsUnknownAndHoldsOnlyItsOwnGate() async {
        let clock = ManualSessionClock()
        let gate = RepoVocabularyFlightGate()
        let started = BoundedWait()
        let unstick = BoundedWait()
        let lookup = Task {
            await StopSecondPass.repositoryRoot(sleep: clock.clock.sleep, gate: gate) {
                started.resolve()
                _ = await unstick.value(failAfter: 10)
                return .root("/work/quillmark")
            }
        }
        _ = await started.value(failAfter: 10)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.249)
        XCTAssertEqual(clock.pendingSleepers, 1, "not before the bound")
        clock.advance(by: 0.001)
        let root = await lookup.value
        XCTAssertEqual(root, .unknown)

        let calls = Mutex(0)
        let next = await StopSecondPass.repositoryRoot(sleep: clock.clock.sleep, gate: gate) {
            calls.withLock { $0 += 1 }
            return .noRepository
        }
        XCTAssertEqual(next, .unknown, "the stuck lookup still holds the gate")
        XCTAssertEqual(calls.withLock { $0 }, 0, "and no second one starts behind it")
        XCTAssertTrue(RepoVocabularyFlightGate().acquire(), "the polish's gate is another")
        unstick.resolve()
    }

    func testAnAnswerWithinTheBoundIsTheRoot() async {
        let clock = ManualSessionClock()
        let root = await StopSecondPass.repositoryRoot(
            sleep: clock.clock.sleep, gate: RepoVocabularyFlightGate()
        ) { .root("/work/quillmark-wt", mainCheckout: "/work/quillmark") }
        XCTAssertEqual(root, .root("/work/quillmark-wt", mainCheckout: "/work/quillmark"))
    }

    /// The case #705 fixes for a joined session: its directory is a
    /// subdirectory of a linked worktree, and the project's proposals are
    /// filed under the main checkout (#652). Without the root the key is the
    /// session's own directory, which holds none of them.
    func testASessionInAWorktreeSubdirectoryKeysOnTheMainCheckout() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-pass-root-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("quillmark")
        let worktreeGitDir = main.appendingPathComponent(".git/worktrees/wt")
        let worktree = base.appendingPathComponent("quillmark-wt")
        let session = worktree.appendingPathComponent("Sources/Quill")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "../..\n".write(
            to: worktreeGitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(worktreeGitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let workspace = try XCTUnwrap(ClaudeWorkspaceReference.make(
            rawCwd: session.path, origin: .localAuthenticated(peerUID: 501)))

        let root = await StopSecondPass.repositoryRoot(
            sleep: ManualSessionClock().clock.sleep, gate: RepoVocabularyFlightGate()
        ) {
            RepoIndexing.repositoryRoot(
                gitRoot: RepoIndexing.findGitRoot(startingAt: session.path))
        }

        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(repositoryRoot: root, workspace: workspace)?.key,
            main.path)
        XCTAssertEqual(
            LearnedTermProjectResolver.resolve(repositoryRoot: .unknown, workspace: workspace)?.key,
            session.path, "what #647 keyed on")
    }
}

/// The race as the stop-commit runs it, against `transcriber`.
private func race(
    _ transcriber: FakeBatchTranscriber, clock: ManualSessionClock
) async -> StopSecondPass.Outcome {
    await StopSecondPass.run(deadline: .seconds(3), sleep: clock.clock.sleep) {
        try await transcriber.transcribe(
            wav: Data(), language: nil, contextBias: [], apiKey: "k",
            endpoint: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
        ).text
    }
}
