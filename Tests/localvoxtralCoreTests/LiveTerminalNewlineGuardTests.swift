import XCTest
@testable import localvoxtralCore

/// #513: a Live Auto-Paste session started outside a terminal, whose focus
/// then moves to one, must still type a newline as a space there. The guard
/// alone; the session path is `LiveTerminalNewlineGuardSessionTests`.
final class LiveTerminalNewlineGuardTests: XCTestCase {
    func testCollapsesEveryNewlineOrTabRunWithItsWhitespaceToOneSpace() {
        let prepared = LiveTerminalNewlineGuard().prepare("a \n\t b\nc", targetIsTerminalLike: { true })

        XCTAssertEqual(prepared.text, "a b c")
        XCTAssertEqual(prepared.collapsedRunCount, 2)
    }

    func testKeepsPlainWhitespaceVerbatim() {
        let prepared = LiveTerminalNewlineGuard().prepare(
            "Pourquoi\u{00A0}? Oui  non\n",
            targetIsTerminalLike: { true }
        )

        XCTAssertEqual(prepared.text, "Pourquoi\u{00A0}? Oui  non")
    }

    func testLeadingRunTypesNoSpaceAtSessionStartOrAfterWhitespace() {
        let atStart = LiveTerminalNewlineGuard().prepare("\nhello ", targetIsTerminalLike: { true })
        XCTAssertEqual(atStart.text, "hello ")

        let afterSpace = atStart.stateAfterTyping.prepare("\n world", targetIsTerminalLike: { true })
        XCTAssertEqual(afterSpace.text, "world")
    }

    func testACollapsedRunEndingAChunkTypesItsSpaceWithTheNextWord() {
        let first = LiveTerminalNewlineGuard()
            .prepare("hello", targetIsTerminalLike: { true })
            .stateAfterTyping
            .prepare("\n", targetIsTerminalLike: { true })
        XCTAssertEqual(first.text, "")

        let second = first.stateAfterTyping.prepare("\n", targetIsTerminalLike: { true })
        XCTAssertEqual(second.text, "")

        let third = second.stateAfterTyping.prepare(" world", targetIsTerminalLike: { true })
        XCTAssertEqual(third.text, " world")
    }

    // Codex review of #514: a space the terminal kept must not be taken from
    // the editor focused next.
    func testTheChunkAfterFocusLeavesTheTerminalKeepsItsSpace() {
        let inTerminal = LiveTerminalNewlineGuard().prepare("hello\n", targetIsTerminalLike: { true })
        XCTAssertEqual(inTerminal.text, "hello")

        let inEditor = inTerminal.stateAfterTyping.prepare(" world", targetIsTerminalLike: { false })
        XCTAssertEqual(inEditor.text, " world")

        let editorNewline = inTerminal.stateAfterTyping.prepare("\nworld", targetIsTerminalLike: { false })
        XCTAssertEqual(editorNewline.text, "\nworld", "the editor keeps its newline")
    }

    func testLeavesTextAloneWhenTheTargetIsNotATerminal() {
        let prepared = LiveTerminalNewlineGuard().prepare("a\nb\tc", targetIsTerminalLike: { false })

        XCTAssertEqual(prepared.text, "a\nb\tc")
        XCTAssertEqual(prepared.collapsedRunCount, 0)
    }

    func testChecksTheTargetOnlyForAChunkHoldingANewlineOrTab() {
        let checks = Box(0)
        let probe = { () -> Bool in
            checks.value += 1
            return true
        }

        _ = LiveTerminalNewlineGuard().prepare("plain words ", targetIsTerminalLike: probe)
        XCTAssertEqual(checks.value, 0)
        _ = LiveTerminalNewlineGuard().prepare("two\nlines", targetIsTerminalLike: probe)
        XCTAssertEqual(checks.value, 1)
    }
}

private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
