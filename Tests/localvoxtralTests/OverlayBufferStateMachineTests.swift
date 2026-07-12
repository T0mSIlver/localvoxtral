import CoreGraphics
import XCTest
@testable import localvoxtral

@MainActor
final class OverlayBufferStateMachineTests: XCTestCase {
    func testSecureInputMarkerSetsOnlyWhileBufferingAndResetsOnNewSession() {
        var machine = OverlayBufferStateMachine()
        let anchor = OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 80, height: 24),
            source: .windowCenter
        )

        machine.setSecureInputWarning()
        XCTAssertNil(machine.snapshot, "no session, no marker")

        machine.startSession(anchor: anchor)
        machine.setSecureInputWarning()
        XCTAssertEqual(machine.snapshot?.secureInputActive, true)
        XCTAssertNil(
            machine.snapshot?.errorMessage,
            "the marker lives in the phase title, not a warning line (owner feedback on #90)"
        )

        machine.beginFinalizing(anchor: nil)
        XCTAssertEqual(
            machine.snapshot?.secureInputActive, true,
            "finalizing keeps the marker; commitFailed owns the surface next"
        )

        machine.reset()
        machine.startSession(anchor: anchor)
        XCTAssertEqual(machine.snapshot?.secureInputActive, false, "a new session starts clean")

        machine.beginFinalizing(anchor: nil)
        machine.setSecureInputWarning()
        XCTAssertEqual(
            machine.snapshot?.secureInputActive, false,
            "too late — the warning is sampled while buffering only"
        )
    }

    func testStateMachine_happyPathTransitionsToIdleAfterReset() {
        var machine = OverlayBufferStateMachine()
        let anchor = OverlayAnchor(targetRect: CGRect(x: 10, y: 20, width: 100, height: 40), source: .windowCenter)

        machine.startSession(anchor: anchor)
        XCTAssertEqual(machine.phase, .buffering)

        machine.updateBuffer(text: "hello world", anchor: nil)
        XCTAssertEqual(machine.bufferText, "hello world")

        machine.beginFinalizing(anchor: nil)
        XCTAssertEqual(machine.phase, .finalizing)

        machine.reset()
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.snapshot)
        XCTAssertEqual(machine.bufferText, "")
    }

    func testStateMachine_commitFailureEntersCommitFailedAndRetainsBuffer() {
        var machine = OverlayBufferStateMachine()
        let anchor = OverlayAnchor(targetRect: CGRect(x: 0, y: 0, width: 40, height: 20), source: .mouseLocation)

        machine.startSession(anchor: anchor)
        machine.updateBuffer(text: "buffered text", anchor: nil)
        machine.beginFinalizing(anchor: nil)
        machine.commitFailed(error: "insert failed", anchor: anchor)

        XCTAssertEqual(machine.phase, .commitFailed)
        XCTAssertEqual(machine.bufferText, "buffered text")
        XCTAssertEqual(machine.errorMessage, "insert failed")
        XCTAssertEqual(machine.snapshot?.anchor, anchor)
    }

    func testStateMachine_resetReturnsToIdleFromAnyState() {
        var machine = OverlayBufferStateMachine()
        let anchor = OverlayAnchor(targetRect: CGRect(x: 5, y: 5, width: 80, height: 20), source: .windowCenter)

        machine.startSession(anchor: anchor)
        machine.updateBuffer(text: "hello", anchor: nil)
        machine.beginFinalizing(anchor: nil)
        machine.reset()

        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.bufferText, "")
        XCTAssertNil(machine.errorMessage)
        XCTAssertNil(machine.anchor)
    }

    func testPolishedFlagSetsInFinalizingAndResetsOnNewSession() {
        var machine = OverlayBufferStateMachine()
        let anchor = OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 80, height: 24),
            source: .windowCenter
        )

        machine.setPolished(true)
        XCTAssertNil(machine.snapshot, "no session, no flag")

        machine.startSession(anchor: anchor)
        XCTAssertEqual(machine.snapshot?.polished, false, "a fresh session is unpolished")

        machine.beginFinalizing(anchor: nil)
        machine.setPolished(true)
        XCTAssertEqual(
            machine.snapshot?.polished, true,
            "the badge rides the finalizing snapshot while the polished text is held"
        )

        machine.setPolished(false)
        XCTAssertEqual(machine.snapshot?.polished, false, "a no-op polish clears the flag")

        machine.setPolished(true)
        machine.reset()
        machine.startSession(anchor: anchor)
        XCTAssertEqual(
            machine.snapshot?.polished, false,
            "reset + a new session must not carry a stale badge"
        )
    }

    func testOverlayAssembler_partialAndFinalMergeWithoutDuplication() {
        let merged = OverlayBufferTextAssembler.displayText(
            committedText: "hello world",
            pendingText: "world again",
            fallbackPendingText: ""
        )

        XCTAssertEqual(merged, "hello world again")
    }

    func testOverlayAssembler_fallbackPendingUsedWhenPrimaryPendingEmpty() {
        let merged = OverlayBufferTextAssembler.displayText(
            committedText: "hello",
            pendingText: "",
            fallbackPendingText: " there"
        )

        XCTAssertEqual(merged, "hello there")
    }

    func testOverlayAssembler_commitTextPreservesNewlines() {
        let commitText = OverlayBufferTextAssembler.commitText(
            committedText: "line one\nline two",
            pendingText: "",
            fallbackPendingText: "\nline three"
        )

        XCTAssertEqual(commitText, "line one\nline two\nline three")
    }

    func testOverlayAssembler_insertionTextTrimsEdgesOnly() {
        let commitText = OverlayBufferTextAssembler.insertionText(from: "  hello world  ")
        XCTAssertEqual(commitText, "hello world")
    }
}
