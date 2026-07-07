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

        // Simulates the periodic retry task's call.
        service.flushPendingRealtimeInsertion()

        XCTAssertEqual(
            typed.value, ["localvoxtral "],
            "retried release must be typed exactly once, never re-ingested"
        )
        XCTAssertFalse(service.hasPendingInsertionText)
        service.endLiveReplacementSession()
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
