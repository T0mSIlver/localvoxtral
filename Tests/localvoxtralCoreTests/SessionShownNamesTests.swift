import ClaudeContextWire
import Foundation
@testable import localvoxtralCore
import XCTest

/// #1013: what sessions are called, over snapshots shaped like the owner's
/// live sessions of 2026-09-28 (Claude Desktop over ssh to the dev box, CLI
/// worktrees there, two agents in the Mac checkout).
final class SessionShownNamesTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let devBox = ClaudeTransportOrigin.remote(channel: "sandbox-vpn")

    // MARK: - Recorded sessions, before and after

    func testRecordedSessionsKeepSpeakableNamesAndStayApart() {
        let desktop = remoteSession(
            "desktop", cwd: "/home/dev/work/localvoxtral/.claude/worktrees/zealous-chaplygin-aa1a02",
            project: "localvoxtral", desktopID: "local_7e66212b-6bd0-4eb5-b551-068eda22432a", seen: 0
        )
        let worktree = remoteSession(
            "worktree", cwd: "/home/dev/work/localvoxtral/.claude/worktrees/ci-speed-optimizations-7ffef0",
            project: "localvoxtral", seen: 1
        )
        let devCheckout = remoteSession("dev-checkout", cwd: "/home/dev/work/localvoxtral", project: "localvoxtral", seen: 2)
        let macClaude = localSession("mac-claude", cwd: "/Users/tom/Desktop/projects/supervoxtral", tty: "/dev/ttys001", seen: 3)
        var macCodex = localSession("mac-codex", cwd: "/Users/tom/Desktop/projects/supervoxtral", tty: "/dev/ttys002", seen: 4)
        macCodex.agent = .codex
        let macClaudeAgain = localSession(
            "mac-claude-2", cwd: "/Users/tom/Desktop/projects/supervoxtral", tty: "/dev/ttys003", seen: 5
        )
        let branch = localSession("branch", cwd: "/Users/tom/work/wt-17", tty: "/dev/ttys004", seen: 6)
        let titles = ["desktop": "Better session names than the worktree folder (#1013)"]
        let candidates = [
            candidate(desktop, title: titles["desktop"]),
            candidate(worktree),
            candidate(devCheckout),
            candidate(macClaude, root: .root("/Users/tom/Desktop/projects/supervoxtral")),
            candidate(macCodex, root: .root("/Users/tom/Desktop/projects/supervoxtral")),
            candidate(macClaudeAgain, root: .root("/Users/tom/Desktop/projects/supervoxtral")),
            candidate(branch, root: .root("/Users/tom/work/wt-17", mainCheckout: "/Users/tom/work/billing"), branch: "fix/overlay-names"),
        ]

        // Before: the git root's folder, `SessionDefaultNames.primary`.
        XCTAssertEqual(candidates.map(\.names.primary), [
            "zealous-chaplygin-aa1a02", "ci-speed-optimizations-7ffef0", "localvoxtral",
            "supervoxtral", "supervoxtral", "supervoxtral", "wt-17",
        ])
        XCTAssertEqual(SessionShownNames.of(candidates), [
            "desktop": "Better session names than the worktree folder (#1013)",
            "worktree": "ci-speed-optimizations",
            "dev-checkout": "localvoxtral",
            "mac-claude": "supervoxtral · 1",
            "mac-codex": "supervoxtral · Codex",
            "mac-claude-2": "supervoxtral · 2",
            "branch": "overlay-names",
        ])

        let spoken: [(String, String?)] = [
            ("better session names", "desktop"),
            ("zealous chaplygin", "desktop"),
            ("zealous chaplygin aa1a02", "desktop"),
            ("ci speed optimizations", "worktree"),
            ("supervoxtral one", "mac-claude"),
            ("supervoxtral codex", "mac-codex"),
            ("supervoxtral two", "mac-claude-2"),
            ("supervoxtral 2", "mac-claude-2"),
            ("overlay names", "branch"),
            ("wt 17", "branch"),
            ("billing", "branch"),
            // Three panes share it: which one is meant is unknown.
            ("supervoxtral", nil),
            // One title word is too little to be a name.
            ("better", nil),
        ]
        for (name, expected) in spoken {
            XCTAssertEqual(resolvedID(name, candidates), expected, name)
        }
        XCTAssertEqual(
            SessionNameResolver.resolve(spokenName: "localvoxtral", candidates: candidates),
            .resolved(devCheckout),
            "the checkout's own folder wins over the worktrees' repository"
        )
    }

    // MARK: - The rule

    func testANicknameIsShownAndKeepsTheBareName() {
        var named = candidate(localSession("late", cwd: "/r/payments", tty: "/dev/ttys002", seen: 9))
        named.nickname = "payments"
        let first = candidate(localSession("first", cwd: "/r/payments", tty: "/dev/ttys001", seen: 0))
        XCTAssertEqual(SessionShownNames.of([first, named]), ["late": "payments", "first": "payments · 1"])
    }

    func testATitleNeverBeatsAFolderName() {
        let folder = candidate(localSession("folder", cwd: "/r/payments", tty: "/dev/ttys001", seen: 0))
        let titled = candidate(localSession("titled", cwd: "/r/other", tty: "/dev/ttys002", seen: 1), title: "Payments")
        XCTAssertEqual(resolvedID("payments", [titled, folder]), "folder")
        XCTAssertEqual(resolvedID("payments", [titled]), "titled")
    }

    /// A name ending in a negative number is ordinary text, not a suffix to
    /// say as a word (#1034).
    func testANameEndingInANegativeNumberHasNoNumberWord() {
        XCTAssertEqual(SessionShownNames.spokenForms("rollback · -1"), ["rollback · -1"])
        let titled = candidate(localSession("titled", cwd: "/r/other", tty: "/dev/ttys001", seen: 0), title: "Rollback · -1")
        XCTAssertEqual(resolvedID("rollback 1", [titled]), "titled")
    }

    /// The name the user reads is the one that answers, suffix included.
    func testATitledPaneLeavesTheShownSuffixesToTheOthers() {
        let titled = candidate(localSession("titled", cwd: "/r/payments", tty: "/dev/ttys001", seen: 0), title: "Fix refunds")
        let second = candidate(localSession("second", cwd: "/r/payments", tty: "/dev/ttys002", seen: 1))
        let third = candidate(localSession("third", cwd: "/r/payments", tty: "/dev/ttys003", seen: 2))
        let three = [titled, second, third]
        XCTAssertEqual(SessionShownNames.of(three), [
            "titled": "Fix refunds", "second": "payments · 1", "third": "payments · 2",
        ])
        XCTAssertEqual(resolvedID("payments one", three), "second")
        XCTAssertEqual(resolvedID("payments two", three), "third")
        XCTAssertEqual(resolvedID("fix refunds", three), "titled")

        let two = [titled, second]
        XCTAssertEqual(SessionShownNames.of(two)["second"], "payments")
        XCTAssertEqual(resolvedID("payments", two), "second")
    }

    /// The popover names sessions by their cwd; its suffixed names answer
    /// even where the git-root walk names them apart.
    func testTheCuesNamesAnswerWhenTheWalkNamesSessionsApart() {
        let a = localSession("a", cwd: "/r/payments/docs", tty: "/dev/ttys001", seen: 0)
        let b = localSession("b", cwd: "/r/billing/docs", tty: "/dev/ttys002", seen: 1)
        XCTAssertEqual(AgentAttentionText.name(of: b, among: [a, b]), "docs · 2")
        let walked = [
            candidate(a, root: .root("/r/payments")),
            candidate(b, root: .root("/r/billing")),
        ]
        XCTAssertEqual(resolvedID("docs two", walked), "b")
        XCTAssertEqual(resolvedID("billing", walked), "b")
    }

    func testSessionsOnOnePaneShareOneName() {
        let old = localSession("old", cwd: "/r/payments", tty: "/dev/ttys001", seen: 0)
        var new = localSession("new", cwd: "/r/payments", tty: "/dev/ttys001", seen: 1)
        new.lastActivity = epoch.addingTimeInterval(60)
        XCTAssertEqual(SessionShownNames.of([candidate(old), candidate(new)]), ["old": "payments", "new": "payments"])
    }

    func testOnlyARandomWorktreeSuffixIsDropped() {
        let cases: [(String, String)] = [
            ("zealous-chaplygin-aa1a02", "zealous-chaplygin"),
            ("macos-widget-monthly-usage-825cc1", "macos-widget-monthly-usage"),
            ("serene-chaplygin-875410", "serene-chaplygin"),
            ("api-facade", "api-facade"),
            ("release-202609", "release-202609"),
            ("a1b2c3", "a1b2c3"),
        ]
        for (folder, expected) in cases {
            XCTAssertEqual(SessionDefaultNames(primary: folder, repository: nil).readablePrimary, expected, folder)
        }
    }

    func testABranchNamesAWorktreeOnlyWhenAPersonNamedIt() {
        let cases: [(String?, String)] = [
            ("fix/overlay-names", "overlay-names"),
            ("t/zealous-chaplygin-aa1a02", "zealous-chaplygin"),
            ("main", "zealous-chaplygin"),
            ("release/1013", "release/1013"),
            (nil, "zealous-chaplygin"),
        ]
        for (branch, expected) in cases {
            let names = SessionDefaultNames(primary: "zealous-chaplygin-aa1a02", repository: "localvoxtral", branch: branch)
            XCTAssertEqual(names.fallback, expected, branch ?? "nil")
        }
        let checkout = SessionDefaultNames(primary: "localvoxtral", repository: nil, branch: "fix/overlay-names")
        XCTAssertEqual(checkout.fallback, "localvoxtral", "a main checkout keeps the repository's name")
    }

    @MainActor
    func testTheCueNamesASessionAmongTheLiveOnes() {
        let first = localSession("a", cwd: "/r/payments", tty: "/dev/ttys001", seen: 0)
        let second = localSession("b", cwd: "/r/payments", tty: "/dev/ttys002", seen: 1)
        XCTAssertEqual(AgentAttentionText.name(of: second, among: [first, second]), "payments · 2")
        XCTAssertEqual(AgentAttentionText.name(of: first, among: [first, second]), "payments · 1")
        XCTAssertEqual(
            AgentAttentionText.name(of: second, among: [first, second], nickname: { $0 == "b" ? "billing" : nil }),
            "billing"
        )
        XCTAssertEqual(
            AgentAttentionText.name(of: first, among: [second], title: { $0.sessionID == "a" ? "Fix the overlay list" : nil }),
            "Fix the overlay list",
            "a session the registry dropped is still named"
        )
    }

    // MARK: - Claude Desktop's titles

    func testDesktopTitlesAreReadFromDesktopsSessionFile() throws {
        let directory = try temporaryDirectory()
        let id = "local_7e66212b-6bd0-4eb5-b551-068eda22432a"
        let file = try writeSession(id, in: directory, json: [
            "sessionId": id, "cliSessionId": "814e6ac2-dc22-4aae-a23c-cfee60bdba09",
            "cwd": "/home/dev/work/localvoxtral/.claude/worktrees/zealous-chaplygin-aa1a02",
            "branch": "t/zealous-chaplygin-aa1a02", "worktreeName": "zealous-chaplygin-aa1a02",
            "title": "Better session names\u{1B}[31m than\nthe worktree folder\u{202E} (#1013)", "titleSource": "auto",
        ])
        let titles = ClaudeDesktopSessionTitles(directory: directory)
        XCTAssertEqual(titles.title(desktopSessionID: id), "Better session names[31m than the worktree folder (#1013)")

        try JSONSerialization.data(withJSONObject: ["title": "Renamed"]).write(to: file)
        XCTAssertEqual(titles.title(desktopSessionID: id), "Renamed", "a changed file is read again")
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(titles.title(desktopSessionID: id), "a file Desktop deleted names nothing")

        XCTAssertNil(titles.title(desktopSessionID: "local_0000"), "no file")
        XCTAssertNil(titles.title(desktopSessionID: "local_../../x"), "not Desktop's id shape")
        XCTAssertNil(ClaudeDesktopSessionTitles.title(inSessionFile: Data(#"{"title":"  "}"#.utf8)))
        XCTAssertNil(ClaudeDesktopSessionTitles.title(inSessionFile: Data("not json".utf8)))
    }

    func testALongTitleIsCut() {
        let long = String(repeating: "word ", count: 40)
        let title = ClaudeDesktopSessionTitles.title(inSessionFile: try! JSONSerialization.data(withJSONObject: ["title": long]))
        XCTAssertEqual(title?.count, ClaudeDesktopSessionTitles.maxLength)
        XCTAssertEqual(title?.last, "…")
    }

    // MARK: - Helpers

    private func localSession(_ id: String, cwd: String, tty: String, seen: TimeInterval) -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: local, firstSeen: epoch.addingTimeInterval(seen))
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: local)
        snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: tty)
        snapshot.lastActivity = snapshot.firstSeen
        return snapshot
    }

    private func remoteSession(
        _ id: String, cwd: String, project: String, desktopID: String? = nil, seen: TimeInterval
    ) -> ClaudeSessionSnapshot {
        var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: devBox, firstSeen: epoch.addingTimeInterval(seen))
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: devBox)
        snapshot.remoteEnvironment = ClaudeRemoteSessionEnvironment(desktopSessionID: desktopID, project: project)
        snapshot.lastActivity = snapshot.firstSeen
        return snapshot
    }

    private func candidate(
        _ snapshot: ClaudeSessionSnapshot,
        root: LearnedTermProjectResolver.RepositoryRoot = .unknown,
        title: String? = nil,
        branch: String? = nil
    ) -> SessionNameCandidate {
        SessionNameCandidate(
            snapshot: snapshot,
            names: SessionDefaultNames.of(snapshot, repositoryRoot: root, title: title, branch: branch)
        )
    }

    private func resolvedID(_ spoken: String, _ candidates: [SessionNameCandidate]) -> String? {
        guard case .resolved(let snapshot) = SessionNameResolver.resolve(spokenName: spoken, candidates: candidates)
        else { return nil }
        return snapshot.sessionID
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-desktop-titles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func writeSession(_ id: String, in directory: URL, json: [String: Any]) throws -> URL {
        let org = directory.appendingPathComponent("92dcfa96-account/960ea615-org", isDirectory: true)
        try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
        let file = org.appendingPathComponent(id + ".json")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        return file
    }
}
