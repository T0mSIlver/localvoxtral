import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtralCore

/// The prompt box a session's mod reads at the stop (#1406): what the reply
/// decodes to, which space the commit takes from it, and where polish sees it.
final class ClaudePromptDraftTests: XCTestCase {
    private func join(
        _ mechanism: ClaudeSessionJoinMechanism,
        sessionID: String = "s1",
        origin: ClaudeTransportOrigin = .localAuthenticated(peerUID: 501),
        agent: ClaudeHookAgent = .claude
    ) -> ClaudeSessionJoin {
        let snapshot = ClaudeSessionSnapshot(sessionID: sessionID, origin: origin, agent: agent, firstSeen: Date(timeIntervalSince1970: 0))
        return ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: 4242, bundleID: "com.mitchellh.ghostty"),
            snapshot: snapshot, windowID: 101, mechanism: mechanism
        )
    }

    private func draft(_ text: String, cursor: Int? = nil, sessionID: String = "s1") -> ClaudePromptDraft? {
        ClaudePromptDraft(
            reply: .init(sessionID: sessionID, id: "d", ok: true, text: text, cursor: cursor ?? text.utf16.count),
            sessionID: "s1"
        )
    }

    func testAReplySplitsAtTheCursorCountedInUTF16() throws {
        // The emoji is two UTF-16 units: the cursor after it is offset 6.
        let split = try XCTUnwrap(draft("fix 😀 then", cursor: 6))
        XCTAssertEqual(split.beforeCursor, "fix 😀")
        XCTAssertEqual(split.afterCursor, " then")
    }

    func testAReplyThatIsNotAUsableDraftDecodesToNil() {
        XCTAssertNil(ClaudePromptDraft(
            reply: .init(sessionID: "s1", id: "d", ok: false, reason: "unknown_kind"), sessionID: "s1"
        ), "a mod older than draft")
        XCTAssertNil(draft("text", sessionID: "s2"), "another session's box")
        XCTAssertNil(draft("text", cursor: 5), "a cursor past the end")
        XCTAssertNil(draft("text", cursor: -1))
        XCTAssertNil(draft("😀", cursor: 1), "a cursor between the halves of a pair")
        XCTAssertNil(ClaudePromptDraft(reply: .init(sessionID: "s1", id: "d", ok: true), sessionID: "s1"))
    }

    /// #802: two dictations into one prompt must not glue, and a fresh
    /// prompt must not get a space that turns `/compact` into text.
    func testTheCommitTakesASpaceOnlyAfterACharacterThatIsNotWhitespace() throws {
        let cases: [(String, Int?, Bool)] = [
            ("", nil, false),
            ("we were doing.", nil, true),
            ("fix the ", nil, false),
            ("first line\n", nil, false),
            ("rest of the prompt", 0, false),
            ("run tests and then", 14, false),
            ("run tests and then", 9, true),
        ]
        for (text, cursor, expected) in cases {
            let box = try XCTUnwrap(draft(text, cursor: cursor))
            XCTAssertEqual(box.commitNeedsLeadingSpace, expected, "\(text.debugDescription) at \(cursor ?? -1)")
        }
    }

    /// Claude Desktop draws its own prompt box, which the mod reads as ""
    /// whatever it holds: an empty answer there must leave the space to the
    /// old evidence, while a terminal's empty answer is the truth.
    func testAnEmptyDesktopBoxDoesNotDecideTheSpace() throws {
        let empty = try XCTUnwrap(draft(""))
        let typed = try XCTUnwrap(draft("and"))
        XCTAssertFalse(empty.decidesLeadingSpace(for: join(.desktopSession)))
        XCTAssertTrue(typed.decidesLeadingSpace(for: join(.desktopSession)))
        XCTAssertTrue(empty.decidesLeadingSpace(for: join(.ttyDevice)))
        XCTAssertFalse(typed.decidesLeadingSpace(for: join(.ttyDevice, sessionID: "s2")))
    }

    func testOnlyAnExactlyJoinedClaudeSessionIsAsked() {
        for mechanism in [ClaudeSessionJoinMechanism.ttyDevice, .herdrPane, .cmuxSurface, .desktopSession] {
            XCTAssertTrue(ClaudePromptDraft.isReadable(through: join(mechanism)), "\(mechanism)")
        }
        XCTAssertFalse(ClaudePromptDraft.isReadable(through: join(.browserTab)))
        XCTAssertFalse(ClaudePromptDraft.isReadable(through: join(.ttyDevice, origin: .remote(channel: "h"))))
        XCTAssertFalse(ClaudePromptDraft.isReadable(through: join(.ttyDevice, agent: .opencode)))
    }

    /// A session on an enrolled host is filled through its mod by the arms
    /// that name it exactly (#1412); a local mechanism on a remote origin,
    /// Claude Desktop and a browser tab are not.
    func testTheModFillsARemoteSessionOnlyThroughTheRemoteArms() {
        let remote = ClaudeTransportOrigin.remote(channel: "ssh:h1")
        for mechanism in [
            ClaudeSessionJoinMechanism.remoteHerdrPane, .federatedHerdrPane, .remoteSSHConnection, .remoteLocalTTY,
            .cmuxSurface,
        ] {
            XCTAssertTrue(ClaudePromptDraft.fillsPrompt(through: join(mechanism, origin: remote)), "\(mechanism)")
            XCTAssertTrue(ClaudePromptDraft.isReadable(through: join(mechanism, origin: remote)), "\(mechanism)")
        }
        for mechanism in [ClaudeSessionJoinMechanism.ttyDevice, .herdrPane, .desktopSession, .browserTab] {
            XCTAssertFalse(ClaudePromptDraft.fillsPrompt(through: join(mechanism, origin: remote)), "\(mechanism)")
        }
        XCTAssertFalse(ClaudePromptDraft.fillsPrompt(through: join(.remoteHerdrPane)), "a local origin")
        XCTAssertFalse(ClaudePromptDraft.fillsPrompt(through: join(.desktopSession)))
    }

    func testTheDraftLeadsTheSessionBlockOneLinePerSideOfTheCursor() throws {
        var snapshot = join(.ttyDevice).snapshot
        snapshot.latestPriorUserPrompt = "add the band"
        let box = try XCTUnwrap(draft("fix the flaky\ntest and", cursor: 16))

        let text = ClaudeSessionContextText.text(for: snapshot, draft: box)

        XCTAssertEqual(text, """
            \(ClaudePromptDraft.beforeCursorLabel)fix the flaky / te
            \(ClaudePromptDraft.afterCursorLabel)st and

            \(ClaudeSessionContextText.priorPromptLabel)add the band
            """)
        let other = ClaudePromptDraft(sessionID: "s2", beforeCursor: "x", afterCursor: "")
        XCTAssertEqual(
            ClaudeSessionContextText.text(for: snapshot, draft: other),
            ClaudeSessionContextText.text(for: snapshot),
            "another session's draft never reaches this block"
        )
    }
}

/// The hub's side: one `draft` request to the named session's mod.
final class ClaudeModChannelDraftTests: XCTestCase {
    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        func append(_ line: Data) { lock.withLock { lines.append(line) } }
        var all: [Data] { lock.withLock { lines } }
    }

    /// A hub whose reply timeout fires at once, or only once cancelled: the
    /// reply, written back as the request goes out, cancels it.
    private func attached(
        answer: ClaudeModChannelWire.Reply?,
        timesOut: Bool = false
    ) -> (ClaudeModChannelHub, Written) {
        let written = Written()
        let sleep: @Sendable (Duration) async -> Void = timesOut
            ? { @Sendable _ in }
            : { @Sendable _ in try? await Task.sleep(for: .seconds(3600)) }
        let hub = ClaudeModChannelHub(sleep: sleep, makeID: { "id-1" })
        _ = hub.attach(sessionID: "s1", channel: .init(
            write: { line in
                written.append(line)
                if let answer { hub.deliver(answer) }
                return true
            },
            close: {}
        ))
        return (hub, written)
    }

    func testTheDraftComesBackFromTheNamedSessionsMod() async throws {
        let (hub, written) = attached(
            answer: .init(sessionID: "s1", id: "id-1", ok: true, text: "fix it", cursor: 3)
        )

        let box = await hub.promptDraft(of: "s1", timeout: .seconds(60))

        XCTAssertEqual(box, ClaudePromptDraft(sessionID: "s1", beforeCursor: "fix", afterCursor: " it"))
        let sent = try XCTUnwrap(written.all.first)
        XCTAssertEqual(
            ClaudeModChannelWire.decode(ClaudeModChannelWire.Message.self, from: sent.dropLast())?.kind,
            .draft
        )
    }

    func testAnOlderModOrNoModGivesNoDraft() async {
        let (older, _) = attached(
            answer: .init(sessionID: "s1", id: "id-1", ok: false, reason: "unknown_kind")
        )
        let none = await older.promptDraft(of: "s1", timeout: .seconds(60))
        XCTAssertNil(none)

        let (hub, written) = attached(answer: nil)
        let other = await hub.promptDraft(of: "s2", timeout: .seconds(60))
        XCTAssertNil(other)
        XCTAssertTrue(written.all.isEmpty, "a session with no mod is not asked")
    }

    func testAModThatNeverAnswersGivesNoDraft() async {
        let (hub, _) = attached(answer: nil, timesOut: true)
        let box = await hub.promptDraft(of: "s1", timeout: .seconds(1))
        XCTAssertNil(box)
    }

    func testTheReplyCarriesTheCursorOnTheWire() throws {
        let line = try XCTUnwrap(ClaudeModChannelWire.encodeLine(
            ClaudeModChannelWire.Reply(sessionID: "s1", id: "d", ok: true, text: "ab", cursor: 1)
        ))
        XCTAssertEqual(
            String(decoding: line, as: UTF8.self),
            #"{"cursor":1,"id":"d","mod_reply":1,"ok":true,"session_id":"s1","text":"ab"}"# + "\n"
        )
    }
}
