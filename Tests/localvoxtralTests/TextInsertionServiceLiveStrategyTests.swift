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
