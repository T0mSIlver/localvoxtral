import ClaudeContextWire
import Foundation
@testable import LocalvoxtralCLICore
import XCTest
import localvoxtralTestSupport

@testable import localvoxtralCore

/// `localvoxtral doctor`: every check that is not fine names its fix.
final class AgentCLIDoctorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func facts(
        microphone: AgentCLIDoctorFacts.Permission = .granted,
        accessibilityTrusted: Bool = true,
        speech: AgentCLIDoctorFacts.Engine = .managed(.ready),
        polish: AgentCLIDoctorFacts.Engine = .mistralAPI(keySet: true),
        claudePlugin: ClaudePluginStatus? = .installed(version: "2.4.0"),
        remoteHosts: [AgentCLIDoctorFacts.RemoteHost] = [],
        lastJoinLine: String? = "arm=tty origin=local causes=none"
    ) -> AgentCLIDoctorFacts {
        AgentCLIDoctorFacts(
            microphone: microphone,
            accessibilityTrusted: accessibilityTrusted,
            speech: speech,
            polish: polish,
            claudePlugin: claudePlugin,
            remoteHosts: remoteHosts,
            lastJoinLine: lastJoinLine,
            now: now
        )
    }

    func testAHealthySetupHasNothingToFix() {
        let checks = AgentCLIDoctorChecks.checks(facts(remoteHosts: [
            .init(label: "devbox", sshHostAlias: "devbox", lastSeenAt: now.addingTimeInterval(-600), pluginNeedsUpdate: false),
        ]))
        XCTAssertEqual(checks.map(\.id), [
            "microphone", "accessibility", "speech", "polish", "claude-plugin", "remote-host.1", "last-join",
        ])
        XCTAssertEqual(checks.filter { $0.state != .ok }.map(\.id), [])
        XCTAssertEqual(checks.first { $0.id == "remote-host.1" }?.detail, "Last context 10 min ago.")
    }

    func testEachFieldProblemFailsItsCheckWithAFix() {
        let checks = AgentCLIDoctorChecks.checks(facts(
            microphone: .denied,
            accessibilityTrusted: false,
            speech: .managed(.failed(summary: "The speech engine exited.", detail: "stderr")),
            polish: .mistralAPI(keySet: false),
            claudePlugin: .updateAvailable(installed: "2.3.0", bundled: "2.4.0"),
            remoteHosts: [
                .init(label: "devbox", sshHostAlias: "devbox", lastSeenAt: nil, pluginNeedsUpdate: false),
                .init(label: "gpu", sshHostAlias: "gpu", lastSeenAt: now, pluginNeedsUpdate: true),
                .init(label: "old", sshHostAlias: "old", lastSeenAt: now, pluginNeedsUpdate: false,
                      forwardFailure: "Host key changed."),
            ],
            lastJoinLine: "arm=none origin=none causes=tty: no live session on this device"
        ))
        let states = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0.state) })
        XCTAssertEqual(states, [
            "microphone": .failed,
            "accessibility": .failed,
            "speech": .failed,
            "polish": .failed,
            "claude-plugin": .warning,
            "remote-host.1": .warning,
            "remote-host.2": .warning,
            "remote-host.3": .failed,
            "last-join": .warning,
        ])
        XCTAssertEqual(checks.filter { $0.fix == nil }.map(\.id), [])
        // The engine's stderr stays out: only its one-line summary is shown.
        XCTAssertFalse(checks.contains { $0.detail.contains("stderr") })
        XCTAssertEqual(
            checks.first { $0.id == "remote-host.3" }?.fix,
            "Run `ssh old true` in a terminal to see ssh's own error."
        )
    }

    func testDoctorAnswersThroughTheServiceAndPrintsNumberedChecks() async throws {
        var state = FixtureAgentCLIDataSource.State()
        state.doctorFacts = facts(accessibilityTrusted: false, polish: .off, claudePlugin: nil, lastJoinLine: nil)
        let service = AgentCLIService(source: FixtureAgentCLIDataSource(state))

        let request = try XCTUnwrap({
            if case .run(let invocation) = AgentCLIArguments(
                now: now, timeZone: TimeZone(identifier: "UTC")!, workingDirectory: "/", environment: [:]
            ).parse(["doctor"]) { return invocation.request }
            return nil
        }())
        let response = await service.respond(to: request)
        let line = try XCTUnwrap(AgentCLIWire.encodeLine(response))
        let decoded = try XCTUnwrap(AgentCLIWire.decodeResponse(line))
        XCTAssertEqual(decoded.doctor?.checks.count, 7)

        XCTAssertEqual(AgentCLIText(timeZone: TimeZone(identifier: "UTC")!).render(decoded), """
            1. [ok  ] Microphone: Allowed.
            2. [FAIL] Accessibility: Not allowed, so text cannot be inserted.
               fix: System Settings > Privacy & Security > Accessibility: turn localvoxtral off, then on. \
            A copy with another signature loses the grant without saying so.
            3. [ok  ] Speech engine: On this Mac, ready.
            4. [--  ] Polish engine: Off.
            5. [--  ] Claude Code plugin: Not checked.
            6. [--  ] Remote hosts: None enrolled.
            7. [--  ] Last dictation's session: Nothing dictated since launch.

            1 failed, 0 to look at.

            """)
    }

    func testDoctorTakesNoOptions() {
        let arguments = AgentCLIArguments(now: now, timeZone: .current, workingDirectory: "/", environment: [:])
        XCTAssertEqual(arguments.parse(["doctor", "--project", "."]), .usageError("--project does not apply to doctor"))
        XCTAssertEqual(arguments.parse(["doctor", "extra"]), .usageError("unexpected argument: extra"))
    }
}
