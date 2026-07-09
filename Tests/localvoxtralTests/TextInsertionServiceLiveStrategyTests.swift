import XCTest
@testable import localvoxtral

#if DEBUG
/// Live Auto-Paste replacement behavior. Every target — terminal or regular
/// editor — applies dictionary replacements BEFORE typing, through the
/// hold-back stream. The post-typing backspace corrector was removed: it read
/// the target's caret synchronously right after posting keystrokes the app had
/// not processed yet, so corrections deferred and were dropped at session stop
/// — zero successful corrections in the field (logs, 2026-07-08). No target
/// ever receives a backspace event; there is no backspace hook to assert on.
@MainActor
final class TextInsertionServiceLiveStrategyTests: XCTestCase {
    // Field repro (owner's Mac, 2026-07-06): dictating into a terminal
    // (Ghostty, Claude Code TUI) with one replacement entry. Replacements are
    // applied before typing, so the whole matched word is corrected with no
    // backspaces.
    func testTerminalLikeSessionAppliesReplacementBeforeTyping() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)

        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("vox")
        service.enqueueRealtimeInsertion("tral ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "localvoxtral ")
        service.endLiveReplacementSession()
    }

    func testTerminalLikeSessionSanitizesNewlinesInReleasedText() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("run\n\nthe tests ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "run the tests ")
    }

    func testTerminalLikeSessionSanitizesNewlinesInFlushedRemainder() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "X", matches: ["run something"]),
            ]),
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        // "run so" stays a live prefix of the rule, so everything is held back
        // and the newline is still held at session stop — it must be sanitized
        // on the remainder flush.
        service.enqueueRealtimeInsertion("run\nso")
        XCTAssertEqual(typed.value, [])
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "run so")
    }

    func testTerminalLikeSessionWithoutDictionaryStillSanitizesNewlines() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: nil,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )
        XCTAssertTrue(
            service.debugLiveHoldBackStreamIsActive,
            "terminals arm the stream even with no rules so newline sanitization runs"
        )

        service.enqueueRealtimeInsertion("git status\n")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "git status ")
    }

    func testNonTerminalSessionAppliesReplacementBeforeTyping() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )
        XCTAssertTrue(service.debugLiveHoldBackStreamIsActive)

        service.enqueueRealtimeInsertion("vox")
        service.enqueueRealtimeInsertion("tral ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(typed.value.joined(), "localvoxtral ")
    }

    func testNonTerminalSessionPreservesNewlines() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        service.enqueueRealtimeInsertion("voxtral\nrocks ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(
            typed.value.joined(), "localvoxtral\nrocks ",
            "a regular editor must keep the user's newlines"
        )
    }

    // MARK: - The regression: final-word-only replacement at stop

    // The exact field failure (2026-07-08): a short dictation whose ONLY
    // replacement is the final word, with no trailing whitespace. The old
    // guarded corrector deferred this correction waiting for the caret to
    // settle and dropped it when the session stopped — nothing was replaced,
    // in every app. The hold-back stream applies it on the remainder flush.
    func testFinalWordOnlyReplacementIsAppliedAtStopNonTerminal() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        // Streams as a partial word with NO trailing boundary, then stop.
        service.enqueueRealtimeInsertion("vox")
        service.enqueueRealtimeInsertion("tral")
        XCTAssertEqual(typed.value, [], "the trailing partial word stays held until stop")

        service.flushFinalLiveReplacementCorrections()
        XCTAssertEqual(
            typed.value.joined(), "localvoxtral",
            "the final word's replacement must be applied on stop, not dropped"
        )
        service.endLiveReplacementSession()
    }

    // Codex-required invariant: after stop, the text emitted for the whole
    // session equals the dictionary applied to the full raw transcript. Proves
    // no fresh-empty-stream teardown bug and no dropped tail.
    func testStopEmittedTextEqualsDictionaryAppliedToFullRawText() {
        let rawDeltas = ["je ", "porte ", "une ", "vox", "tral ", "et ", "un ", "voxtral"]
        let expected = "je porte une localvoxtral et un localvoxtral"

        for terminalLike in [false, true] {
            let typed = Box<[String]>([])
            let service = makeService(capturing: typed)
            service.beginLiveReplacementSession(
                dictionary: voxtralDictionary,
                preferredAppPID: nil,
                isTerminalLikeTarget: terminalLike
            )
            for delta in rawDeltas {
                service.enqueueRealtimeInsertion(delta)
            }
            service.flushFinalLiveReplacementCorrections()
            XCTAssertEqual(
                typed.value.joined(), expected,
                "emitted text must equal the dictionary applied to the full raw text (terminalLike=\(terminalLike))"
            )
            service.endLiveReplacementSession()
        }
    }

    // Teardown safety: even if a caller reaches endLiveReplacementSession
    // without an explicit final flush first, the held tail is not dropped.
    func testEndSessionFlushesHeldTailWithoutExplicitFinalFlush() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )

        service.enqueueRealtimeInsertion("voxtral")
        XCTAssertEqual(typed.value, [])

        service.endLiveReplacementSession()
        XCTAssertEqual(
            typed.value.joined(), "localvoxtral",
            "teardown must flush the held tail rather than drop it"
        )
    }

    func testNonTerminalNoRulesTypesDirectlyWithoutHoldBack() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: []),
            preferredAppPID: nil,
            isTerminalLikeTarget: false
        )
        XCTAssertFalse(
            service.debugLiveHoldBackStreamIsActive,
            "a non-terminal target with no rules must type directly (zero hold-back delay)"
        )

        // No hold-back: each partial word is typed immediately, unheld.
        service.enqueueRealtimeInsertion("hello")
        XCTAssertEqual(typed.value, ["hello"])
        service.enqueueRealtimeInsertion(" world")
        XCTAssertEqual(typed.value.joined(), "hello world")
        service.endLiveReplacementSession()
    }

    func testHeldTextIsTypedOnFinalFlush() {
        let typed = Box<[String]>([])
        let service = makeService(capturing: typed)
        service.beginLiveReplacementSession(
            dictionary: voxtralDictionary,
            preferredAppPID: nil,
            isTerminalLikeTarget: true
        )

        service.enqueueRealtimeInsertion("voxtral")
        XCTAssertEqual(typed.value, [], "partial word must stay held")

        service.flushFinalLiveReplacementCorrections()
        XCTAssertEqual(typed.value, ["localvoxtral"])
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
            accessibilityInserter: { _, _ in false }
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

    // MARK: - Harness

    private var voxtralDictionary: ReplacementDictionary {
        ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "localvoxtral", matches: ["voxtral"]),
        ])
    }

    private func makeService(capturing typed: Box<[String]>) -> TextInsertionService {
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.value.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )
        return service
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
#endif
