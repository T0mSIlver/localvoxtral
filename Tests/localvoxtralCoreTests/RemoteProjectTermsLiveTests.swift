import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

/// #641 end to end on a Linux remote host, with real agents: a real Claude
/// Code or Vibe session runs the shipped remote hooks, which reach the Mac's
/// listener through a real ssh `RemoteForward`; a dictation marks the session;
/// the next hook's reply asks; the hook starts the shipped runner detached; the
/// runner's `claude -p` or `vibe -p` answers; the answer lands in the learned
/// terms. Spends real tokens, so it runs only through
/// `scripts/linux/remote-terms-live.sh`, which holds the forward. Never on
/// the Mac.
///
/// The waits here are bounded polls on a detached process the test cannot
/// join, the one thing the unit tier (`RemoteProjectTermsTests`) never does.
final class RemoteProjectTermsLiveTests: XCTestCase {
    private final class MemoryHostStore: ClaudeRemoteHostStoreIO, @unchecked Sendable {
        private let contents = Mutex<Data?>(nil)
        func read(from url: URL) throws -> Data? { contents.withLock { $0 } }
        func write(_ data: Data, to url: URL) throws { contents.withLock { $0 = data } }
    }

    private final class Store: ProjectTermProposalStoring, @unchecked Sendable {
        let memory = Mutex(LearnedTerms())
        func snapshot() -> LearnedTerms { memory.withLock { $0 } }
        func recordProposal(
            _ terms: [String], agent: ProjectTermProposal.Agent,
            project: LearnedTermProjectIdentity, excluding: [String]
        ) {
            memory.withLock { $0.recordProposal(terms, agent: agent, project: project, excluding: excluding, now: Date()) }
        }
        func recordProposalFailure(project: LearnedTermProjectIdentity) {
            memory.withLock { $0.recordProposalFailure(project: project, now: Date()) }
        }
    }

    private var root: URL!
    private var listener: ClaudeRemoteContextListener!
    private var sessions: ClaudeSessionRegistry!
    private var store: Store!
    private var requests: RemoteProjectTermRequests!
    private var token = ""
    private var forwardPort = ""
    private final class Shared: Sendable {
        let answerSizes = Mutex<[Int]>([])
        let marking = Mutex(true)
        /// Every session any hook reported: the user's, and a phantom if the
        /// run's own hooks fired.
        let seen = Mutex<Set<String>>([])
    }
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
            .appendingPathComponent("remote-terms-live-\(UUID().uuidString)", isDirectory: true)
        let hosts = try ClaudeRemoteHostRegistry(
            fileURL: root.appendingPathComponent("hosts.json"), io: MemoryHostStore()
        )
        token = try hosts.enroll(label: "linux-box").token
        sessions = ClaudeSessionRegistry(isProcessAlive: { _ in true })
        store = Store()
        requests = RemoteProjectTermRequests(store: store, hosts: hosts)
        requests.debugObserveAnswers { [shared] size in shared.answerSizes.withLock { $0.append(size) } }
        listener = ClaudeRemoteContextListener(
            registry: sessions, hosts: hosts,
            limits: ClaudeRemoteListenerLimits(port: listenerPort),
            projectTerms: requests
        )
        try listener.start()
        // The dictation: every session the host reports is joined and
        // dictated into as soon as its first hook lands.
        let sessions = sessions!, requests = requests!, shared = shared
        Thread.detachNewThread {
            var marked = Set<String>()
            while shared.marking.withLock({ $0 }) {
                for session in sessions.liveSessions() where !marked.contains(session.sessionID) {
                    shared.seen.withLock { _ = $0.insert(session.sessionID) }
                    if requests.request(for: session, excluding: []) { marked.insert(session.sessionID) }
                }
                usleep(20_000)
            }
        }
    }

    override func tearDownWithError() throws {
        shared.marking.withLock { $0 = false }
        listener?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The #609 fixture, plus a project `SessionStart` hook that appends a
    /// line per firing.
    private func fixture(_ name: String) throws -> (repo: String, marker: String) {
        let repo = root.appendingPathComponent(name).path
        let marker = root.appendingPathComponent("\(name)-marker").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: repo + "/.claude", withIntermediateDirectories: true)
        try """
            # quillmark
            Quillmark renders Markdown to PDF through the `inkwell` layout engine.
            Set `QUILLMARK_FONT_DIR` to add fonts. The CLI is `qmk render`.
            """.write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        try """
            /// Lays out one page for inkwell.
            struct PageComposer { let glyphCache: GlyphAtlasCache }
            final class GlyphAtlasCache {}
            """.write(toFile: repo + "/src/PageComposer.swift", atomically: true, encoding: .utf8)
        try #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo fired >> \#(marker)"}]}]}}"#
            .write(toFile: repo + "/.claude/settings.json", atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            XCTAssertEqual(try run("/usr/bin/git", ["-C", repo] + arguments, in: repo, environment: ProcessInfo.processInfo.environment), 0)
        }
        return (repo, marker)
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

    /// Bounded: the runner's own watchdog is 180 s.
    private func waitForProposals(_ projectKey: String) -> [LearnedTerm] {
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            let terms = store.snapshot().projects.first { $0.key == projectKey }?.terms ?? []
            if !terms.isEmpty { return terms }
            usleep(250_000)
        }
        return []
    }

    private func markerLines(_ marker: String) -> Int {
        ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func report(_ label: String, _ terms: [LearnedTerm]) {
        print("[\(label)] proposals stored: \(terms.map(\.term)) sources \(Set(terms.flatMap(\.sources)).sorted())")
        print("[\(label)] posted body sizes: \(shared.answerSizes.withLock { $0 }) bytes")
        print("[\(label)] sessions the host reported: \(shared.seen.withLock { $0.sorted() })")
    }

    func testAClaudeCodeSessionOnTheHostProposesItsProjectsTerms() throws {
        let (repo, marker) = try fixture("quillmark")
        let plugin = repoRoot.appendingPathComponent("integrations/claude-code/plugins/localvoxtral-remote").path
        let base = ProcessInfo.processInfo.environment
        // The user's session: the shipped plugin from this tree, the user's
        // own settings (and installed plugins) left out. It stays open for
        // the run: an answer for a session that has ended is refused.
        let status = try run(try which("claude"), [
            "-p", "Read README.md, then run the shell command `echo waiting && sleep 75` with a 120000 ms timeout, then reply with the single word ok.",
            "--plugin-dir", plugin,
            "--setting-sources", "project",
            "--model", "haiku",
            "--max-turns", "6",
            "--allowedTools", "Read,Bash(echo:*),Bash(sleep:*)",
        ], in: repo, environment: [
            "HOME": base["HOME"] ?? "", "PATH": base["PATH"] ?? "", "LANG": base["LANG"] ?? "C.UTF-8",
            "CLAUDE_PLUGIN_OPTION_TOKEN": token, "CLAUDE_PLUGIN_OPTION_PORT": forwardPort,
        ])
        XCTAssertEqual(status, 0)
        let terms = waitForProposals("remote:quillmark")
        report("claude", terms)
        XCTAssertFalse(terms.isEmpty, "no answer reached /v1/terms")
        XCTAssertTrue(terms.allSatisfy { $0.sources == ["agent:claude"] && $0.isUnconfirmedProposal })
        XCTAssertEqual(markerLines(marker), 1, "only the user's session may fire the project's SessionStart hook")
        XCTAssertEqual(shared.seen.withLock(\.count), 1, "the run published a session of its own")
    }

    /// The unified harness runs no user hook under `vibe -p` (programmatic
    /// mode denies the callbacks), so this session is interactive, driven
    /// through a pty. It also runs a hook command without a shell, so `$HOME`
    /// in the shipped block is never expanded (#641 follow-up); the commands
    /// here are absolute paths.
    func testAVibeSessionOnTheHostStartsTheRunnerFromItsHookUnified() throws {
        try vibe(harness: "--experimental-harness", project: "quillmark-unified", interactive: true)
    }

    func testAVibeSessionOnTheHostStartsTheRunnerFromItsHookLegacy() throws {
        try vibe(harness: "--legacy-harness", project: "quillmark-legacy")
    }

    /// A home of the user's own for the Vibe session: their real config and
    /// key, the shipped remote hooks from this tree, and a `post_agent`
    /// marker hook. The runner's app-owned Vibe home lands under it too.
    private func vibe(harness: String, project: String, interactive: Bool = false) throws {
        let (repo, marker) = try fixture(project)
        let base = ProcessInfo.processInfo.environment
        let realHome = try XCTUnwrap(base["HOME"])
        let home = root.appendingPathComponent("home-\(project)").path
        let vibeHome = home + "/.vibe"
        let remote = vibeHome + "/localvoxtral/remote"
        let fm = FileManager.default
        try fm.createDirectory(atPath: remote, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: vibeHome + "/.env", withDestinationPath: realHome + "/.vibe/.env")
        // The user's model config, without the update prompt an interactive
        // session would otherwise open on.
        let config = (try? String(contentsOfFile: realHome + "/.vibe/config.toml", encoding: .utf8)) ?? ""
        try ("enable_update_checks = false\n" + config.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("enable_update_checks") }.joined(separator: "\n"))
            .write(toFile: vibeHome + "/config.toml", atomically: true, encoding: .utf8)
        // A hook command is run without a shell on the unified harness, so the
        // marker is a script that appends.
        let markerScript = root.appendingPathComponent("\(project)-marker.sh").path
        try "#!/bin/sh\necho fired >> \(marker)\n".write(toFile: markerScript, atomically: true, encoding: .utf8)
        for path in ["integrations/vibe/remote/post.sh", "integrations/vibe/remote/compact.py",
                     "integrations/claude-code/plugins/localvoxtral-remote/hooks/terms.sh"] {
            try fm.copyItem(
                atPath: repoRoot.appendingPathComponent(path).path,
                toPath: remote + "/" + (path as NSString).lastPathComponent
            )
        }
        try token.write(toFile: remote + "/token", atomically: true, encoding: .utf8)
        try forwardPort.write(toFile: remote + "/port", atomically: true, encoding: .utf8)
        var block = try String(
            contentsOf: repoRoot.appendingPathComponent("integrations/vibe/remote/hooks.toml"), encoding: .utf8
        )
        if interactive {
            block = block.replacingOccurrences(
                of: #"sh \"$HOME/.vibe/localvoxtral/remote/post.sh\" 2>/dev/null || :"#,
                with: "sh \(remote)/post.sh"
            )
        }
        try (block + """

            [[hooks]]
            name = "marker"
            type = "post_agent"
            command = "sh \(markerScript)"
            timeout = 5.0
            """).write(toFile: vibeHome + "/hooks.toml", atomically: true, encoding: .utf8)

        let environment = [
            "HOME": home, "PATH": base["PATH"] ?? "", "LANG": base["LANG"] ?? "C.UTF-8",
            // The session must outlive the run; the watcher would end it.
            "LOCALVOXTRAL_VIBE_WATCHER": "off",
        ]
        let prompt = "Read README.md, then reply with the single word ok."
        let status = interactive
            ? try run(try which("python3"), [
                repoRoot.appendingPathComponent("scripts/linux/vibe-tty-turn.py").path,
                prompt, try which("vibe"), harness, "--auto-approve",
            ], in: repo, environment: environment)
            : try run(try which("vibe"), [harness, "--auto-approve", "-p", prompt, "--max-turns", "4"],
                      in: repo, environment: environment)
        XCTAssertEqual(status, 0)
        let terms = waitForProposals("remote:\(project)")
        report("vibe \(harness)", terms)
        XCTAssertFalse(terms.isEmpty, "no answer reached /v1/terms")
        XCTAssertTrue(terms.allSatisfy { $0.sources == ["agent:vibe"] && $0.isUnconfirmedProposal })
        XCTAssertEqual(markerLines(marker), 1, "only the user's session may fire the post_agent hook")
        XCTAssertEqual(shared.seen.withLock(\.count), 1, "the run published a session of its own")
        XCTAssertTrue(fm.fileExists(atPath: remote + "/vibe-home/config.toml"), "the run used its own Vibe home")
    }
}
