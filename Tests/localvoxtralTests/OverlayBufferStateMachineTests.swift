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

        machine.startSession(anchor: anchor, claudeJoin: .hidden)
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
        machine.startSession(anchor: anchor, claudeJoin: .hidden)
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

        machine.startSession(anchor: anchor, claudeJoin: .hidden)
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

        machine.startSession(anchor: anchor, claudeJoin: .hidden)
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

        machine.startSession(anchor: anchor, claudeJoin: .hidden)
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

        machine.startSession(anchor: anchor, claudeJoin: .hidden)
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
        machine.startSession(anchor: anchor, claudeJoin: .hidden)
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

    // MARK: - Claude join badge

    // The badge arrives WITH the session and must ride every later snapshot:
    // the join it describes is resolved exactly once, so nothing downstream can
    // change what it should say.
    func testClaudeJoinBadgeRidesTheWholeSession() {
        var machine = OverlayBufferStateMachine()
        let anchor = OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 80, height: 24),
            source: .windowCenter
        )

        machine.startSession(anchor: anchor, claudeJoin: .joined(label: "localvoxtral"))
        XCTAssertEqual(machine.snapshot?.claudeJoin, .joined(label: "localvoxtral"))

        machine.updateBuffer(text: "hello", anchor: nil)
        machine.beginFinalizing(anchor: nil)
        XCTAssertEqual(
            machine.snapshot?.claudeJoin, .joined(label: "localvoxtral"),
            "the badge annotates the whole session, including the polished hold"
        )

        machine.commitFailed(error: "nope", anchor: nil)
        XCTAssertEqual(
            machine.snapshot?.claudeJoin, .joined(label: "localvoxtral"),
            "a failed insert says nothing about what the dictation was grounded in"
        )
    }

    // The badge cannot outlive the dictation it describes, because starting a
    // session ASSIGNS it rather than merely clearing it: there is no ordering
    // in which a stale `.joined` can reach the next session's panel, and no
    // setter that could put one there later.
    func testEachSessionsBadgeIsItsOwn() {
        var machine = OverlayBufferStateMachine()
        let anchor = OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 80, height: 24),
            source: .windowCenter
        )

        machine.startSession(anchor: anchor, claudeJoin: .joined(label: "localvoxtral"))
        machine.reset()
        XCTAssertEqual(machine.claudeJoin, .hidden, "reset holds nothing to render later")

        machine.startSession(anchor: anchor, claudeJoin: .unjoined)
        XCTAssertEqual(machine.snapshot?.claudeJoin, .unjoined)

        // Even without an intervening reset: a second startSession is refused
        // outright (guarded on `.idle`), so it cannot half-apply a new badge to
        // a running session either.
        machine.startSession(anchor: anchor, claudeJoin: .joined(label: "sneaky"))
        XCTAssertEqual(
            machine.snapshot?.claudeJoin, .unjoined,
            "the running session keeps the badge it was started with"
        )
    }
}
