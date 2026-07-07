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
}
#endif
