import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore
import localvoxtralTestSupport

/// #745 end to end on a Linux remote host, with real agents: a real Claude
/// Code or Vibe session, in a linked worktree of a repository, runs the
/// shipped remote hooks, which reach the Mac's listener through a real ssh
/// `RemoteForward`. The first hook's reply asks for the README; once the
/// session is live, a quick capture routed to its project waits for the next
/// hook, whose reply asks for a draft; the host's `claude -p` or `vibe -p`
/// drafts it in its checkout and the draft comes back. Spends real tokens,
/// so it runs only through `scripts/linux/remote-terms-live.sh --filter
/// RemoteQuickCaptureLiveTests`, which holds the forward. Never on the Mac.
///
/// The waits are bounded polls on detached processes the test cannot join.
final class RemoteQuickCaptureLiveTests: XCTestCase {
    private final class Store: RemoteProjectSummaryStoring, @unchecked Sendable {
        let memory = Mutex(LearnedTerms())
        func snapshot() -> LearnedTerms { memory.withLock { $0 } }
        func recordSummary(_ summary: String?, projectKey: String) {
            memory.withLock { _ = $0.recordSummary(summary, projectKey: projectKey, now: Date()) }
        }
        func recordRemoteReport(
            project: LearnedTermProjectIdentity, asRepository: Bool, repository: String?, hostID: String?
        ) {
            memory.withLock {
                _ = $0.recordRemoteReport(project: project, asRepository: asRepository, repository: repository, hostID: hostID, now: Date())
            }
        }
        func recordAgentActivity(_ repositories: [AgentWorkedRepository], hostID: String?) {}
    }

    private final class Shared: Sendable {
        let outcome = Mutex<QuickCaptureDraft.Outcome?>(nil)
        /// Every session any hook reported, with its learned-terms project.
        let seen = Mutex<[String: String]>([:])
        let watching = Mutex(true)
    }

    private static let capture =
        "For quillmark, the render command should take a flag that picks the page size, A4 or letter, "
            + "instead of always using A4."

    private var root: URL!
    private var listener: ClaudeRemoteContextListener!
    private var sessions: ClaudeSessionRegistry!
    private var store: Store!
    private var requests: RemoteQuickCaptureRequests!
    private var token = ""
    private var forwardPort = ""
    private let shared = Shared()

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LV_REMOTE_TERMS_LIVE"] == "1",
              let listenerPort = environment["LVX_LISTENER_PORT"].flatMap(UInt16.init),
              let forwardPort = environment["LVX_FORWARD_PORT"]
        else {
            throw XCTSkip("spends tokens: run through scripts/linux/remote-terms-live.sh")
        }
        self.forwardPort = forwardPort
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-capture-live-\(UUID().uuidString)", isDirectory: true)
        let hosts = try ClaudeRemoteHostRegistry(
            fileURL: root.appendingPathComponent("hosts.json"), io: MemoryRemoteHostStoreIO()
        )
        token = try hosts.enroll(label: "linux-box").token
        sessions = ClaudeSessionRegistry(isProcessAlive: { _ in true })
        store = Store()
        requests = RemoteQuickCaptureRequests(store: store, hosts: hosts, registry: sessions)
        listener = ClaudeRemoteContextListener(
            registry: sessions, hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: listenerPort),
            quickCapture: requests
        )
        try listener.start()
    }

    override func tearDownWithError() throws {
        shared.watching.withLock { $0 = false }
        listener?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A repository named `name` with a README and a CLI, and a linked
    /// worktree the session runs in. The learned terms hold the project, as
    /// after a dictation into it.
    private func fixture(_ name: String) throws -> String {
        let repo = root.appendingPathComponent(name).path
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try """
            # quillmark

            [![CI](https://example.com/ci.svg)](https://example.com)

            Quillmark renders Markdown to PDF through the `inkwell` layout engine.

            The CLI is `qmk render <file>`; pages are always A4 for now.
            """.write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try """
            /// `qmk render <file>`: lays every page out at A4.
            struct RenderCommand {
                static let pageSize = PageSize.a4
                func run(file: String) { PageComposer(size: Self.pageSize).render(file) }
            }
            enum PageSize { case a4 }
            struct PageComposer { let size: PageSize; func render(_ file: String) {} }
            """.write(toFile: repo + "/src/RenderCommand.swift", atomically: true, encoding: .utf8)
        let git = try which("git")
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"],
                          ["worktree", "add", "-q", repo + "/.claude/worktrees/bold-bose"]] {
            XCTAssertEqual(try run(git, ["-C", repo] + arguments, in: repo, environment: ProcessInfo.processInfo.environment), 0)
        }
        store.memory.withLock {
            $0.recordProposalFailure(project: LearnedTermProjectIdentity(key: "remote:\(name)", name: name), now: Date())
        }
        return repo + "/.claude/worktrees/bold-bose"
    }

    /// The Inbox's side: once the host reports a live session in the
    /// project, the capture routed there is drafted.
    private func draftWhenTheSessionIsLive(project: QuickCaptureProject) {
        let sessions = sessions!, requests = requests!, shared = shared
        Thread.detachNewThread {
            var started = false
            while shared.watching.withLock({ $0 }) {
                let live = sessions.liveSessions()
                shared.seen.withLock { seen in
                    for session in live {
                        seen[session.sessionID] = LearnedTermProjectResolver.resolve(
                            repositoryRoot: .unknown, workspace: session.learnedTermWorkspace
                        )?.key ?? "none"
                    }
                }
                if !live.isEmpty, !started {
                    started = true
                    Task {
                        let outcome = await requests.draft(capture: Self.capture, project: project)
                        shared.outcome.withLock { $0 = outcome }
                    }
                }
                usleep(20_000)
            }
        }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func which(_ name: String) throws -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidate = path.split(separator: ":").map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        return try XCTUnwrap(candidate, "\(name) is not on PATH")
    }

    /// Bounded: the host's watchdog is 240 s, `gh` 20 s.
    private func waitForOutcome() -> QuickCaptureDraft.Outcome? {
        let deadline = Date().addingTimeInterval(330)
        while Date() < deadline {
            if let outcome = shared.outcome.withLock({ $0 }) { return outcome }
            usleep(250_000)
        }
        return nil
    }

    private func check(_ label: String, project name: String, agent: String, sessions expected: Int = 1) throws {
        let outcome = waitForOutcome()
        let kept = store.snapshot().projects.first { $0.key == "remote:\(name)" }
        print("[\(label)] sessions the host reported: \(shared.seen.withLock { $0 }.sorted { $0.key < $1.key })")
        print("[\(label)] README summary kept on remote:\(name): \(kept?.summary ?? "none")")
        switch outcome {
        case .draft(let draft, let usage)?:
            print("[\(label)] draft: relation \(draft.relation.rawValue), \(usage?.summary ?? "usage not reported")")
            print("[\(label)] title: \(draft.title)")
            print("[\(label)] body:\n\(draft.body)")
        case let other:
            print("[\(label)] outcome: \(String(describing: other))")
        }
        guard case .draft(let draft, _)? = outcome else { return XCTFail("no draft came back") }
        XCTAssertFalse(draft.title.isEmpty)
        XCTAssertEqual(
            kept?.summary,
            "Quillmark renders Markdown to PDF through the inkwell layout engine. The CLI is qmk render ; pages are always A4 for now.",
            "the local cut: `<file>` reads as HTML"
        )
        let seen = shared.seen.withLock { $0 }
        XCTAssertEqual(seen.count, expected, "the host's run published a session of its own")
        XCTAssertTrue(seen.keys.allSatisfy { $0.hasPrefix(agent == "vibe" ? "vibe:remote:" : "remote:") })
        XCTAssertTrue(
            seen.values.allSatisfy { $0 == "remote:\(name)" },
            "a worktree's session is the repository's project"
        )
    }

    func testAClaudeCodeSessionInAWorktreeDraftsTheCaptureOnTheHost() throws {
        let worktree = try fixture("quillmark")
        let project = QuickCaptureProject(key: "remote:quillmark", name: "quillmark", summary: nil, terms: [], userLine: nil)
        draftWhenTheSessionIsLive(project: project)
        let plugin = repoRoot.appendingPathComponent("integrations/claude-code/plugins/localvoxtral-remote").path
        let base = ProcessInfo.processInfo.environment
        let status = try run(try which("claude"), [
            "-p", "Read README.md, then run the shell command `echo waiting && sleep 20`, then reply with the single word ok.",
            "--plugin-dir", plugin,
            "--setting-sources", "project",
            "--model", "haiku",
            "--max-turns", "6",
            "--allowedTools", "Read,Bash(echo:*),Bash(sleep:*)",
        ], in: worktree, environment: [
            "HOME": base["HOME"] ?? "", "PATH": base["PATH"] ?? "", "LANG": base["LANG"] ?? "C.UTF-8",
            "CLAUDE_PLUGIN_OPTION_TOKEN": token, "CLAUDE_PLUGIN_OPTION_PORT": forwardPort,
        ])
        XCTAssertEqual(status, 0)
        try check("claude", project: "quillmark", agent: "claude")
    }

    /// The legacy harness runs the user's hooks under `vibe -p`; the unified
    /// one does not (#712). A `vibe -p` session sends its hooks once, at the
    /// end of its turn, so a second session in the project carries the ask.
    func testAVibeSessionInAWorktreeDraftsTheCaptureOnTheHost() throws {
        let worktree = try fixture("quillmark")
        let project = QuickCaptureProject(key: "remote:quillmark", name: "quillmark", summary: nil, terms: [], userLine: nil)
        draftWhenTheSessionIsLive(project: project)
        let base = ProcessInfo.processInfo.environment
        let realHome = try XCTUnwrap(base["HOME"])
        let home = root.appendingPathComponent("home").path
        let vibeHome = home + "/.vibe"
        let remote = vibeHome + "/localvoxtral/remote"
        let fm = FileManager.default
        try fm.createDirectory(atPath: remote, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: vibeHome + "/.env", withDestinationPath: realHome + "/.vibe/.env")
        try fm.createSymbolicLink(atPath: vibeHome + "/config.toml", withDestinationPath: realHome + "/.vibe/config.toml")
        for path in ["integrations/vibe/remote/post.sh", "integrations/vibe/remote/compact.py",
                     "integrations/claude-code/plugins/localvoxtral-remote/hooks/terms.sh",
                     "integrations/claude-code/plugins/localvoxtral-remote/hooks/capture.sh"] {
            try fm.copyItem(
                atPath: repoRoot.appendingPathComponent(path).path,
                toPath: remote + "/" + (path as NSString).lastPathComponent
            )
        }
        try token.write(toFile: remote + "/token", atomically: true, encoding: .utf8)
        try forwardPort.write(toFile: remote + "/port", atomically: true, encoding: .utf8)
        try fm.copyItem(
            atPath: repoRoot.appendingPathComponent("integrations/vibe/remote/hooks.toml").path,
            toPath: vibeHome + "/hooks.toml"
        )
        for _ in 1...2 {
            let status = try run(try which("vibe"), [
                "--legacy-harness", "--auto-approve", "-p",
                "Read README.md, then reply with the single word ok.",
                "--max-turns", "4",
            ], in: worktree, environment: [
                "HOME": home, "PATH": base["PATH"] ?? "", "LANG": base["LANG"] ?? "C.UTF-8",
                "LOCALVOXTRAL_VIBE_WATCHER": "off",
            ])
            XCTAssertEqual(status, 0)
        }
        try check("vibe --legacy-harness", project: "quillmark", agent: "vibe", sessions: 2)
    }
}
