import XCTest
@testable import localvoxtral

#if DEBUG
/// Live Auto-Paste replacement strategy selection at session start:
/// terminal-like targets and caret-less targets must apply replacements
/// BEFORE typing (hold-back stream, zero backspaces), while readable-caret
/// regular targets keep the guarded backspace corrector.
@MainActor
final class TextInsertionServiceLiveStrategyTests: XCTestCase {
    // Field repro (owner's Mac, 2026-07-06): dictating into a terminal
    // (Ghostty, Claude Code TUI) with one replacement entry. The terminal
    // exposes a READABLE AX caret, but it is a screen-grid cursor over the
    // whole scrollback buffer, so it can never match the tracked session
    // span. The first correction attempt timed out ("corrector settle
    // timeout") and the corrector stood down for the whole session
    // ("stand-down reason=tracked caret diverged") — replacement entries
    // never applied in terminals.
    func testTerminalLikeSessionAppliesReplacementWithoutBackspaces() async {
        let service = TextInsertionService()
        var typedChunks: [String] = []
        var backspaceEvents: [Int] = []
        service.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typedChunks.append(chunk)
                return true
            },
            backspacePoster: { count in
                backspaceEvents.append(count)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            // Terminal grid caret: readable, but pinned to a screen position
            // that never matches startCaret + insertedUTF16Length.
            caretLocationReader: { _ in 4242 },
            liveReplacementSettleSleep: {}
        )

        service.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
            ]),
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("vox")
        service.enqueueRealtimeInsertion("tral ")
        await service.debugWaitForLiveReplacementCorrectionTasks()
        service.flushFinalLiveReplacementCorrections()
        await service.debugWaitForLiveReplacementCorrectionTasks()

        XCTAssertEqual(
            backspaceEvents, [],
            "terminal-safe live sessions must never post backspace events"
        )
        XCTAssertEqual(typedChunks.joined(), "localvoxtral ")
        service.endLiveReplacementSession()
    }

    func testTerminalLikeSessionSanitizesNewlinesInReleasedText() {
        let harness = makeServiceHarness(caretLocationReader: { _ in 4242 })
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        harness.service.enqueueRealtimeInsertion("run\n\nthe tests ")
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(harness.typed.value.joined(), "run the tests ")
        XCTAssertEqual(harness.backspaces.value, [])
    }

    func testTerminalLikeSessionSanitizesNewlinesInFlushedRemainder() {
        let harness = makeServiceHarness(caretLocationReader: { _ in 4242 })
        harness.service.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["local voxtral"]),
            ]),
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        // The two-word rule holds everything back, so the newline is still
        // held at session stop and must be sanitized on the remainder flush.
        harness.service.enqueueRealtimeInsertion("run\nit")
        XCTAssertEqual(harness.typed.value, [])
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(harness.typed.value.joined(), "run it")
        XCTAssertEqual(harness.backspaces.value, [])
    }

    func testTerminalLikeSessionWithoutDictionaryStillSanitizesNewlines() {
        let harness = makeServiceHarness(caretLocationReader: { _ in 4242 })
        harness.service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        harness.service.enqueueRealtimeInsertion("git status\n")
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(harness.typed.value.joined(), "git status ")
        XCTAssertEqual(harness.backspaces.value, [])
    }

    func testCaretUnreadableSessionAppliesReplacementWithoutBackspaces() {
        let harness = makeServiceHarness(caretLocationReader: { _ in nil })
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )
        XCTAssertTrue(harness.service.debugLiveHoldBackStreamIsActive)

        harness.service.enqueueRealtimeInsertion("vox")
        harness.service.enqueueRealtimeInsertion("tral ")
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(harness.typed.value.joined(), "localvoxtral ")
        XCTAssertEqual(
            harness.backspaces.value, [],
            "caret-unreadable sessions must never post unverified backspaces"
        )
    }

    func testCaretUnreadableNonTerminalSessionPreservesNewlines() {
        let harness = makeServiceHarness(caretLocationReader: { _ in nil })
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        harness.service.enqueueRealtimeInsertion("voxtral\nrocks ")
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(harness.typed.value.joined(), "localvoxtral\nrocks ")
    }

    func testCaretReadableNonTerminalSessionStillUsesGuardedCorrector() {
        let field = FakeCaretField()
        let harness = makeServiceHarness(
            field: field,
            caretLocationReader: { _ in (field.value as NSString).length }
        )
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )
        XCTAssertFalse(harness.service.debugLiveHoldBackStreamIsActive)
        XCTAssertTrue(harness.service.debugLiveReplacementCorrectorIsActive)

        harness.service.enqueueRealtimeInsertion("voxtral ")

        // Existing behavior preserved exactly: type raw, then backspace and
        // retype under the caret guard.
        XCTAssertEqual(harness.typed.value, ["voxtral ", "localvoxtral "])
        XCTAssertEqual(harness.backspaces.value, [8])
        XCTAssertEqual(field.value, "localvoxtral ")
    }

    func testHeldTextIsTypedOnFinalFlush() {
        let harness = makeServiceHarness(caretLocationReader: { _ in 4242 })
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        harness.service.enqueueRealtimeInsertion("voxtral")
        XCTAssertEqual(harness.typed.value, [], "partial word must stay held")

        harness.service.flushFinalLiveReplacementCorrections()
        XCTAssertEqual(harness.typed.value, ["localvoxtral"])
        XCTAssertEqual(harness.backspaces.value, [])
    }

    func testFailedHoldBackReleaseIsRetriedWithoutDuplication() {
        let typed = Box<[String]>([])
        let failuresRemaining = Box(1)
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                if failuresRemaining.value > 0 {
                    failuresRemaining.value -= 1
                    return false
                }
                typed.value.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            caretLocationReader: { _ in 4242 }
        )
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("voxtral ")
        XCTAssertEqual(typed.value, [])
        XCTAssertTrue(
            service.hasPendingInsertionText,
            "failed release must stay pending so the retry task retries it"
        )

        // Simulates the periodic retry task's call. The trailing space is
        // buffered by the sanitizer until the final flush decides its fate.
        service.flushPendingRealtimeInsertion()

        XCTAssertEqual(
            typed.value, ["localvoxtral"],
            "retried release must be typed exactly once, never re-ingested"
        )
        XCTAssertFalse(service.hasPendingInsertionText)

        service.flushFinalLiveReplacementCorrections()
        XCTAssertEqual(typed.value.joined(), "localvoxtral ")
        service.endLiveReplacementSession()
    }

    // MARK: - Mid-session conversion (guarded corrector → hold-back stream)

    // Field repro (owner's Mac, 2026-07-07): cmux (com.cmuxterm.app) hosts a
    // terminal but reports a WRITABLE focused AX value, so it is honestly
    // classified non-terminal and the guarded corrector arms with
    // caret_guard=on. The terminal grid caret never matches the tracked
    // session span, the first correction times out its settle attempts
    // ("stand-down reason=tracked caret diverged"), and replacements used to
    // go silently dead for the rest of the session. The session must instead
    // CONVERT to the hold-back stream and keep applying replacements to all
    // future text — with zero backspace events after the conversion point.
    func testCaretDivergenceConvertsToHoldBackAndKeepsApplyingReplacements() async {
        // Terminal-grid style caret: readable, but pinned to a location that
        // never matches startCaret + insertedUTF16Length.
        let harness = makeServiceHarness(caretLocationReader: { _ in 4242 })
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )
        XCTAssertTrue(harness.service.debugLiveReplacementCorrectorIsActive)
        XCTAssertFalse(harness.service.debugLiveHoldBackStreamIsActive)

        // First rule match: typed raw, then the deferred correction exhausts
        // its settle attempts against the diverged caret.
        harness.service.enqueueRealtimeInsertion("voxtral ")
        await harness.service.debugWaitForLiveReplacementCorrectionTasks()

        XCTAssertTrue(
            harness.service.debugLiveHoldBackStreamIsActive,
            "caret divergence must convert the session to the hold-back stream"
        )
        XCTAssertFalse(harness.service.debugLiveReplacementCorrectorIsActive)
        XCTAssertEqual(
            harness.typed.value, ["voxtral "],
            "the failed correction's text is already typed raw and stays raw"
        )

        // Second rule match after conversion: applied BEFORE typing.
        harness.service.enqueueRealtimeInsertion("voxtral ")
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(harness.typed.value.joined(), "voxtral localvoxtral ")
        XCTAssertEqual(
            harness.backspaces.value, [],
            "no backspace events may ever be posted after conversion"
        )
        harness.service.endLiveReplacementSession()
    }

    func testKeyboardFailureStandDownDoesNotConvertToHoldBack() {
        let typed = Box<[String]>([])
        let backspaceAttempts = Box<[Int]>([])
        let field = FakeCaretField()
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.value.append(chunk)
                field.value.append(chunk)
                return true
            },
            backspacePoster: { count in
                backspaceAttempts.value.append(count)
                return false
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            caretLocationReader: { _ in (field.value as NSString).length },
            liveReplacementSettleSleep: {}
        )
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        // Caret settles correctly, but the backspace key events cannot post.
        service.enqueueRealtimeInsertion("voxtral ")

        XCTAssertEqual(backspaceAttempts.value, [8])
        XCTAssertFalse(
            service.debugLiveHoldBackStreamIsActive,
            "keyboard-posting failure must stay a true stand-down: the hold-back stream could not type either"
        )
        XCTAssertFalse(service.debugLiveReplacementCorrectorIsActive)

        // Further dictation types raw: no corrections, no stream, no more
        // backspace attempts.
        service.enqueueRealtimeInsertion("voxtral ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "voxtral voxtral ")
        XCTAssertEqual(backspaceAttempts.value, [8])
        XCTAssertFalse(service.debugLiveHoldBackStreamIsActive)
        service.endLiveReplacementSession()
    }

    func testConversionDuringDeferredCorrectionRoutesQueuedTextThroughStreamOnce() async {
        let harness = makeServiceHarness(caretLocationReader: { _ in 4242 })
        harness.service.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
                ReplacementEntry(replaceWith: "chai", matches: ["tea"]),
            ]),
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        harness.service.enqueueRealtimeInsertion("voxtral ")
        XCTAssertTrue(harness.service.debugLiveReplacementCorrectionIsInFlight)

        // Queued while the failing correction is still in flight: must flow
        // into the converted stream exactly once (no drop, no double-type).
        harness.service.enqueueRealtimeInsertion("tea")
        XCTAssertEqual(harness.typed.value, ["voxtral "])

        await harness.service.debugWaitForLiveReplacementCorrectionTasks()

        XCTAssertTrue(harness.service.debugLiveHoldBackStreamIsActive)
        XCTAssertFalse(harness.service.debugLiveReplacementCorrectionIsInFlight)
        XCTAssertFalse(
            harness.service.hasPendingInsertionText,
            "queued text must be ingested into the stream, not left pending"
        )
        XCTAssertEqual(
            harness.typed.value, ["voxtral "],
            "the trailing partial word stays held by the stream, never typed raw"
        )

        harness.service.flushFinalLiveReplacementCorrections()
        XCTAssertEqual(harness.typed.value, ["voxtral ", "chai"])
        XCTAssertEqual(
            harness.backspaces.value, [],
            "no backspaces after conversion, even when the failed correction was mid-defer"
        )
        harness.service.endLiveReplacementSession()
    }

    func testFinalFlushRequestedDuringDeferredCorrectionFlushesConvertedStream() async {
        let harness = makeServiceHarness(caretLocationReader: { _ in 4242 })
        harness.service.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
                ReplacementEntry(replaceWith: "chai", matches: ["tea"]),
            ]),
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        harness.service.enqueueRealtimeInsertion("voxtral ")
        harness.service.enqueueRealtimeInsertion("tea")
        // Session stop while the failing correction is still in flight.
        harness.service.flushFinalLiveReplacementCorrections()
        XCTAssertEqual(harness.typed.value, ["voxtral "])

        await harness.service.debugWaitForLiveReplacementCorrectionTasks()

        XCTAssertEqual(
            harness.typed.value, ["voxtral ", "chai"],
            "the queued final flush must release the converted stream's remainder"
        )
        XCTAssertEqual(harness.backspaces.value, [])
        harness.service.endLiveReplacementSession()
    }

    func testCaretBecomingUnavailableMidSessionConvertsToHoldBack() {
        let caretReads = Box(0)
        // Caret readable at session start (arms the guarded corrector), then
        // unreadable for every later verification.
        let harness = makeServiceHarness(caretLocationReader: { _ in
            caretReads.value += 1
            return caretReads.value == 1 ? 0 : nil
        })
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )
        XCTAssertTrue(harness.service.debugLiveReplacementCorrectorIsActive)

        harness.service.enqueueRealtimeInsertion("voxtral ")

        XCTAssertTrue(
            harness.service.debugLiveHoldBackStreamIsActive,
            "a caret that becomes unavailable mid-session must convert, not stand down"
        )
        XCTAssertEqual(harness.typed.value, ["voxtral "])

        harness.service.enqueueRealtimeInsertion("voxtral ")
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(harness.typed.value.joined(), "voxtral localvoxtral ")
        XCTAssertEqual(harness.backspaces.value, [])
        harness.service.endLiveReplacementSession()
    }

    // MARK: - Post-backspace conversion must restore erased text (codex review, 2026-07-07)

    // The caret matches initially, so the correction's backspaces post and
    // ERASE the matched text — and only then the erased-caret verification
    // fails. Converting without retyping correction.erasedText loses the
    // user's typed text from the target app. The erased text must be
    // restored raw before converting, and a later rule match must still
    // apply through the converted stream.
    func testPostBackspaceCaretLossRestoresErasedTextBeforeConverting() {
        let field = FakeCaretField()
        // begin → 0 (arms guard), inserted-caret check → 8 (matched, so
        // backspaces post), erased-caret check → nil (caret lost).
        let caretScript = Box<[Int?]>([0, 8, nil])
        let harness = makeServiceHarness(
            field: field,
            caretLocationReader: { _ in
                caretScript.value.isEmpty ? nil : caretScript.value.removeFirst()
            }
        )
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        harness.service.enqueueRealtimeInsertion("voxtral ")

        XCTAssertEqual(harness.backspaces.value, [8])
        XCTAssertEqual(
            field.value, "voxtral ",
            "the erased text must be restored before converting"
        )
        XCTAssertTrue(harness.service.debugLiveHoldBackStreamIsActive)

        harness.service.enqueueRealtimeInsertion("voxtral ")
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(
            field.value, "voxtral localvoxtral ",
            "all dictated text must be present in the target after conversion"
        )
        XCTAssertEqual(harness.backspaces.value, [8], "no backspaces after conversion")
        harness.service.endLiveReplacementSession()
    }

    func testDeferredPostBackspaceTimeoutRestoresErasedTextBeforeConverting() async {
        let field = FakeCaretField()
        // begin → 0, inserted-caret check → 7 (mismatch, defers), settle
        // wait → 8 (matched, backspaces post), then 5 forever: the
        // erased-caret wait (expected 0) times out → tracked caret diverged
        // AFTER the erase.
        let caretScript = Box<[Int?]>([0, 7, 8])
        let harness = makeServiceHarness(
            field: field,
            caretLocationReader: { _ in
                caretScript.value.isEmpty ? 5 : caretScript.value.removeFirst()
            }
        )
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        harness.service.enqueueRealtimeInsertion("voxtral ")
        XCTAssertTrue(harness.service.debugLiveReplacementCorrectionIsInFlight)
        await harness.service.debugWaitForLiveReplacementCorrectionTasks()

        XCTAssertEqual(harness.backspaces.value, [8])
        XCTAssertEqual(
            field.value, "voxtral ",
            "the deferred post-backspace timeout must restore the erased text before converting"
        )
        XCTAssertTrue(harness.service.debugLiveHoldBackStreamIsActive)

        harness.service.enqueueRealtimeInsertion("voxtral ")
        harness.service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(field.value, "voxtral localvoxtral ")
        XCTAssertEqual(harness.backspaces.value, [8])
        harness.service.endLiveReplacementSession()
    }

    func testPostBackspaceRestoreFailureStandsDownWithoutConverting() {
        let typed = Box<[String]>([])
        let backspaces = Box<[Int]>([])
        let failNextUnicodePost = Box(false)
        let caretScript = Box<[Int?]>([0, 8, nil])
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                if failNextUnicodePost.value {
                    failNextUnicodePost.value = false
                    return false
                }
                typed.value.append(chunk)
                return true
            },
            backspacePoster: { count in
                backspaces.value.append(count)
                // The restore attempt right after these backspaces fails:
                // the keyboard path is broken.
                failNextUnicodePost.value = true
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            caretLocationReader: { _ in
                caretScript.value.isEmpty ? nil : caretScript.value.removeFirst()
            },
            liveReplacementSettleSleep: {}
        )
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        service.enqueueRealtimeInsertion("voxtral ")

        XCTAssertEqual(backspaces.value, [8])
        XCTAssertFalse(
            service.debugLiveHoldBackStreamIsActive,
            "a failed restore means the keyboard path is broken: true stand-down, no conversion"
        )
        XCTAssertFalse(service.debugLiveReplacementCorrectorIsActive)

        service.enqueueRealtimeInsertion("next ")
        service.flushFinalLiveReplacementCorrections()
        XCTAssertEqual(typed.value, ["voxtral ", "next "])
        XCTAssertEqual(backspaces.value, [8])
        service.endLiveReplacementSession()
    }

    // MARK: - Session stop during an in-flight correction (codex review, 2026-07-07)

    // Production stop ordering: finishStoppedSession calls
    // flushFinalLiveReplacementCorrections() and then (same MainActor turn)
    // completeStoppedSessionCleanup() -> endLiveReplacementSession(). When a
    // deferred correction is in flight, the final flush is queued behind a
    // task that teardown immediately cancels — pre-existing on the guarded
    // path: the queued text was dropped and reported as failed pending text.
    // Teardown must drain it instead, with replacements applied.
    func testSessionStopDuringInFlightCorrectionDrainsQueuedTextInsteadOfDroppingIt() {
        let harness = makeServiceHarness(caretLocationReader: { _ in 4242 })
        harness.service.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
                ReplacementEntry(replaceWith: "chai", matches: ["tea"]),
            ]),
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        harness.service.enqueueRealtimeInsertion("voxtral ")
        XCTAssertTrue(harness.service.debugLiveReplacementCorrectionIsInFlight)
        harness.service.enqueueRealtimeInsertion("tea")

        // Production ordering: both calls in the same turn, the deferred
        // task never gets to run.
        harness.service.flushFinalLiveReplacementCorrections()
        harness.service.endLiveReplacementSession()

        XCTAssertEqual(
            harness.typed.value, ["voxtral ", "chai"],
            "text queued behind the cancelled correction must be drained with replacements applied"
        )
        XCTAssertFalse(harness.service.hasPendingInsertionText)
        XCTAssertEqual(harness.backspaces.value, [])
    }

    func testSessionStopDuringBackspacePostedCorrectionRestoresErasedText() {
        let field = FakeCaretField()
        // begin → 0, inserted-caret check → 8 (matched, backspaces post),
        // erased-caret check → 7 (mismatch, defers at .backspacePosted).
        let caretScript = Box<[Int?]>([0, 8, 7])
        let harness = makeServiceHarness(
            field: field,
            caretLocationReader: { _ in
                caretScript.value.isEmpty ? 7 : caretScript.value.removeFirst()
            }
        )
        harness.service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        harness.service.enqueueRealtimeInsertion("voxtral ")
        XCTAssertTrue(harness.service.debugLiveReplacementCorrectionIsInFlight)
        XCTAssertEqual(field.value, "", "the correction's backspaces erased the text")

        // Production stop ordering, same turn.
        harness.service.flushFinalLiveReplacementCorrections()
        harness.service.endLiveReplacementSession()

        XCTAssertEqual(
            field.value, "voxtral ",
            "teardown must restore text erased by the abandoned correction"
        )
        XCTAssertEqual(harness.backspaces.value, [8])
    }

    // MARK: - Harness

    private var voxtralDictionary: ReplacementDictionary {
        ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
        ])
    }

    private func makeServiceHarness(
        field: FakeCaretField? = nil,
        caretLocationReader: @escaping (pid_t?) -> Int?
    ) -> (
        service: TextInsertionService,
        typed: Box<[String]>,
        backspaces: Box<[Int]>
    ) {
        let service = TextInsertionService()
        let typed = Box<[String]>([])
        let backspaces = Box<[Int]>([])
        service.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.value.append(chunk)
                field?.value.append(chunk)
                return true
            },
            backspacePoster: { count in
                backspaces.value.append(count)
                if let field {
                    for _ in 0 ..< count where !field.value.isEmpty {
                        field.value.removeLast()
                    }
                }
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            caretLocationReader: caretLocationReader,
            liveReplacementSettleSleep: {}
        )
        return (service, typed, backspaces)
    }
}

@MainActor
private final class FakeCaretField {
    var value = ""
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
