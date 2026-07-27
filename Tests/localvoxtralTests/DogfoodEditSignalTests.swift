#if LOCALVOXTRAL_DOGFOOD

import AppKit
import Carbon.HIToolbox
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

// MARK: - Shared doubles (also used by DogfoodCaptureWiringTests)

/// A key source the watcher can be driven from without an event stream, an
/// Accessibility grant, or the host's keyboard.
///
/// `stop()` deliberately KEEPS the handler: the watcher's own generation/result
/// guard is what must reject a late signal, and a double that forgot the handler
/// would pass those tests without the guard existing.
@MainActor
final class DogfoodEditSignalTestMonitor: DogfoodEditKeyMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isInstalled = false
    private var handler: (@MainActor (DogfoodEditSignal) -> Void)?

    func start(_ handler: @escaping @MainActor (DogfoodEditSignal) -> Void) {
        startCount += 1
        isInstalled = true
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        isInstalled = false
    }

    func send(_ signal: DogfoodEditSignal) {
        handler?(signal)
    }
}

/// A `sleepFor` seam the test decides the duration of. No wall-clock: the window
/// elapses when `fireAll()` says it does (AGENTS.md forbids real sleeps here).
///
/// `fireAll()` LATCHES. The watcher starts its window inside a `Task`, which
/// does not necessarily reach the sleep before the test's next statement runs —
/// an un-latched fire would resume nobody and the window would then wait
/// forever, hanging the suite rather than failing it.
final class DogfoodManualSleeper: Sendable {
    private struct State {
        var requested: [Duration] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        var fired = false
    }

    private let state = Mutex(State())

    /// Returns once a window has actually reached the sleep.
    ///
    /// `Task.yield()` is NOT enough: the window runs in a `Task` the main actor
    /// is free to schedule after the test's next statement, which made asserting
    /// the requested duration flaky (observed on the build host, 2026-07-27).
    func waitForSleepRequest() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { current -> Bool in
                guard current.requested.isEmpty else { return true }
                current.arrivalWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func sleep(_ duration: Duration) async {
        let (alreadyFired, arrivals) = state.withLock { current -> (Bool, [CheckedContinuation<Void, Never>]) in
            current.requested.append(duration)
            let arrivals = current.arrivalWaiters
            current.arrivalWaiters = []
            return (current.fired, arrivals)
        }
        for arrival in arrivals { arrival.resume() }
        guard !alreadyFired else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { current -> Bool in
                guard !current.fired else { return true }
                current.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var requestedDurations: [Duration] { state.withLock { $0.requested } }

    func fireAll() {
        let waiters = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.fired = true
            let waiters = current.waiters + current.arrivalWaiters
            current.waiters = []
            current.arrivalWaiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Injected clock, mirroring `CaptureTestClock` in the store suite.
final class DogfoodTestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

// MARK: - Tests

/// The post-commit behavioral signal: the ladder, the key mapping, and the
/// watch window's lifecycle.
@MainActor
final class DogfoodEditSignalTests: XCTestCase {
    // MARK: Policy

    func testWindowLadderBoundaries() {
        let cases: [(Int, Double)] = [
            (1, 2), (5, 2),
            (6, 4), (15, 4),
            (16, 8), (40, 8),
            (41, 15), (400, 15),
        ]
        for (words, expected) in cases {
            XCTAssertEqual(
                DogfoodEditSignalPolicy.windowSeconds(wordCount: words), expected,
                "\(words) words"
            )
        }
    }

    func testWordCountBucketBoundaries() {
        let cases: [(Int, String)] = [
            (1, "1-5"), (5, "1-5"),
            (6, "6-15"), (15, "6-15"),
            (16, "16-40"), (40, "16-40"),
            (41, "41+"), (400, "41+"),
        ]
        for (words, expected) in cases {
            XCTAssertEqual(
                DogfoodEditSignalPolicy.wordCountBucket(words), expected, "\(words) words"
            )
        }
    }

    func testSecondsSinceCommitBucketBoundaries() {
        let cases: [(Double, String)] = [
            (0, "0-1"), (0.99, "0-1"),
            (1, "1-2"), (1.99, "1-2"),
            (2, "2-5"), (4.99, "2-5"),
            (5, "5-15"), (14.9, "5-15"),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(
                DogfoodEditSignalPolicy.secondsSinceCommitBucket(seconds), expected,
                "\(seconds)s"
            )
        }
    }

    func testWordCountIgnoresWhitespaceRuns() {
        XCTAssertEqual(DogfoodEditSignalPolicy.wordCount(of: "  run   the tests\n"), 3)
        XCTAssertEqual(DogfoodEditSignalPolicy.wordCount(of: "   "), 0)
    }

    // MARK: Key mapping

    /// The whole recognized alphabet. Everything else must be forgotten — this
    /// is the property that keeps the watch from being a keylogger.
    func testOnlyTwoGesturesAreRecognized() {
        XCTAssertEqual(
            DogfoodEditSignal.from(keyCode: UInt16(kVK_Delete), modifiers: []), .backspace
        )
        XCTAssertEqual(
            DogfoodEditSignal.from(keyCode: UInt16(kVK_ForwardDelete), modifiers: []), .backspace
        )
        // A word/line delete is still the user erasing the insertion.
        XCTAssertEqual(
            DogfoodEditSignal.from(keyCode: UInt16(kVK_Delete), modifiers: [.option]), .backspace
        )
        XCTAssertEqual(
            DogfoodEditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command]), .selectAll
        )

        // Plain "a" is typing, not selecting.
        XCTAssertNil(DogfoodEditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: []))
        // ⌥⌘A / ⌃⌘A are app shortcuts, not select-all.
        XCTAssertNil(
            DogfoodEditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .option])
        )
        XCTAssertNil(
            DogfoodEditSignal.from(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .control])
        )
        // Every other key, modified or not.
        XCTAssertNil(DogfoodEditSignal.from(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command]))
        XCTAssertNil(DogfoodEditSignal.from(keyCode: UInt16(kVK_Return), modifiers: []))
        XCTAssertNil(DogfoodEditSignal.from(keyCode: UInt16(kVK_Escape), modifiers: []))
    }

    // MARK: Watch window

    /// A gesture inside the window is recorded with the buckets that describe
    /// it, and the observer comes down at that instant.
    func testSignalInsideWindowIsRecordedWithBuckets() async throws {
        let harness = makeWatcher()

        harness.watcher.arm(committedText: "run the tests", outputMode: "overlay_buffer")
        XCTAssertTrue(harness.watcher.isWatching)
        XCTAssertEqual(harness.monitor.startCount, 1)
        await harness.sleeper.waitForSleepRequest()
        XCTAssertEqual(harness.sleeper.requestedDurations, [.seconds(2.0)], "3 words -> 2s window")

        harness.watcher.attachRecord(url: harness.recordURL, store: harness.store)
        harness.clock.advance(1.5)
        harness.monitor.send(.backspace)
        await harness.watcher.flushTask?.value

        let behavior = try XCTUnwrap(harness.readBack()?.behavior)
        XCTAssertEqual(behavior.outcome, .edited)
        XCTAssertEqual(behavior.signal, .backspace)
        XCTAssertEqual(behavior.secondsSinceCommitBucket, "1-2")
        XCTAssertEqual(behavior.wordCountBucket, "1-5")
        XCTAssertEqual(behavior.watchWindowSeconds, 2)
        XCTAssertEqual(behavior.outputMode, "overlay_buffer")

        XCTAssertFalse(harness.watcher.isWatching)
        XCTAssertFalse(harness.monitor.isInstalled, "the observer must not outlive its window")
        XCTAssertEqual(harness.monitor.stopCount, 1)
    }

    /// ⌘A, and the far end of the ladder: a long transcript gets the long
    /// window and a late gesture still lands inside it.
    func testSelectAllLateInALongWindowIsRecorded() async throws {
        let harness = makeWatcher()
        let longText = (0..<60).map { "word\($0)" }.joined(separator: " ")

        harness.watcher.arm(committedText: longText, outputMode: "overlay_buffer")
        await harness.sleeper.waitForSleepRequest()
        XCTAssertEqual(harness.sleeper.requestedDurations, [.seconds(15.0)])
        harness.watcher.attachRecord(url: harness.recordURL, store: harness.store)

        harness.clock.advance(9)
        harness.monitor.send(.selectAll)
        await harness.watcher.flushTask?.value

        let behavior = try XCTUnwrap(harness.readBack()?.behavior)
        XCTAssertEqual(behavior.outcome, .edited)
        XCTAssertEqual(behavior.signal, .selectAll)
        XCTAssertEqual(behavior.secondsSinceCommitBucket, "5-15")
        XCTAssertEqual(behavior.wordCountBucket, "41+")
        XCTAssertEqual(behavior.watchWindowSeconds, 15)
    }

    /// The negative is recorded too — without it there is no denominator — and
    /// a gesture arriving after the window closed must not rewrite it.
    func testSignalAfterWindowIsNotRecorded() async throws {
        let harness = makeWatcher()

        harness.watcher.arm(committedText: "run the tests", outputMode: "overlay_buffer")
        harness.watcher.attachRecord(url: harness.recordURL, store: harness.store)

        let windowTask = harness.watcher.windowTask
        harness.clock.advance(2)
        harness.sleeper.fireAll()
        await windowTask?.value
        await harness.watcher.flushTask?.value

        let clean = try XCTUnwrap(harness.readBack()?.behavior)
        XCTAssertEqual(clean.outcome, .clean)
        XCTAssertNil(clean.signal)
        XCTAssertNil(clean.secondsSinceCommitBucket)
        XCTAssertEqual(clean.wordCountBucket, "1-5")
        XCTAssertFalse(harness.monitor.isInstalled)

        // A key that arrives after the window (the monitor double keeps its
        // handler on purpose) must be ignored, not re-flush the record.
        harness.clock.advance(1)
        harness.monitor.send(.backspace)
        await harness.watcher.flushTask?.value
        XCTAssertEqual(harness.readBack()?.behavior?.outcome, .clean)
        XCTAssertEqual(harness.monitor.stopCount, 1, "a closed window closes exactly once")
    }

    /// Live Auto-Paste rides the same watch; the mode is recorded as given.
    func testLiveModeOutputModeIsRecorded() async throws {
        let harness = makeWatcher()

        harness.watcher.arm(
            committedText: "insert this live",
            outputMode: DictationOutputMode.liveAutoPaste.rawValue
        )
        harness.watcher.attachRecord(url: harness.recordURL, store: harness.store)
        harness.clock.advance(0.4)
        harness.monitor.send(.backspace)
        await harness.watcher.flushTask?.value

        let behavior = try XCTUnwrap(harness.readBack()?.behavior)
        XCTAssertEqual(behavior.outputMode, DictationOutputMode.liveAutoPaste.rawValue)
        XCTAssertEqual(behavior.secondsSinceCommitBucket, "0-1")
    }

    /// A new dictation closes the previous window. The old record still gets its
    /// own verdict — `superseded`, which is neither evidence of an edit nor of a
    /// clean commit — and the new watch starts fresh.
    func testNewDictationSupersedesTheOpenWindow() async throws {
        let harness = makeWatcher()

        harness.watcher.arm(committedText: "first dictation text", outputMode: "overlay_buffer")
        harness.watcher.attachRecord(url: harness.recordURL, store: harness.store)

        harness.watcher.arm(committedText: "second dictation text", outputMode: "overlay_buffer")
        await harness.watcher.flushTask?.value

        XCTAssertEqual(harness.readBack()?.behavior?.outcome, .superseded)
        XCTAssertEqual(harness.monitor.startCount, 2)
        XCTAssertEqual(
            harness.monitor.stopCount, 1,
            "the old window's observer came down before the new one went up"
        )
        XCTAssertTrue(harness.watcher.isWatching, "the new dictation's window is open")
    }

    /// The superseded record must not then be overwritten by the NEW window's
    /// verdict: a watch patches only the record it was handed.
    func testSupersededRecordIsNotRewrittenByTheNextWatch() async throws {
        let harness = makeWatcher()

        harness.watcher.arm(committedText: "first dictation text", outputMode: "overlay_buffer")
        harness.watcher.attachRecord(url: harness.recordURL, store: harness.store)
        harness.watcher.arm(committedText: "second dictation text", outputMode: "overlay_buffer")
        await harness.watcher.flushTask?.value

        // The second dictation never attached a record (its write is still in
        // flight), so its gesture has nowhere to land — and must not land on
        // the first dictation's record.
        harness.monitor.send(.backspace)
        await harness.watcher.flushTask?.value
        XCTAssertEqual(harness.readBack()?.behavior?.outcome, .superseded)
    }

    /// Nothing to measure, nothing to watch: an empty commit never installs an
    /// observer.
    func testEmptyCommitNeverArms() {
        let harness = makeWatcher()
        harness.watcher.arm(committedText: "   \n", outputMode: "overlay_buffer")
        XCTAssertFalse(harness.watcher.isWatching)
        XCTAssertEqual(harness.monitor.startCount, 0)
    }

    /// A record that vanished (pruned, or a write that never landed) costs the
    /// signal, never anything else.
    func testMissingRecordFailsQuietly() async throws {
        let harness = makeWatcher(writeRecord: false)

        harness.watcher.arm(committedText: "run the tests", outputMode: "overlay_buffer")
        harness.watcher.attachRecord(url: harness.recordURL, store: harness.store)
        harness.monitor.send(.backspace)
        await harness.watcher.flushTask?.value

        XCTAssertNil(harness.readBack())
    }

    /// Flagging renames the file; a record flagged during the watch window
    /// still receives its signal.
    func testBehaviorPatchFollowsAFlagRename() async throws {
        let harness = makeWatcher()

        harness.watcher.arm(committedText: "run the tests", outputMode: "overlay_buffer")
        harness.watcher.attachRecord(url: harness.recordURL, store: harness.store)

        let flaggedURL = try XCTUnwrap(harness.store.flagMostRecentRecord())
        harness.monitor.send(.backspace)
        await harness.watcher.flushTask?.value

        let record = try XCTUnwrap(harness.readBack(at: flaggedURL))
        XCTAssertTrue(record.flagged, "flagging must survive the patch")
        XCTAssertEqual(record.behavior?.outcome, .edited)
        XCTAssertNil(harness.readBack(), "the patch must not resurrect the unflagged name")
    }

    // MARK: Harness

    private struct WatcherHarness {
        let watcher: DogfoodEditSignalWatcher
        let monitor: DogfoodEditSignalTestMonitor
        let sleeper: DogfoodManualSleeper
        let clock: DogfoodTestClock
        let store: DogfoodCaptureStore
        let directory: URL
        let recordURL: URL

        func readBack(at url: URL? = nil) -> DogfoodCaptureRecord? {
            let target = url ?? recordURL
            guard let data = try? Data(contentsOf: target) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(DogfoodCaptureRecord.self, from: data)
        }
    }

    private func makeWatcher(writeRecord: Bool = true) -> WatcherHarness {
        let monitor = DogfoodEditSignalTestMonitor()
        let sleeper = DogfoodManualSleeper()
        let clock = DogfoodTestClock()
        let watcher = DogfoodEditSignalWatcher(
            monitor: monitor,
            now: { clock.now() },
            sleepFor: { await sleeper.sleep($0) }
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-edit-signal-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            // Release any window still parked on the sleeper, so a test that
            // ended before its window did leaves no unresumed continuation.
            sleeper.fireAll()
            try? FileManager.default.removeItem(at: directory)
        }
        let store = DogfoodCaptureStore(directoryURL: directory, now: { clock.now() })

        var recordURL = directory.appendingPathComponent("missing.json", isDirectory: false)
        if writeRecord {
            recordURL = (try? store.write(makeRecord(capturedAt: clock.now()))) ?? recordURL
        }

        return WatcherHarness(
            watcher: watcher,
            monitor: monitor,
            sleeper: sleeper,
            clock: clock,
            store: store,
            directory: directory,
            recordURL: recordURL
        )
    }

    private func makeRecord(capturedAt: Date) -> DogfoodCaptureRecord {
        DogfoodCaptureRecord(
            id: UUID().uuidString,
            capturedAt: capturedAt,
            session: .init(
                targetBundleID: "com.mitchellh.ghostty",
                targetKind: "terminal-like",
                outputMode: "overlay_buffer",
                promptProfile: "agent",
                endpointClass: "loopback",
                polishModel: "qwen35-4b"
            ),
            join: nil,
            screen: nil,
            allocation: [],
            sources: [],
            text: .init(
                rawTranscript: "run the tests",
                workingText: "run the tests",
                groundedText: "run the tests",
                systemPrompt: nil,
                userPrompts: [],
                polishedOutput: nil,
                committedText: nil
            ),
            timings: .init()
        )
    }
}

#endif
