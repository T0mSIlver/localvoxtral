#if LOCALVOXTRAL_DOGFOOD

import AppKit
import Foundation
import XCTest
@testable import localvoxtral

/// The wiring that turns one polished dictation into one on-disk capture
/// record. Drives the REAL `finishStoppedSession` polish/commit path (the same
/// harness as the polish-failure diagnostics suite) and reads the record back.
@MainActor
final class DogfoodCaptureWiringTests: XCTestCase {
    // DictationViewModel owns app-lifetime services; retain test instances for
    // the process lifetime (mirrors the token-guard suite).
    private static var retainedViewModels: [DictationViewModel] = []

    /// Armed build + armed runtime flag: a polished overlay commit writes
    /// exactly one record whose text stages, session facts, join abstention,
    /// and screen decision describe the dictation that just committed.
    func testPolishedCommitWritesOneAttributableRecord() async throws {
        let harness = try makeHarness(dogfoodArmed: true)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let records = try recordsOnDisk(in: harness.captureDirectory)
        XCTAssertEqual(records.count, 1, "one dictation writes exactly one record")
        let record = records[0]

        XCTAssertEqual(record.schemaVersion, DogfoodCaptureRecord.currentSchemaVersion)
        XCTAssertFalse(record.flagged)

        // Text stages, in pipeline order.
        XCTAssertEqual(record.text.rawTranscript, "polish this text")
        XCTAssertEqual(record.text.workingText, "polish this text")
        XCTAssertEqual(record.text.groundedText, "polish this text")
        XCTAssertEqual(record.text.polishedOutput, "polished output text")
        XCTAssertEqual(record.text.committedText, "polished output text")
        XCTAssertFalse(record.text.userPrompts.isEmpty, "the rendered prompt is the payload")
        XCTAssertEqual(record.text.systemPrompt, "system")

        // Session facts.
        XCTAssertEqual(record.session.outputMode, DictationOutputMode.overlayBuffer.rawValue)
        XCTAssertEqual(record.session.endpointClass, "loopback")
        XCTAssertNotNil(record.session.promptProfile)
        XCTAssertNotNil(record.session.polishModel)

        // No session start ran, so no join was resolved: the record must say
        // "none" rather than omitting the block.
        XCTAssertEqual(record.join?.arm, "none")

        // No start capture: the decision is drop(no-start-capture), and the
        // record's screen block must carry that exact cause.
        XCTAssertEqual(record.screen?.decision, "drop")
        XCTAssertEqual(record.screen?.cause, "no-start-capture")

        // Nothing demanded, so no allocation rows and no sources.
        XCTAssertEqual(record.allocation, [])
        XCTAssertEqual(record.sources, [])

        // Timings: the polish duration came from the service; the capture
        // measured itself.
        XCTAssertEqual(record.timings.polishSeconds, 0.25)
        XCTAssertNotNil(record.timings.captureMilliseconds)
    }

    /// The compile flag alone must not collect: with the runtime opt-in off,
    /// the same commit writes nothing.
    func testDisarmedRuntimeFlagWritesNothing() async throws {
        let harness = try makeHarness(dogfoodArmed: false)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: harness.captureDirectory.path),
            "a disarmed build must not even create the capture directory"
        )
    }

    /// A failing store must cost the record, never the commit: the dictation
    /// still commits and the session completes.
    func testCaptureWriteFailureDoesNotBreakTheCommit() async throws {
        // A file where the capture DIRECTORY should be: every write fails.
        let harness = try makeHarness(dogfoodArmed: true, blockCaptureDirectory: true)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertFalse(harness.viewModel.isCompletingStoppedSession)
        XCTAssertEqual(
            harness.viewModel.currentDictationEventText, "polished output text",
            "the committed text must be unaffected by a capture-write failure"
        )
    }

    /// A join abstention noted at (a would-be) session start is consumed into
    /// the record; a second dictation does not inherit it.
    func testJoinAbstentionRidesTheRecordOnceAndIsConsumed() async throws {
        let harness = try makeHarness(dogfoodArmed: true)
        DogfoodCaptureTap.shared.beginSession()
        DogfoodCaptureTap.shared.noteJoinAbstention("tty: stale")
        DogfoodCaptureTap.shared.noteJoinAbstention("marker: no marker in title")

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let first = try recordsOnDisk(in: harness.captureDirectory)
        XCTAssertEqual(
            first.last?.join?.abstentionReason,
            "tty: stale; marker: no marker in title"
        )

        // A second commit on a fresh session must not repeat the reason.
        let second = try makeHarness(dogfoodArmed: true)
        second.viewModel.finishStoppedSession(promotePendingSegment: false)
        await second.viewModel.polishAndCommitTask?.value
        let records = try recordsOnDisk(in: second.captureDirectory)
        XCTAssertNil(records.last?.join?.abstentionReason)
    }

    /// Populated sources ride the commit path into the record: a clipboard
    /// context produces its allocation row and harvested source row, and a
    /// repo-vocabulary outcome (with its tapped harvest) produces the
    /// `repoVocabulary` row AND its pre-application shows in `groundedText`.
    /// This is the end-to-end lock on the demand/grant/rendered extraction and
    /// the tap→record path, which the builder unit tests alone cannot see
    /// (review, 2026-07-25).
    func testPopulatedSourcesProduceAllocationAndSourceRows() async throws {
        let harness = try makeHarness(dogfoodArmed: true)
        harness.viewModel.settings.polishClipboardContextEnabled = true
        harness.viewModel.settings.repoVocabularyEnabled = true
        harness.viewModel.debugPolishContextPasteboardReaderOverride = {
            WiringPasteboardStub(text: "error in PolishContextBudget.swift line 40")
        }
        harness.viewModel.debugRepoVocabularyEntriesOverride = { _ in
            RepoVocabularyMatcher.GroundingOutcome(
                entries: [ReplacementEntry(replaceWith: "herdr", matches: ["herder"])],
                isFallbackOnly: false
            )
        }
        DogfoodCaptureTap.shared.beginSession()
        DogfoodCaptureTap.shared.noteRepoVocabularyHarvest(["herdr", "pane.read"])
        harness.viewModel.currentDictationEventText = "join the herder pane"

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)

        // Grounding pre-applied the repo entry before the model saw the text.
        XCTAssertEqual(record.text.groundedText, "join the herdr pane")

        // One allocation row: only the clipboard declared a render demand.
        XCTAssertEqual(record.allocation.count, 1)
        let allocation = record.allocation[0]
        XCTAssertEqual(allocation.source, "clipboard")
        XCTAssertGreaterThan(allocation.demandedCharacters, 0)
        XCTAssertEqual(allocation.grantedCharacters, allocation.demandedCharacters)
        XCTAssertEqual(allocation.renderedCharacters, allocation.demandedCharacters)
        XCTAssertFalse(allocation.excerptWasSelected)

        let sourceNames = record.sources.map(\.source)
        XCTAssertEqual(sourceNames, ["repoVocabulary", "clipboard"])

        let repoRow = record.sources[0]
        XCTAssertEqual(repoRow.harvest, ["herdr", "pane.read"])
        XCTAssertEqual(repoRow.entries, [.init(term: "herdr", heard: ["herder"])])

        let clipboardRow = record.sources[1]
        XCTAssertTrue(
            clipboardRow.harvest.contains("PolishContextBudget.swift"),
            "the clipboard's technical entities are the harvest: \(clipboardRow.harvest)"
        )
        XCTAssertEqual(
            clipboardRow.renderedExcerpt,
            "error in PolishContextBudget.swift line 40"
        )
    }

    /// The MAJOR from the 2026-07-25 review: a deadline-abandoned repo
    /// vocabulary pipeline finishing AFTER its session ended must not write its
    /// harvest into the next session's slot. Notes carry the generation they
    /// were created under; a stale one is dropped.
    func testStaleGenerationHarvestNoteIsRejected() {
        let tap = DogfoodCaptureTap.shared
        tap.beginSession()
        let staleGeneration = tap.currentGeneration
        tap.beginSession() // the next dictation began; the old pipeline is stale

        DogfoodCaptureTap.$noteGeneration.withValue(staleGeneration) {
            tap.noteRepoVocabularyHarvest(["previous-session-term"])
        }
        XCTAssertNil(
            tap.consumeRepoVocabularyHarvest(),
            "a stale pipeline's harvest must not survive into the new session"
        )

        DogfoodCaptureTap.$noteGeneration.withValue(tap.currentGeneration) {
            tap.noteRepoVocabularyHarvest(["current-session-term"])
        }
        XCTAssertEqual(tap.consumeRepoVocabularyHarvest(), ["current-session-term"])
    }

    /// The generation BINDING itself, through the real pipeline-task path: a
    /// harvest noted from inside the detached pipeline (via the seam, which
    /// shares `detachedRepoVocabularyPipeline` with production) carries the
    /// creation-time generation and lands in the record. Deleting the
    /// `withValue` binding would not fail this test — the next one exists for
    /// that (verification review, 2026-07-25).
    func testPipelineNotedHarvestRidesTheBindingIntoTheRecord() async throws {
        let harness = try makeHarness(dogfoodArmed: true)
        harness.viewModel.settings.polishClipboardContextEnabled = true
        harness.viewModel.settings.repoVocabularyEnabled = true
        harness.viewModel.debugPolishContextPasteboardReaderOverride = {
            WiringPasteboardStub(text: "clipboard text")
        }
        harness.viewModel.debugRepoVocabularyPipelineOverride = { _ in
            DogfoodCaptureTap.shared.noteRepoVocabularyHarvest(["pipeline-term"])
            return .empty
        }
        DogfoodCaptureTap.shared.beginSession()

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)
        let repoRow = record.sources.first { $0.source == "repoVocabulary" }
        XCTAssertEqual(repoRow?.harvest, ["pipeline-term"])
    }

    /// The MAJOR's end-to-end regression: a pipeline whose session has ended
    /// (the next dictation's `beginSession` ran) must have its harvest note
    /// REJECTED — because the detached task carries the creation-time
    /// generation. This is the test that fails if the `withValue` binding is
    /// removed from `detachedRepoVocabularyPipeline`: an unbound note fails
    /// open and the stale harvest would land in the record.
    func testAbandonedPipelineHarvestIsRejectedByTheBinding() async throws {
        let harness = try makeHarness(dogfoodArmed: true)
        harness.viewModel.settings.polishClipboardContextEnabled = true
        harness.viewModel.settings.repoVocabularyEnabled = true
        harness.viewModel.debugPolishContextPasteboardReaderOverride = {
            WiringPasteboardStub(text: "clipboard text")
        }
        harness.viewModel.debugRepoVocabularyPipelineOverride = { _ in
            // The next dictation begins while this pipeline is still running…
            DogfoodCaptureTap.shared.beginSession()
            // …so its late note is stale and must be dropped.
            DogfoodCaptureTap.shared.noteRepoVocabularyHarvest(["stale-term"])
            return .empty
        }
        DogfoodCaptureTap.shared.beginSession()

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)
        XCTAssertNil(
            record.sources.first { $0.source == "repoVocabulary" },
            "a stale pipeline's harvest must not reach any record"
        )
    }

    /// A stopped-with-no-speech session writes nothing: there was no polish
    /// call and there is nothing to attribute.
    func testEmptyDictationWritesNoRecord() async throws {
        let harness = try makeHarness(dogfoodArmed: true)
        harness.viewModel.currentDictationEventText = "   "

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertEqual(try recordsOnDisk(in: harness.captureDirectory).count, 0)
    }

    // MARK: - Post-commit edit signal

    /// The commit path arms the watch and hands it the record it just wrote: a
    /// Backspace inside the window patches THAT record, in place.
    func testCommitArmsTheEditWatchAndPatchesItsOwnRecord() async throws {
        let signals = EditSignalHarness()
        let harness = try makeHarness(dogfoodArmed: true, editSignal: signals)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertEqual(signals.monitor.startCount, 1, "the commit opened a window")
        // "polished output text" is three words: the 1–5 rung of the ladder.
        await signals.sleeper.waitForSleepRequest()
        XCTAssertEqual(signals.sleeper.requestedDurations, [.seconds(2.0)])

        signals.clock.advance(0.5)
        signals.monitor.send(.backspace)
        await signals.watcher.flushTask?.value

        let records = try recordsOnDisk(in: harness.captureDirectory)
        XCTAssertEqual(records.count, 1, "the signal patches the record, never adds one")
        let behavior = try XCTUnwrap(records[0].behavior)
        XCTAssertEqual(behavior.outcome, .edited)
        XCTAssertEqual(behavior.signal, .backspace)
        XCTAssertEqual(behavior.secondsSinceCommitBucket, "0-1")
        XCTAssertEqual(behavior.wordCountBucket, "1-5")
        XCTAssertEqual(behavior.outputMode, DictationOutputMode.overlayBuffer.rawValue)

        // The rest of the record is untouched by the patch.
        XCTAssertEqual(records[0].text.committedText, "polished output text")
        XCTAssertNotNil(records[0].timings.captureMilliseconds)
    }

    /// A window that closes unobserved still patches its record: the clean
    /// outcome is the denominator an edit rate needs.
    func testUneventfulWindowPatchesTheCleanOutcome() async throws {
        let signals = EditSignalHarness()
        let harness = try makeHarness(dogfoodArmed: true, editSignal: signals)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        let windowTask = signals.watcher.windowTask
        signals.clock.advance(2)
        signals.sleeper.fireAll()
        await windowTask?.value
        await signals.watcher.flushTask?.value

        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)
        XCTAssertEqual(record.behavior?.outcome, .clean)
        XCTAssertNil(record.behavior?.signal)
    }

    /// The compile flag alone must not watch either: with the runtime opt-in
    /// off, no observer is ever installed.
    func testDisarmedRuntimeFlagNeverInstallsAnObserver() async throws {
        let signals = EditSignalHarness()
        let harness = try makeHarness(dogfoodArmed: false, editSignal: signals)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertEqual(signals.monitor.startCount, 0)
        XCTAssertFalse(signals.watcher.isWatching)
        XCTAssertTrue(signals.sleeper.requestedDurations.isEmpty)
    }

    /// A stopped-with-no-speech session has nothing to attribute and nothing to
    /// watch — the guard that skips the record skips the observer too.
    func testEmptyDictationNeverInstallsAnObserver() async throws {
        let signals = EditSignalHarness()
        let harness = try makeHarness(dogfoodArmed: true, editSignal: signals)
        harness.viewModel.currentDictationEventText = "   "

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertEqual(signals.monitor.startCount, 0)
    }

    /// A commit that never landed must not be watched: `.failed` leaves nothing
    /// in the target app to erase, so a Backspace typed there would be recorded
    /// as erasing an insertion that never happened — and an uneventful window
    /// would pad the `clean` denominator with unwatchable dictations. The
    /// record itself is still written; it just carries no behavior block.
    func testFailedCommitNeverArmsTheWatch() async throws {
        let signals = EditSignalHarness()
        let harness = try makeHarness(
            dogfoodArmed: true,
            editSignal: signals,
            commitOutcome: .failed(message: "insertion failed")
        )

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertEqual(signals.monitor.startCount, 0, "nothing was inserted; nothing to watch")
        XCTAssertFalse(signals.watcher.isWatching)
        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)
        XCTAssertNil(record.behavior, "an unwatched dictation keeps no behavior block")
    }

    /// Same rule for the Secure Keyboard Entry fallback: the text went to the
    /// clipboard, not the target app, so post-commit keys say nothing about it.
    func testClipboardFallbackCommitNeverArmsTheWatch() async throws {
        let signals = EditSignalHarness()
        let harness = try makeHarness(
            dogfoodArmed: true,
            editSignal: signals,
            commitOutcome: .copiedToClipboard(message: "Copied to clipboard")
        )

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        XCTAssertEqual(signals.monitor.startCount, 0)
        XCTAssertFalse(signals.watcher.isWatching)
        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)
        XCTAssertNil(record.behavior)
    }

    /// The watch window must scale with what was actually inserted. A
    /// clipboard-payload commit inserts the substituted payload, not the
    /// placeholder — a 100-word paste takes far longer to judge than one
    /// placeholder token, so it gets the 15 s rung, not 2 s. The payload
    /// itself must still never reach the record: only the window length (and
    /// the bucket it implies) may reflect it.
    func testClipboardPayloadWindowScalesWithTheInsertedPayload() async throws {
        let signals = EditSignalHarness()
        let harness = try makeHarness(dogfoodArmed: true, editSignal: signals)
        harness.viewModel.settings.clipboardPayloadMacroEnabled = true
        let payload = (0..<100).map { "word\($0)" }.joined(separator: " ")
        harness.viewModel.debugClipboardPayloadPasteboardReaderOverride = {
            WiringPasteboardStub(text: payload)
        }
        // The polish stub returns text without the placeholder, so the
        // placeholder-count guard discards the polish and commits the
        // placeholder-bearing grounded text — payload-substituted at commit.
        harness.viewModel.currentDictationEventText = "paste clipboard"

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value

        await signals.sleeper.waitForSleepRequest()
        XCTAssertEqual(
            signals.sleeper.requestedDurations, [.seconds(15.0)],
            "the window measures the substituted commit, not its placeholder"
        )

        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)
        XCTAssertEqual(
            record.text.committedText, ClipboardPayloadMacro.placeholder,
            "measuring the payload must not persist it"
        )

        signals.clock.advance(1)
        signals.monitor.send(.backspace)
        await signals.watcher.flushTask?.value
        let behavior = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last?.behavior)
        XCTAssertEqual(behavior.wordCountBucket, "41+", "buckets follow the inserted length")
        XCTAssertEqual(behavior.watchWindowSeconds, 15)
    }

    /// FINDING 3, at the notification wiring: the flush must run INLINE in the
    /// `willTerminateNotification` observer. The observer's synchronous return
    /// is the last execution the process guarantees — a Task spawned there is
    /// not guaranteed to run — so the record must already be patched when
    /// `post` returns, with deliberately no await in between. A private
    /// notification center keeps the post from reaching every other retained
    /// view model in the suite.
    func testWillTerminateNotificationFlushesTheOpenWatchInline() async throws {
        let signals = EditSignalHarness()
        let harness = try makeHarness(dogfoodArmed: true, editSignal: signals)
        let center = NotificationCenter()
        harness.viewModel.debugRegisterLifecycleObservers(on: center)

        harness.viewModel.finishStoppedSession(promotePendingSegment: false)
        await harness.viewModel.polishAndCommitTask?.value
        XCTAssertTrue(signals.watcher.isWatching, "the commit opened a window")

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        let record = try XCTUnwrap(recordsOnDisk(in: harness.captureDirectory).last)
        XCTAssertEqual(
            record.behavior?.outcome, .superseded,
            "the patch must be on disk when the observer returns"
        )
        XCTAssertFalse(signals.watcher.isWatching)
    }

    // MARK: - Builder

    func testEndpointClassBuckets() {
        let cases: [(String, String)] = [
            ("http://127.0.0.1:8472/v1", "loopback"),
            ("http://localhost:8080/v1", "loopback"),
            ("http://[::1]:8080/v1", "loopback"),
            ("http://192.168.1.183:8080/v1", "lan"),
            ("http://10.0.0.7/v1", "lan"),
            ("http://172.20.0.2/v1", "lan"),
            ("http://mac-studio.local:8080/v1", "lan"),
            ("http://172.15.0.2/v1", "remote"),
            ("https://api.example.com/v1", "remote"),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(
                DogfoodCaptureBuilder.endpointClass(of: URL(string: url)!),
                expected, url
            )
        }
    }

    func testJoinBuilderMapsResolvedAndAbstainedJoins() {
        let unresolved = DogfoodCaptureBuilder.join(
            from: nil, abstentions: ["gate: accessibility not trusted"]
        )
        XCTAssertEqual(unresolved.arm, "none")
        XCTAssertEqual(unresolved.abstentionReason, "gate: accessibility not trusted")
        XCTAssertNil(unresolved.origin)

        let empty = DogfoodCaptureBuilder.join(from: nil, abstentions: [])
        XCTAssertEqual(empty.arm, "none")
        XCTAssertNil(empty.abstentionReason)

        // Every arm needs its own name in the record: a mis-blamed retrieval
        // stage is exactly the attribution this capture exists to prevent.
        let snapshot = ClaudeSessionSnapshot(
            sessionID: "s1",
            origin: .localAuthenticated(peerUID: 501),
            marker: ClaudeSessionMarker(value: "lvx-abcd"),
            firstSeen: Date(timeIntervalSince1970: 1_000_000)
        )
        let cmuxJoin = DogfoodCaptureBuilder.join(
            from: ClaudeSessionJoin(
                target: TerminalScreenTarget(
                    pid: 4242, bundleID: TerminalScreenAllowlist.cmuxBundleID
                ),
                marker: snapshot.marker,
                snapshot: snapshot,
                windowID: 101,
                mechanism: .cmuxSurface,
                cmuxSurface: ClaudeCmuxSurfaceBinding(surfaceID: "surface-a")
            ),
            abstentions: []
        )
        XCTAssertEqual(cmuxJoin.arm, "cmuxSurface")
        XCTAssertEqual(cmuxJoin.terminal, TerminalScreenAllowlist.cmuxBundleID)
        XCTAssertEqual(cmuxJoin.origin, "local")
        XCTAssertEqual(
            cmuxJoin.herdrBound, false,
            "a cmux join is not a herdr binding, and the record must not imply one"
        )
    }

    func testScreenBuilderRouteAndCause() {
        let vocabOnly = DogfoodCaptureBuilder.screen(
            from: .vocabularyOnly(
                startText: "screen text",
                cause: .screenChanged(stopLength: 10, differingLines: 3, firstDifferingLine: 0)
            ),
            targetBundleID: TerminalScreenAllowlist.ghosttyBundleID,
            socketPaneSwapApplied: false
        )
        XCTAssertEqual(vocabOnly.route, "axGrid")
        XCTAssertEqual(vocabOnly.decision, "vocabularyOnly")
        XCTAssertEqual(vocabOnly.cause, "screen-changed(stop:10ch lines:3 first:0)")
        XCTAssertEqual(vocabOnly.sanitizedText, "screen text")
        XCTAssertEqual(vocabOnly.sanitizedCharacterCount, "screen text".count)

        let appleScript = DogfoodCaptureBuilder.screen(
            from: .render(excerpt: "e", startText: "s", elidedChurnLines: 0),
            targetBundleID: TerminalScreenAllowlist.iterm2BundleID,
            socketPaneSwapApplied: false
        )
        XCTAssertEqual(appleScript.route, "appleScriptContents")
        XCTAssertEqual(appleScript.decision, "render")

        let herdr = DogfoodCaptureBuilder.screen(
            from: .render(excerpt: "pane", startText: "pane", elidedChurnLines: 0),
            targetBundleID: TerminalScreenAllowlist.ghosttyBundleID,
            socketPaneSwapApplied: true
        )
        XCTAssertEqual(herdr.route, "herdrPaneRead")

        // Same swap flag, different app: the record must name WHICH socket
        // answered, or a cmux surface read reads back as a herdr pane read.
        let cmux = DogfoodCaptureBuilder.screen(
            from: .render(excerpt: "surface", startText: "surface", elidedChurnLines: 0),
            targetBundleID: TerminalScreenAllowlist.cmuxBundleID,
            socketPaneSwapApplied: true
        )
        XCTAssertEqual(cmux.route, "cmuxSurfaceRead")

        let dropped = DogfoodCaptureBuilder.screen(
            from: .drop(reason: .targetChanged),
            targetBundleID: nil,
            socketPaneSwapApplied: false
        )
        XCTAssertEqual(dropped.decision, "drop")
        XCTAssertEqual(dropped.cause, "target-changed")
        XCTAssertNil(dropped.route)
        XCTAssertNil(dropped.sanitizedText)
    }

    func testAllocationsKeepZeroGrantsAndDropZeroDemands() {
        let rows = DogfoodCaptureBuilder.allocations(
            demands: [.repository: 9000, .terminal: 0, .clipboard: 200],
            grants: [.repository: 0, .clipboard: 200],
            rendered: [.clipboard: 180]
        )
        XCTAssertEqual(rows.count, 2, "zero-demand sources leave no row")

        let repo = rows[0]
        XCTAssertEqual(repo.source, "repository")
        XCTAssertEqual(repo.demandedCharacters, 9000)
        XCTAssertEqual(repo.grantedCharacters, 0)
        XCTAssertTrue(
            repo.excerptWasSelected,
            "a starved source is exactly what bucket 4 needs recorded"
        )

        let clipboard = rows[1]
        XCTAssertEqual(clipboard.source, "clipboard")
        XCTAssertFalse(clipboard.excerptWasSelected)
        XCTAssertEqual(clipboard.renderedCharacters, 180)
    }

    func testHarvestListIsCappedInTheRecordOnly() {
        let harvest = (0..<(DogfoodCaptureBuilder.harvestTermCap + 7)).map { "term\($0)" }
        let row = DogfoodCaptureBuilder.source(DogfoodCaptureBuilder.SourceInputs(
            source: .clipboard,
            harvest: harvest,
            outcome: .empty,
            renderedExcerpt: nil
        ))
        XCTAssertEqual(row.harvest.count, DogfoodCaptureBuilder.harvestTermCap)
        XCTAssertEqual(row.harvestCount, harvest.count, "the true pool size survives the cap")
        XCTAssertTrue(row.harvestTruncated)
    }

    func testTapBeginSessionClearsBothSlots() {
        DogfoodCaptureTap.shared.beginSession()
        DogfoodCaptureTap.shared.noteJoinAbstention("tty: stale")
        DogfoodCaptureTap.shared.noteRepoVocabularyHarvest(["Term"])
        DogfoodCaptureTap.shared.beginSession()
        XCTAssertEqual(DogfoodCaptureTap.shared.consumeJoinAbstentions(), [])
        XCTAssertNil(DogfoodCaptureTap.shared.consumeRepoVocabularyHarvest())
    }

    // MARK: - Harness (mirrors the polish-failure diagnostics suite)

    private struct Harness {
        let viewModel: DictationViewModel
        let captureDirectory: URL
    }

    /// The injected seams of the post-commit edit watch, bundled so a test can
    /// drive the window without wall-clock.
    @MainActor
    private struct EditSignalHarness {
        let monitor = DogfoodEditSignalTestMonitor()
        let sleeper = DogfoodManualSleeper()
        let clock = DogfoodTestClock()
        let watcher: DogfoodEditSignalWatcher

        init() {
            let monitor = self.monitor
            let sleeper = self.sleeper
            let clock = self.clock
            watcher = DogfoodEditSignalWatcher(
                monitor: monitor,
                now: { clock.now() },
                sleepFor: { await sleeper.sleep($0) }
            )
        }
    }

    private func makeHarness(
        dogfoodArmed: Bool,
        blockCaptureDirectory: Bool = false,
        editSignal: EditSignalHarness? = nil,
        commitOutcome: OverlayBufferCommitOutcome = .succeeded
    ) throws -> Harness {
        let settings = makeSettings()
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .managedLocal
        settings.dogfoodCaptureEnabled = dogfoodArmed

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-wiring-\(UUID().uuidString)", isDirectory: true)
        let captureDirectory = base.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if blockCaptureDirectory {
            // A regular FILE at the directory path: every store write fails.
            try Data("not a directory".utf8).write(
                to: captureDirectory, options: []
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }

        let overlayCoordinator = WiringMockOverlayCoordinator()
        overlayCoordinator.commitOutcome = commitOutcome
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = WiringMockAppConfigStore()
        viewModel.llmPolishingService = SucceedingPolishingService()
        viewModel.dogfoodCaptureStore = DogfoodCaptureStore(directoryURL: captureDirectory)
        // Always injected, even for the tests that ignore it: the production
        // watcher would arm a REAL 2 s timer on a process-retained view model,
        // and this suite does not add wall-clock timers (AGENTS.md).
        let signals = editSignal ?? EditSignalHarness()
        viewModel.dogfoodEditSignalWatcher = signals.watcher
        let sleeper = signals.sleeper
        addTeardownBlock {
            // Release a window the test never closed, so no continuation is
            // left unresumed behind it.
            sleeper.fireAll()
        }
        viewModel.isShowingConnectionFailureAlert = true
        Self.retainedViewModels.append(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "polish this text"
        return Harness(viewModel: viewModel, captureDirectory: captureDirectory)
    }

    /// Decoded records, oldest first.
    private func recordsOnDisk(in directory: URL) throws -> [DogfoodCaptureRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path).sorted()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try names.map { name in
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            return try decoder.decode(DogfoodCaptureRecord.self, from: data)
        }
    }

    private func makeSettings() -> SettingsStore {
        let suiteName = "localvoxtral.DogfoodCaptureWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = .overlayBuffer
        return settings
    }
}

/// A plain-text pasteboard with no concealed/transient markers.
private final class WiringPasteboardStub: PasteboardReading {
    private let text: String
    init(text: String) { self.text = text }
    func types() -> [NSPasteboard.PasteboardType]? { [.string] }
    func string() -> String? { text }
}

/// Always polishes successfully, without networking.
private actor SucceedingPolishingService: LLMPolishingServicing {
    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        LLMPolishingResult(
            rawText: request.inputText,
            polishedText: "polished output text",
            durationSeconds: 0.25
        )
    }
}

private final class WiringMockAppConfigStore: AppConfigServing {
    func configDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        ReplacementDictionary(entries: [])
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        LLMPromptTemplates(systemContent: "system", userContent: "{{input_text}}")
    }

    func loadTerminalAppBundleIDs() -> [String] {
        []
    }
}

@MainActor
private final class WiringMockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil
    /// What `commitIfNeeded` reports — the seam for the failed / clipboard-
    /// fallback arming tests.
    var commitOutcome: OverlayBufferCommitOutcome = .succeeded

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor _: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText _: String, commitBufferText _: String) {}
    func refresh(displayBufferText _: String, commitBufferText _: String) {}

    func commitIfNeeded(
        using _: OverlayTextCommitting,
        autoCopyEnabled _: Bool
    ) -> OverlayBufferCommitOutcome {
        commitOutcome
    }

    func dismissAfterHold(minimumVisibility _: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
    func markPolished(_: Bool) {}
}

#endif
