import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// The terminal read-back that lets a Return into a joined pane go: the
/// focused tty must be the session's, and the registry must still resolve
/// that tty to this session.
@MainActor
final class TerminalSessionPaneFocuserTests: XCTestCase {
    private func session(tty: String = "/dev/ttys002") -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(
            sessionID: "ses_a", origin: .localAuthenticated(peerUID: 501), firstSeen: Date(timeIntervalSince1970: 0)
        )
        snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: tty)
        return snapshot
    }

    private func focuser(focused: String?, resolvesTo: String?) -> TerminalSessionPaneFocuser {
        TerminalSessionPaneFocuser(
            focusedTTY: { _ in focused },
            frontmostBundleID: { TerminalScreenAllowlist.ghosttyBundleID },
            sessionOnTTY: { _ in resolvesTo }
        )
    }

    func testThePaneShowsTheSessionWhenTheTTYAndTheRegistryAgree() async {
        let shows = await focuser(focused: "/dev/ttys002", resolvesTo: "ses_a")
            .focusedPaneShows(session(), bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        XCTAssertTrue(shows)
    }

    func testAnotherTabIsNotShown() async {
        let shows = await focuser(focused: "/dev/ttys009", resolvesTo: "ses_a")
            .focusedPaneShows(session(), bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        XCTAssertFalse(shows)
    }

    /// One opencode TUI hosts sessions A and B on one tty and shows B: the
    /// tty reads back as A's, but the registry resolves it to B.
    func testAnotherSessionShownOnTheSameTTYIsNotShown() async {
        let other = await focuser(focused: "/dev/ttys002", resolvesTo: "ses_b")
            .focusedPaneShows(session(), bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        XCTAssertFalse(other)
        let none = await focuser(focused: "/dev/ttys002", resolvesTo: nil)
            .focusedPaneShows(session(), bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        XCTAssertFalse(none, "ambiguous, stale or unknown")
    }
}
