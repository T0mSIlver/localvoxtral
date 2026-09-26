import ClaudeContextWire
import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

/// The real `claude -p` and `vibe -p` runs of #609, through the production
/// proposer and runner, against a fixture repository whose hooks write a
/// marker file. Spends real tokens (about $0.25 for the whole class), so it
/// runs only through `scripts/linux/project-terms-live.sh`, on Linux, never on
/// the Mac.
final class ProjectTermProposalLiveTests: XCTestCase {
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

    /// Records what the real runner returned, usage included.
    private final class Recording: ProjectTermProposalRunning, @unchecked Sendable {
        let inner: ProjectTermProposalProcessRunner
        let outcomes = Mutex<[ProjectTermProposal.Outcome]>([])
        init(_ inner: ProjectTermProposalProcessRunner) { self.inner = inner }
        func run(_ invocation: ProjectTermProposal.Invocation) async -> ProjectTermProposal.Outcome {
            let outcome = await inner.run(invocation)
            outcomes.withLock { $0.append(outcome) }
            return outcome
        }
    }

    private var root: URL!
    private var repo: String { root.appendingPathComponent("quillmark").path }
    private var claudeMarker: String { root.appendingPathComponent("claude-session-start-hook-ran").path }
    private var vibeMarker: String { root.appendingPathComponent("vibe-post-agent-hook-ran").path }
    /// Stands in for the user's `~/.vibe`: their real config and key, and a
    /// `post_agent` hook that writes the marker.
    private var userVibe: URL { root.appendingPathComponent("user-vibe") }
    private var appVibeHome: URL { root.appendingPathComponent("app-vibe-home") }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["LV_PROJECT_TERMS_LIVE"] == "1" else {
            throw XCTSkip("spends tokens: run through scripts/linux/project-terms-live.sh")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-terms-live-\(UUID().uuidString)", isDirectory: true)
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
        try #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch \#(claudeMarker)"}]}]}}"#
            .write(toFile: repo + "/.claude/settings.json", atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", repo] + arguments
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }

        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["HOME"])
        try fm.createDirectory(at: userVibe, withIntermediateDirectories: true)
        for name in VibeProposalHome.linkedFiles {
            try fm.createSymbolicLink(
                atPath: userVibe.appendingPathComponent(name).path,
                withDestinationPath: home + "/.vibe/" + name
            )
        }
        try """
            [[hooks]]
            name = "marker"
            type = "post_agent"
            command = "touch \(vibeMarker)"
            timeout = 5.0
            """.write(to: userVibe.appendingPathComponent("hooks.toml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func join(_ agent: ClaudeHookAgent) -> ClaudeSessionSnapshot {
        let origin = ClaudeTransportOrigin.localAuthenticated(peerUID: getuid())
        var snapshot = ClaudeSessionSnapshot(sessionID: "live", origin: origin, agent: agent, firstSeen: Date())
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: repo + "/src", origin: origin)
        return snapshot
    }

    private func propose(_ agent: ClaudeHookAgent) async -> (ProjectTermProposal.Outcome?, Store) {
        let runner = Recording(ProjectTermProposalProcessRunner(vibeHome: appVibeHome, userVibeDirectory: userVibe))
        let store = Store()
        let proposer = ProjectTermProposer(store: store, runner: runner, now: { Date() })
        await proposer.dictationCommitted(join: join(agent), enabled: true, excluding: [])?.value
        return (runner.outcomes.withLock { $0.first }, store)
    }

    private func report(_ label: String, _ outcome: ProjectTermProposal.Outcome?, _ store: Store) {
        print("[\(label)] outcome: \(String(describing: outcome))")
        print("[\(label)] proposals stored: \(store.snapshot().unconfirmedProposals(projectKey: repo))")
    }

    func testClaudeProposesTheFixturesTermsWithoutFiringItsHooks() async throws {
        let (outcome, store) = await propose(.claude)
        report("claude", outcome, store)
        guard case .terms(_, let usage)? = outcome else { return XCTFail("claude run failed") }
        print("[claude] usage: \(usage?.summary ?? "none")")
        XCTAssertFalse(store.snapshot().unconfirmedProposals(projectKey: repo).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeMarker), "the SessionStart hook fired")

        // Control: the same run with hooks left on does fire the marker, so
        // its absence above means something.
        var arguments = ProjectTermProposal.claudeArguments()
        let settings = try XCTUnwrap(arguments.firstIndex(of: "--settings"))
        arguments[settings + 1] = "{}"
        let executable = try XCTUnwrap(ProjectTermProposalProcessRunner.candidates(
            for: .claude, environment: ProcessInfo.processInfo.environment
        ).first { FileManager.default.isExecutableFile(atPath: $0) })
        _ = await BoundedProcess.run(
            executableURL: URL(fileURLWithPath: executable), arguments: arguments,
            environment: ProcessInfo.processInfo.environment, currentDirectory: repo,
            timeoutSeconds: 120, maxBytes: 8_000_000, label: "control"
        )
        print("[claude control, hooks on] marker present: \(FileManager.default.fileExists(atPath: claudeMarker))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeMarker), "control: the hook never fires here")
    }

    /// Run twice, with the app home's cached harness rollout set to each
    /// value in turn: the forced `--experimental-harness` must answer
    /// whichever harness the account defaults to.
    func testVibeProposesTheFixturesTermsWithoutFiringTheUsersHooksOnEitherDefaultHarness() async throws {
        for rollout in ["unified", "legacy"] {
            try setCachedHarnessRollout(rollout)
            let (outcome, store) = await propose(.vibe)
            report("vibe, default \(rollout)", outcome, store)
            print("[vibe, default \(rollout)] tokens: \(vibeSessionTokens())")
            guard case .terms? = outcome else { return XCTFail("vibe run failed with default \(rollout)") }
            XCTAssertFalse(store.snapshot().unconfirmedProposals(projectKey: repo).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: vibeMarker), "the user's post_agent hook fired")
        }

        // Control: the same run under the user's home does fire it.
        var environment = ProcessInfo.processInfo.environment
        environment["VIBE_HOME"] = userVibe.path
        let executable = try XCTUnwrap(ProjectTermProposalProcessRunner.candidates(
            for: .vibe, environment: environment
        ).first { FileManager.default.isExecutableFile(atPath: $0) })
        _ = await BoundedProcess.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: ProjectTermProposal.vibeArguments(trackedFiles: ["README.md", "src/PageComposer.swift"]),
            environment: environment, currentDirectory: repo,
            timeoutSeconds: 120, maxBytes: 8_000_000, label: "control"
        )
        print("[vibe control, user home] marker present: \(FileManager.default.fileExists(atPath: vibeMarker))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vibeMarker), "control: the hook never fires here")
    }

    /// Vibe caches its server-side rollout per home; before the first run
    /// the app home has none and fetches it.
    private func setCachedHarnessRollout(_ value: String) throws {
        let cache = appVibeHome.appendingPathComponent("experiment_eval_cache.json")
        guard let data = FileManager.default.contents(atPath: cache.path),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            print("[vibe] no cached rollout yet: running with the fetched default")
            return
        }
        for (key, entry) in object {
            guard var entry = entry as? [String: Any],
                  var payload = entry["payload"] as? [String: Any],
                  var features = payload["features"] as? [String: Any],
                  var rollout = features["vibe_cli_unified_harness_rollout"] as? [String: Any]
            else { continue }
            rollout["defaultValue"] = value
            features["vibe_cli_unified_harness_rollout"] = rollout
            payload["features"] = features
            entry["payload"] = payload
            object[key] = entry
        }
        try JSONSerialization.data(withJSONObject: object).write(to: cache)
    }

    /// Vibe keeps usage out of `--output json`. The unified harness journals
    /// each model call under `logs/session/unified/<id>/journal`; this sums
    /// the newest session's calls. Prices are Vibe's own log values.
    private func vibeSessionTokens() -> String {
        let sessions = appVibeHome.appendingPathComponent("logs/session/unified")
        let fm = FileManager.default
        let newest = ((try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l < r
            }
        guard let journal = newest?.appendingPathComponent("journal"),
              let files = try? fm.contentsOfDirectory(atPath: journal.path)
        else { return "no unified session log" }
        var totals: [String: Int] = [:]
        let pattern = try! NSRegularExpression(pattern: #""(inputTokens|cachedInputTokens|outputTokens)":\s*([0-9]+)"#)
        for file in files {
            guard let text = try? String(contentsOf: journal.appendingPathComponent(file), encoding: .utf8) else { continue }
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let key = Range(match.range(at: 1), in: text),
                      let value = Range(match.range(at: 2), in: text)
                else { continue }
                totals[String(text[key]), default: 0] += Int(text[value]) ?? 0
            }
        }
        return ["inputTokens", "cachedInputTokens", "outputTokens"]
            .map { "\($0)=\(totals[$0] ?? 0)" }
            .joined(separator: " ")
    }
}
