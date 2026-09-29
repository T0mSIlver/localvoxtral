import ClaudeContextWire
import Foundation
@testable import LocalvoxtralCLICore
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

/// `localvoxtral doctor`: every check that is not fine names its fix.
final class AgentCLIDoctorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func facts(
        commandLink: AgentCLIDoctorFacts.CommandLink? = .init(state: .installed),
        microphone: AgentCLIDoctorFacts.Permission = .granted,
        accessibilityTrusted: Bool = true,
        speech: AgentCLIDoctorFacts.Engine = .managed(.ready),
        polish: AgentCLIDoctorFacts.Engine = .mistralAPI(keySet: true),
        claudePlugin: ClaudePluginStatus? = .installed(version: "2.4.0"),
        codexPlugin: CodexPluginInstallService.Status? = .installed,
        codexHookHeard: Bool = true,
        opencodePlugin: OpencodePluginInstallService.Status? = .installed,
        vibeHooks: VibeHooksInstallService.Status? = .installed,
        dictationNotes: [DictationNoteAgent: DictationNoteInstallService.Status] = [
            .claudeCode: .added(path: ".claude/CLAUDE.md"),
        ],
        remoteHosts: [AgentCLIDoctorFacts.RemoteHost] = [],
        recentJoins: [AgentCLIDoctorFacts.JoinLine]? = nil
    ) -> AgentCLIDoctorFacts {
        AgentCLIDoctorFacts(
            appVersion: "1.4.0",
            appBundlePath: "/Applications/localvoxtral.app",
            commandLink: commandLink,
            microphone: microphone,
            accessibilityTrusted: accessibilityTrusted,
            speech: speech,
            polish: polish,
            claudePlugin: claudePlugin,
            codexPlugin: codexPlugin,
            codexHookHeard: codexHookHeard,
            opencodePlugin: opencodePlugin,
            vibeHooks: vibeHooks,
            dictationNotes: dictationNotes,
            remoteHosts: remoteHosts,
            recentJoins: recentJoins ?? [.init(at: now.addingTimeInterval(-120), line: "arm=tty origin=local causes=none")],
            now: now
        )
    }

    func testAHealthySetupHasNothingToFix() {
        let checks = AgentCLIDoctorChecks.checks(facts(remoteHosts: [
            .init(label: "devbox", sshHostAlias: "devbox", lastSeenAt: now.addingTimeInterval(-600),
                  pluginNeedsUpdate: false, reportedPluginVersion: "1.22.0"),
        ]))
        XCTAssertEqual(checks.map(\.id), [
            "app", "command-link", "microphone", "accessibility", "speech", "polish", "claude-plugin",
            "codex-plugin", "opencode-plugin", "vibe-hooks", "dictation-note.claudeCode", "remote-host.1", "last-join",
        ])
        XCTAssertEqual(checks.filter { $0.state != .ok }.map(\.id), [])
        XCTAssertEqual(checks.first?.detail, "localvoxtral 1.4.0, running from /Applications/localvoxtral.app.")
        XCTAssertEqual(checks.first { $0.id == "remote-host.1" }?.detail, "Last context 10 min ago. Plugin 1.22.0.")
    }

    func testEachFieldProblemFailsItsCheckWithAFix() {
        let checks = AgentCLIDoctorChecks.checks(facts(
            commandLink: .init(state: .otherCopy, target: "/Users/me/Downloads/localvoxtral.app/Contents/MacOS/localvoxtral-cli"),
            microphone: .denied,
            accessibilityTrusted: false,
            speech: .managed(.failed(summary: "The speech engine exited.", detail: "stderr")),
            polish: .mistralAPI(keySet: false),
            claudePlugin: .updateAvailable(installed: "2.3.0", bundled: "2.4.0"),
            codexPlugin: .installed,
            codexHookHeard: false,
            opencodePlugin: .installedUnlisted,
            vibeHooks: .conflictingHooks,
            dictationNotes: [
                .claudeCode: .differs(path: ".claude/CLAUDE.md"),
                .codex: .needsManualFix(path: ".codex/AGENTS.md", .unpairedMarkers),
            ],
            remoteHosts: [
                .init(label: "devbox", sshHostAlias: "devbox", lastSeenAt: nil, pluginNeedsUpdate: false),
                .init(label: "gpu", sshHostAlias: "gpu", lastSeenAt: now, pluginNeedsUpdate: true),
                .init(label: "old", sshHostAlias: "old", lastSeenAt: now, pluginNeedsUpdate: false,
                      forwardFailure: "Host key changed."),
                .init(label: "held", sshHostAlias: "held", lastSeenAt: nil, pluginNeedsUpdate: false,
                      keepsTunnelOpen: true),
            ],
            recentJoins: [.init(at: now, line: "arm=none origin=none causes=tty: no live session on this device")]
        ))
        let states = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0.state) })
        XCTAssertEqual(states, [
            "app": .ok,
            "command-link": .warning,
            "microphone": .failed,
            "accessibility": .failed,
            "speech": .failed,
            "polish": .failed,
            "claude-plugin": .warning,
            "codex-plugin": .warning,
            "opencode-plugin": .warning,
            "vibe-hooks": .failed,
            "dictation-note.claudeCode": .warning,
            "dictation-note.codex": .warning,
            "remote-host.1": .warning,
            "remote-host.2": .warning,
            "remote-host.3": .failed,
            "remote-host.4": .warning,
            "last-join": .warning,
        ])
        XCTAssertEqual(checks.filter { $0.state != .ok && $0.fix == nil }.map(\.id), [])
        // The engine's stderr stays out: only its one-line summary is shown.
        XCTAssertFalse(checks.contains { $0.detail.contains("stderr") })
        let fixes = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0.fix) })
        XCTAssertEqual(fixes["remote-host.3"], "Run `ssh old true` in a terminal to see ssh's own error.")
        XCTAssertEqual(
            fixes["remote-host.2"],
            "Settings > Remote hosts > Update Host…, then run `/reload-plugins` in its Claude Code sessions "
                + "and restart its Vibe sessions."
        )
        XCTAssertEqual(fixes["opencode-plugin"], "Settings > opencode > Set up…")
        XCTAssertEqual(
            fixes["dictation-note.claudeCode"],
            "Settings > Claude Code > Tell Claude Code you dictate > Update, then restart Claude Code sessions."
        )
        // Keep the tunnel open is already on: the fix points at the host's end.
        XCTAssertEqual(fixes["remote-host.4"], AgentCLIDoctorChecks.keepTunnelOpenHostFix)
        XCTAssertEqual(
            checks.first { $0.id == "command-link" }?.detail,
            "/usr/local/bin/localvoxtral points to /Users/me/Downloads/localvoxtral.app/Contents/MacOS/localvoxtral-cli, "
                + "but the app running is /Applications/localvoxtral.app."
        )
    }

    /// A session whose hooks still send an older shim than its host has is
    /// named, with `/reload-plugins` for Claude Code and a restart for Vibe
    /// (#969). One behind and one current per agent.
    func testSessionsOnAnOlderShimThanTheirHostAreNamedWithTheirFix() {
        func host(_ sessions: [AgentCLIDoctorFacts.RemoteHost.Session]) -> AgentCLIDoctorFacts.RemoteHost {
            .init(label: "devbox", lastSeenAt: now, pluginNeedsUpdate: false, reportedPluginVersion: "1.25.0",
                  installedPluginVersion: .version("1.25.0"), installedVibeHooksVersion: "1.4.0", sessions: sessions)
        }
        let claudeBehind = AgentCLIDoctorFacts.RemoteHost.Session(label: "api", agent: .claude, shimVersion: .version("1.24.0"))
        let claudeCurrent = AgentCLIDoctorFacts.RemoteHost.Session(label: "web", agent: .claude, shimVersion: .version("1.25.0"))
        let vibeBehind = AgentCLIDoctorFacts.RemoteHost.Session(label: "notes", agent: .vibe, shimVersion: .version("1.3.0"))
        let vibeCurrent = AgentCLIDoctorFacts.RemoteHost.Session(label: "cli", agent: .vibe, shimVersion: .version("1.4.0"))

        let both = AgentCLIDoctorChecks.checks(facts(remoteHosts: [
            host([claudeBehind, claudeCurrent, vibeBehind, vibeCurrent]),
        ]))
        XCTAssertEqual(both.map(\.id).suffix(3), ["remote-host.1", "remote-sessions.1", "last-join"])
        XCTAssertEqual(
            AgentCLIDoctor(checks: both.filter { $0.id == "remote-sessions.1" }).textLines(),
            [
                "1. [warn] Sessions on devbox: 2 sessions run an older plugin than the host has.",
                "   api, Claude Code: plugin 1.24.0; the host has 1.25.0.",
                "   notes, Mistral Vibe: hooks 1.3.0; the host has 1.4.0.",
                "   fix: Run `/reload-plugins` in each Claude Code session listed, and restart each Vibe one.",
            ]
        )

        let claudeOnly = AgentCLIDoctorChecks.checks(facts(remoteHosts: [host([claudeBehind, claudeCurrent, vibeCurrent])]))
        let claudeCheck = claudeOnly.first { $0.id == "remote-sessions.1" }
        XCTAssertEqual(claudeCheck?.detail, "1 session runs an older plugin than the host has.")
        XCTAssertEqual(claudeCheck?.fix, "Run `/reload-plugins` in each session listed.")

        let vibeOnly = AgentCLIDoctorChecks.checks(facts(remoteHosts: [host([claudeCurrent, vibeBehind])]))
        XCTAssertEqual(vibeOnly.first { $0.id == "remote-sessions.1" }?.lines, [
            "notes, Mistral Vibe: hooks 1.3.0; the host has 1.4.0.",
        ])
        XCTAssertEqual(
            vibeOnly.first { $0.id == "remote-sessions.1" }?.fix,
            "Restart each session listed: Vibe has no `/reload-plugins`."
        )

        // Current sessions, or one whose hook sent nothing yet: no check.
        let current = AgentCLIDoctorChecks.checks(facts(remoteHosts: [
            host([claudeCurrent, vibeCurrent, .init(label: "quiet", agent: .claude, shimVersion: nil)]),
        ]))
        XCTAssertFalse(current.contains { $0.id == "remote-sessions.1" })

        // A pre-1.10.0 shim sends no header at all.
        let headerless = AgentCLIDoctorChecks.checks(facts(remoteHosts: [
            host([.init(label: "ancient", agent: .claude, shimVersion: .headerAbsent)]),
        ]))
        XCTAssertEqual(headerless.first { $0.id == "remote-sessions.1" }?.lines, [
            "ancient, Claude Code: plugin 1.9.0 or older; the host has 1.25.0.",
        ])

        // The host's own doctor gets its sessions too.
        XCTAssertEqual(
            AgentCLIDoctorChecks.hostChecks(facts(remoteHosts: [host([claudeBehind])]), hostIndex: 0).map(\.id).suffix(3),
            ["remote-host", "remote-sessions", "last-join"]
        )
    }

    func testTheJoinCheckListsTheLastFiveDictationsMostRecentFirst() {
        let joins = (0..<7).map { index in
            AgentCLIDoctorFacts.JoinLine(at: now.addingTimeInterval(-Double(index) * 60), line: "arm=tty line\(index)")
        }
        let check = AgentCLIDoctorChecks.checks(facts(recentJoins: joins)).first { $0.id == "last-join" }
        XCTAssertEqual(check?.state, .ok)
        XCTAssertEqual(check?.lines, (0..<5).map { "\($0) min ago: arm=tty line\($0)" })
    }

    /// A remote host gets no path, no other host and nothing about this
    /// Mac's agents.
    func testAHostGetsOnlyItsOwnHostSafeChecks() {
        let all = facts(
            speech: .managed(.failed(summary: "Model missing at /Users/me/models/x", detail: "stderr")),
            remoteHosts: [
                .init(label: "devbox", lastSeenAt: nil, pluginNeedsUpdate: false, keepsTunnelOpen: true),
                .init(label: "gpu", lastSeenAt: now, pluginNeedsUpdate: false),
            ]
        )
        let checks = AgentCLIDoctorChecks.hostChecks(all, hostIndex: 0)
        XCTAssertEqual(checks.map(\.id), [
            "app", "microphone", "accessibility", "speech", "polish", "remote-host", "last-join",
        ])
        let text = AgentCLIDoctor(checks: checks).textLines().joined(separator: "\n")
        XCTAssertFalse(text.contains("/Users"), text)
        XCTAssertFalse(text.contains("/Applications"), text)
        XCTAssertFalse(text.contains("gpu"), text)
        XCTAssertEqual(checks.first { $0.id == "remote-host" }?.fix, AgentCLIDoctorChecks.keepTunnelOpenHostFixFromHost)
        XCTAssertEqual(
            AgentCLIDoctorChecks.hostChecks(all, hostIndex: nil).map(\.id),
            ["app", "microphone", "accessibility", "speech", "polish", "last-join"]
        )
    }

    func testDoctorAnswersThroughTheServiceAndPrintsNumberedChecks() async throws {
        var state = FixtureAgentCLIDataSource.State()
        state.doctorFacts = AgentCLIDoctorFacts(
            appVersion: "1.4.0", microphone: .granted, accessibilityTrusted: false, speech: .managed(.ready),
            polish: .off, claudePlugin: nil, remoteHosts: [], recentJoins: [], now: now
        )
        let service = AgentCLIService(source: FixtureAgentCLIDataSource(state))

        let invocation = try XCTUnwrap({
            if case .run(let invocation) = AgentCLIArguments(
                now: now, timeZone: utc, workingDirectory: "/", environment: [:]
            ).parse(["doctor"]) { return invocation }
            return nil
        }())
        let response = await service.respond(to: invocation.request)
        let line = try XCTUnwrap(AgentCLIWire.encodeLine(response))
        let decoded = try XCTUnwrap(AgentCLIWire.decodeResponse(line))
        XCTAssertEqual(decoded.doctor?.checks.count, 8)

        let outcome = AgentCLIRunner(transport: { _ in .success(line) }, timeZone: utc).run(invocation)
        XCTAssertEqual(outcome.exitCode, .checkFailed)
        XCTAssertEqual(outcome.stdout, """
            1. [ok  ] App: localvoxtral 1.4.0.
            2. [ok  ] Microphone: Allowed.
            3. [FAIL] Accessibility: Not allowed, so text cannot be inserted.
               fix: System Settings > Privacy & Security > Accessibility: turn localvoxtral off, then on. \
            A copy with another signature loses the grant without saying so.
            4. [ok  ] Speech engine: On this Mac, ready.
            5. [--  ] Polish engine: Off.
            6. [--  ] Claude Code plugin: Not checked.
            7. [--  ] Remote hosts: None enrolled.
            8. [--  ] Last dictation's session: Nothing dictated since launch.

            1 failed, 0 to look at.

            """)
    }

    func testAWarningAloneExitsZero() {
        let doctor = AgentCLIDoctor(checks: [AgentCLICheck(id: "x", title: "X", state: .warning, detail: "d", fix: "f")])
        let line = AgentCLIWire.encodeLine(AgentCLIResponse(doctor: doctor))
        let invocation = AgentCLIInvocation(request: AgentCLIRequest(command: .doctor), json: true)
        let outcome = AgentCLIRunner(transport: { _ in .success(line) }, timeZone: utc).run(invocation)
        XCTAssertEqual(outcome.exitCode, .answered)
    }

    func testDoctorTakesNoOptions() {
        let arguments = AgentCLIArguments(now: now, timeZone: .current, workingDirectory: "/", environment: [:])
        XCTAssertEqual(arguments.parse(["doctor", "--project", "."]), .usageError("--project does not apply to doctor"))
        XCTAssertEqual(arguments.parse(["doctor", "extra"]), .usageError("unexpected argument: extra"))
        XCTAssertEqual(arguments.parse(["doctor", "--join"]), .usageError("--join applies to logs only"))
    }

    // MARK: - logs

    func testLogsReadsTheJoinLinesSinceAWindowWithoutTheApp() {
        let arguments = AgentCLIArguments(now: now, timeZone: utc, workingDirectory: "/", environment: [:])
        XCTAssertEqual(
            arguments.parse(["logs", "--join", "--since", "2h", "--json"]),
            .logs(AgentCLILogsQuery(joinOnly: true, since: now.addingTimeInterval(-7_200), json: true))
        )
        XCTAssertEqual(
            arguments.parse(["logs"]),
            .logs(AgentCLILogsQuery(joinOnly: false, since: now.addingTimeInterval(-3_600), json: false))
        )
        XCTAssertEqual(arguments.parse(["logs", "--limit", "3"]), .usageError("--limit does not apply to logs"))

        let query = AgentCLILogsQuery(joinOnly: true, since: now, json: false)
        XCTAssertEqual(query.logShowArguments(timeZone: utc), [
            "show", "--style", "ndjson", "--start", "2026-09-21 14:13:20", "--predicate",
            #"subsystem == "com.localvoxtral" AND eventMessage BEGINSWITH "Claude join outcome: ""#,
        ])
        XCTAssertEqual(
            AgentCLILogsQuery(joinOnly: false, since: now, json: false).predicate,
            #"subsystem == "com.localvoxtral" AND (eventMessage BEGINSWITH "Claude join outcome: " "#
                + "OR messageType == error OR messageType == fault)"
        )
    }

    func testLogsParsesNdjsonAndSkipsWhatIsNotAnEntry() {
        let output = Data("""
            {"timestamp":"2026-09-21 16:13:20.000000+0200","messageType":"Default","category":"ClaudeContext","eventMessage":"Claude join outcome: arm=tty origin=local causes=none"}
            {"timestamp":"2026-09-21 16:14:20+0200","messageType":"Error","category":"Backends","eventMessage":"Speech engine failed: <private>"}
            {"timestamp":"2026-09-21 16:15:20.000000+02:00","messageType":"Fault","category":"Backends","eventMessage":"x"}
            {"count":3,"finished":1}
            not json
            """.utf8)
        let lines = AgentCLILogs.parse(output)
        XCTAssertEqual(lines.map(\.level), ["notice", "error", "fault"])
        XCTAssertEqual(lines.first?.at, now)
        XCTAssertEqual(lines.last?.at, now.addingTimeInterval(120))
        let outcome = AgentCLILogs.run(
            AgentCLILogsQuery(joinOnly: false, since: now, json: false), timeZone: utc,
            readLog: { _ in .success(output) }
        )
        XCTAssertEqual(outcome.exitCode, .answered)
        XCTAssertEqual(outcome.stdout, """
            2026-09-21 14:13:20 [ClaudeContext] Claude join outcome: arm=tty origin=local causes=none
            2026-09-21 14:14:20 [Backends] error: Speech engine failed: <private>
            2026-09-21 14:15:20 [Backends] fault: x

            """)
        let failed = AgentCLILogs.run(
            AgentCLILogsQuery(joinOnly: true, since: now, json: false), timeZone: utc,
            readLog: { _ in .failure(AgentCLILogsReadFailure("/usr/bin/log exited with 64")) }
        )
        XCTAssertEqual(failed.exitCode, .refused)
        XCTAssertEqual(failed.stderr, "localvoxtral: could not read the log: /usr/bin/log exited with 64\n")
    }

    func testFailureLogReadsTheFailuresCategoriesAtEveryDefaultLevel() {
        let query = AgentCLIFailureLogQuery(categories: ["Polishing", "Backends"], since: now)
        XCTAssertEqual(query.logShowArguments(timeZone: utc), [
            "show", "--style", "ndjson", "--start", "2026-09-21 14:13:20", "--predicate",
            #"subsystem == "com.localvoxtral" AND category IN {"Polishing", "Backends"}"#,
        ])
        let output = Data("""
            {"timestamp":"2026-09-21 16:13:20.000000+0200","messageType":"Default","category":"Polishing","eventMessage":"request sent"}
            {"timestamp":"2026-09-21 16:14:20.000000+0200","messageType":"Error","category":"Polishing","eventMessage":"timed out: <private>"}
            """.utf8)
        var asked: [String] = []
        let read = AgentCLILogs.failureLog(query, timeZone: utc) { arguments in
            asked = arguments
            return .success(output)
        }
        XCTAssertEqual(asked, query.logShowArguments(timeZone: utc))
        XCTAssertEqual(read, .success("""
            2026-09-21 14:13:20 [Polishing] request sent
            2026-09-21 14:14:20 [Polishing] error: timed out: <private>

            """))
        XCTAssertEqual(
            AgentCLILogs.failureLog(query, timeZone: utc) { _ in .failure(AgentCLILogsReadFailure("/usr/bin/log exited with 64")) },
            .failure(AgentCLILogsReadFailure("/usr/bin/log exited with 64"))
        )
    }
}
