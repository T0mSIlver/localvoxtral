import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// The AppleScript focuser against fake terminals: no Apple event is sent.
@MainActor
final class TerminalSessionPaneFocuserTests: XCTestCase {
    private static let ghostty = TerminalScreenAllowlist.ghosttyBundleID
    private static let iterm = TerminalScreenAllowlist.iterm2BundleID
    private static let terminal = TerminalScreenAllowlist.appleTerminalBundleID
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    func testOnlyALettersAndDigitsDevicePathReachesAScript() {
        XCTAssertTrue(TerminalSessionPaneFocuser.isScriptSafeTTY("/dev/ttys004"))
        for unsafe in ["/dev/ttys004\" & quit", "/dev/tty s1", "/dev/tty", "ttys004", "/dev/ttys00\\4", "/dev/ttys/../x"] {
            XCTAssertFalse(TerminalSessionPaneFocuser.isScriptSafeTTY(unsafe), unsafe)
            XCTAssertNil(TerminalSessionPaneFocuser.focusScriptSource(bundleID: Self.ghostty, tty: unsafe), unsafe)
        }
    }

    func testEachTerminalGetsItsOwnScriptAndNoOtherAppDoes() throws {
        let ghostty = try XCTUnwrap(TerminalSessionPaneFocuser.focusScriptSource(bundleID: Self.ghostty, tty: "/dev/ttys004"))
        XCTAssertTrue(ghostty.contains("tell application id \"\(Self.ghostty)\""))
        XCTAssertTrue(ghostty.contains("focus t"))
        let iterm = try XCTUnwrap(TerminalSessionPaneFocuser.focusScriptSource(bundleID: Self.iterm, tty: "/dev/ttys004"))
        XCTAssertTrue(iterm.contains("select s"))
        let terminal = try XCTUnwrap(TerminalSessionPaneFocuser.focusScriptSource(bundleID: Self.terminal, tty: "/dev/ttys004"))
        XCTAssertTrue(terminal.contains("set selected tab of w to t"))
        for source in [ghostty, iterm, terminal] {
            XCTAssertTrue(source.contains("\"/dev/ttys004\""))
            XCTAssertFalse(source.contains("keystroke"), "focusing never types")
        }
        XCTAssertNil(TerminalSessionPaneFocuser.focusScriptSource(bundleID: "com.example.editor", tty: "/dev/ttys004"))
    }

    func testTheSessionsTerminalIsAskedFirstAndOnlyRunningOnesAtAll() async {
        let fake = FakeTerminals(running: [Self.ghostty, Self.iterm], holding: Self.iterm)
        let outcome = await fake.focuser.focusPane(of: session(termProgram: "iTerm.app"))

        XCTAssertEqual(outcome, .focused(bundleID: Self.iterm))
        XCTAssertEqual(fake.asked, [Self.iterm])
        XCTAssertEqual(fake.activated, [Self.iterm])
    }

    func testAPaneTheReadBackDoesNotShowIsUnverified() async {
        let fake = FakeTerminals(running: [Self.ghostty], holding: Self.ghostty, readBack: "/dev/ttys999")
        let outcome = await fake.focuser.focusPane(of: session(termProgram: nil))

        XCTAssertEqual(outcome, .unverified(bundleID: Self.ghostty))
    }

    func testATerminalThatFailsOrLacksThePaneHandsOverToTheNext() async {
        let fake = FakeTerminals(
            running: [Self.ghostty, Self.iterm, Self.terminal],
            holding: Self.terminal,
            failing: [Self.ghostty]
        )
        let outcome = await fake.focuser.focusPane(of: session(termProgram: "ghostty"))

        XCTAssertEqual(outcome, .focused(bundleID: Self.terminal))
        XCTAssertEqual(fake.asked, [Self.ghostty, Self.iterm, Self.terminal])
        XCTAssertEqual(fake.activated, [Self.terminal])
    }

    func testNoTerminalHoldingTheTTYActivatesNothing() async {
        let fake = FakeTerminals(running: [Self.ghostty, Self.iterm], holding: nil)
        let outcome = await fake.focuser.focusPane(of: session(termProgram: nil))

        XCTAssertEqual(outcome, .paneNotFound)
        XCTAssertEqual(fake.activated, [])
    }

    func testAGoToCancelledWhileTheTerminalAnswersActivatesNothing() async {
        let fake = FakeTerminals(running: [Self.ghostty], holding: Self.ghostty, cancelsWhileAnswering: true)
        let outcome = await Task { await fake.focuser.focusPane(of: session(termProgram: "ghostty")) }.value

        XCTAssertEqual(outcome, .paneNotFound)
        XCTAssertEqual(fake.asked, [Self.ghostty])
        XCTAssertEqual(fake.activated, [], "a new dictation keeps its frontmost app")
    }

    func testAHerdrPaneAsksNoTerminal() async {
        let fake = FakeTerminals(running: [Self.ghostty], holding: Self.ghostty)
        var herdr = session(termProgram: "ghostty")
        herdr.process?.herdrPaneID = "p1"
        let outcome = await fake.focuser.focusPane(of: herdr)

        XCTAssertEqual(outcome, .unsupported(.herdr))
        XCTAssertEqual(fake.asked, [])
    }

    // MARK: - Helpers

    private func session(termProgram: String?) -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: "s", origin: local, firstSeen: Date(timeIntervalSince1970: 0))
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: "/r/payments", origin: local)
        snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys004", termProgram: termProgram)
        return snapshot
    }

    /// Terminals that answer the focus script by bundle ID: `holding` has
    /// the pane, `failing` raise an AppleScript error.
    @MainActor
    private final class FakeTerminals {
        private(set) var asked: [String] = []
        private(set) var activated: [String] = []
        private(set) var focuser: TerminalSessionPaneFocuser!

        init(
            running: Set<String>,
            holding: String?,
            failing: Set<String> = [],
            readBack: String = "/dev/ttys004",
            cancelsWhileAnswering: Bool = false
        ) {
            focuser = TerminalSessionPaneFocuser(
                runningTerminalBundleIDs: { running },
                runScript: { [unowned self] source in
                    let bundleID = [TerminalSessionPaneFocuserTests.ghostty, TerminalSessionPaneFocuserTests.iterm, TerminalSessionPaneFocuserTests.terminal].first { source.contains("\"\($0)\"") } ?? ""
                    self.asked.append(bundleID)
                    if cancelsWhileAnswering { withUnsafeCurrentTask { $0?.cancel() } }
                    if failing.contains(bundleID) { return .failure(code: -1743) }
                    return .success(bundleID == holding ? TerminalSessionPaneFocuser.focusedReply : "")
                },
                activate: { [unowned self] bundleID in
                    self.activated.append(bundleID)
                    return true
                },
                focusedTTY: { _ in readBack }
            )
        }
    }
}
