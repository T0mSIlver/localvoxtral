import Foundation
import XCTest
@testable import localvoxtral

// MARK: - Install/uninstall goes through Claude Code's CLI

final class ClaudePluginInstallServiceArgumentsTests: XCTestCase {
    private let path = "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace"

    private func arguments(_ action: ClaudePluginInstallService.Action) -> [String] {
        ClaudePluginInstallService.arguments(for: action, marketplacePath: path)
    }

    func testPluginReferenceIsFullyQualified() {
        XCTAssertEqual(ClaudePluginInstallService.pluginReference, "localvoxtral@localvoxtral")
    }

    func testAddMarketplaceCommand() {
        XCTAssertEqual(arguments(.addMarketplace), ["plugin", "marketplace", "add", path])
    }

    func testInstallCommand() {
        XCTAssertEqual(arguments(.install), ["plugin", "install", "localvoxtral@localvoxtral"])
    }

    // MARK: publisher_path userConfig

    func testInstallPassesPublisherPathAsUserConfig() {
        // This is what makes the plugin work for an app outside /Applications:
        // the shim reads it back as CLAUDE_PLUGIN_OPTION_PUBLISHER_PATH.
        XCTAssertEqual(
            ClaudePluginInstallService.arguments(
                for: .install,
                marketplacePath: path,
                publisherPath: "/Volumes/Dev/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook"
            ),
            [
                "plugin", "install", "localvoxtral@localvoxtral",
                "--config",
                "publisher_path=/Volumes/Dev/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook",
            ]
        )
    }

    func testAbsentPublisherPathAddsNoConfigArguments() {
        // Nothing to say is better than `--config publisher_path=` — an empty
        // value would override the shim's own search with a dead path.
        XCTAssertEqual(
            ClaudePluginInstallService.arguments(for: .install, marketplacePath: path, publisherPath: nil),
            ["plugin", "install", "localvoxtral@localvoxtral"]
        )
        XCTAssertEqual(
            ClaudePluginInstallService.arguments(for: .install, marketplacePath: path, publisherPath: ""),
            ["plugin", "install", "localvoxtral@localvoxtral"]
        )
    }

    func testUninstallCarriesNoPublisherConfig() {
        XCTAssertEqual(
            ClaudePluginInstallService.arguments(
                for: .uninstall, marketplacePath: path, publisherPath: "/A/hook"
            ),
            ["plugin", "uninstall", "localvoxtral@localvoxtral"]
        )
    }

    func testConfigKeyMatchesTheEnvironmentVariableTheShimReads() {
        // CLAUDE_PLUGIN_OPTION_<KEY>. The manifest test pins the other half.
        XCTAssertEqual(ClaudePluginInstallService.publisherPathConfigKey, "publisher_path")
    }

    func testUninstallCommand() {
        XCTAssertEqual(arguments(.uninstall), ["plugin", "uninstall", "localvoxtral@localvoxtral"])
    }

    func testRemoveMarketplaceCommand() {
        XCTAssertEqual(arguments(.removeMarketplace), ["plugin", "marketplace", "remove", "localvoxtral"])
    }

    func testEveryCommandTargetsOnlyOurOwnPlugin() {
        // A qualified reference is what keeps `uninstall` from ever matching a
        // same-named plugin from someone else's marketplace.
        for action: ClaudePluginInstallService.Action in [.install, .uninstall] {
            XCTAssertTrue(arguments(action).contains("localvoxtral@localvoxtral"))
        }
    }

    func testNoCommandEverTouchesSettingsJSON() {
        // The load-bearing rule: settings.json is the user's and Claude Code
        // owns its schema. We drive the CLI; we never write that file.
        let actions: [ClaudePluginInstallService.Action] = [
            .addMarketplace, .install, .uninstall, .removeMarketplace,
        ]
        for action in actions {
            for argument in arguments(action) {
                XCTAssertFalse(argument.contains("settings.json"), "\(action) must not name settings.json")
                XCTAssertFalse(argument.contains(".claude/settings"), "\(action) must not touch user settings")
            }
        }
    }
}

// MARK: - Service behaviour

/// Records invocations instead of spawning `claude`.
private final class RecordingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invocations: [ClaudePluginInstallService.Invocation] = []
    var result: ClaudePluginInstallService.RunResult = .init(exitCode: 0, message: "ok")
    /// When set, wins over `result` — lets one step in a flow fail while the
    /// others succeed.
    var resultFor: ((ClaudePluginInstallService.Invocation) -> ClaudePluginInstallService.RunResult)?

    var runner: ClaudePluginInstallService.Runner {
        { [self] invocation in
            lock.lock()
            invocations.append(invocation)
            let result = self.resultFor?(invocation) ?? self.result
            lock.unlock()
            return result
        }
    }

    var argumentLists: [[String]] { invocations.map(\.arguments) }
}

final class ClaudePluginInstallServiceTests: XCTestCase {
    private let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
    private let marketplace = URL(fileURLWithPath: "/Apps/localvoxtral.app/Contents/Resources/claude-code-marketplace")

    private func makeService(
        runner: RecordingRunner,
        publisherURL: URL? = nil
    ) -> ClaudePluginInstallService {
        ClaudePluginInstallService(
            claudeExecutableURL: claude,
            marketplaceURL: marketplace,
            publisherURL: publisherURL,
            runner: runner.runner
        )
    }

    func testServiceThreadsItsPublisherURLIntoTheInstallCommand() throws {
        let runner = RecordingRunner()
        let publisher = URL(fileURLWithPath: "/Users/me/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook")
        try makeService(runner: runner, publisherURL: publisher).installPlugin()
        XCTAssertEqual(runner.argumentLists, [
            ["plugin", "marketplace", "add", marketplace.path],
            ["plugin", "install", "localvoxtral@localvoxtral", "--config", "publisher_path=\(publisher.path)"],
        ])
    }

    func testInstallRegistersMarketplaceThenInstalls() throws {
        let runner = RecordingRunner()
        try makeService(runner: runner).installPlugin()
        XCTAssertEqual(runner.argumentLists, [
            ["plugin", "marketplace", "add", marketplace.path],
            ["plugin", "install", "localvoxtral@localvoxtral"],
        ])
    }

    func testUpdateReinstallsAndNeverRunsThePluginUpdateVerb() throws {
        // Field bug from the #150 hand test: `claude plugin update --config …`
        // fails with "unknown option '--config'" (probed on Claude Code
        // 2.1.212), and an update WITHOUT --config leaves a stale
        // publisher_path, which the shim silently skips — every hook dies for
        // an app outside /Applications. Update is therefore marketplace
        // refresh + uninstall + install.
        let runner = RecordingRunner()
        let publisher = URL(fileURLWithPath: "/A/hook")
        try makeService(runner: runner, publisherURL: publisher).updatePlugin()
        XCTAssertEqual(runner.argumentLists, [
            ["plugin", "marketplace", "add", marketplace.path],
            ["plugin", "uninstall", "localvoxtral@localvoxtral"],
            ["plugin", "install", "localvoxtral@localvoxtral", "--config", "publisher_path=/A/hook"],
        ])
    }

    func testUpdateToleratesUninstallFailureSoTheFirstPressInstalls() throws {
        // The "Install or Update" button's first-ever press has nothing to
        // uninstall (the CLI exits 1 for that); the flow must carry on to
        // install rather than surface the error.
        let runner = RecordingRunner()
        runner.resultFor = { invocation in
            invocation.arguments.first == "plugin" && invocation.arguments[1] == "uninstall"
                ? .init(exitCode: 1, message: "Plugin \"localvoxtral\" is not installed")
                : .init(exitCode: 0, message: "ok")
        }
        try makeService(runner: runner).updatePlugin()
        XCTAssertEqual(runner.argumentLists.last, ["plugin", "install", "localvoxtral@localvoxtral"])
    }

    func testUninstallRemovesPluginThenMarketplace() throws {
        let runner = RecordingRunner()
        try makeService(runner: runner).uninstallPlugin()
        XCTAssertEqual(runner.argumentLists, [
            ["plugin", "uninstall", "localvoxtral@localvoxtral"],
            ["plugin", "marketplace", "remove", "localvoxtral"],
        ])
    }

    func testNothingRunsWithoutAnExplicitCall() {
        // Constructing the service must never install anything: putting a
        // plugin into someone's Claude Code is their decision.
        let runner = RecordingRunner()
        _ = makeService(runner: runner)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testMissingCLIIsReportedAndRunsNothing() {
        let runner = RecordingRunner()
        let service = ClaudePluginInstallService(
            claudeExecutableURL: nil, marketplaceURL: marketplace, runner: runner.runner
        )
        XCTAssertThrowsError(try service.installPlugin()) { error in
            XCTAssertEqual(error as? ClaudePluginInstallService.ServiceError, .claudeCLINotFound)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testMissingMarketplaceIsReportedAndRunsNothing() {
        let runner = RecordingRunner()
        let service = ClaudePluginInstallService(
            claudeExecutableURL: claude, marketplaceURL: nil, runner: runner.runner
        )
        XCTAssertThrowsError(try service.installPlugin()) { error in
            XCTAssertEqual(error as? ClaudePluginInstallService.ServiceError, .marketplaceUnavailable)
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testFailedCommandSurfacesExitCodeAndMessage() {
        let runner = RecordingRunner()
        runner.result = .init(exitCode: 3, message: "marketplace not found")
        XCTAssertThrowsError(try makeService(runner: runner).perform(.install)) { error in
            XCTAssertEqual(
                error as? ClaudePluginInstallService.ServiceError,
                .commandFailed(action: .install, exitCode: 3, message: "marketplace not found")
            )
        }
    }

    func testInstallStopsAtTheFirstFailure() {
        // If registering the marketplace failed, installing from it cannot work
        // — running it anyway would only produce a more confusing error.
        let runner = RecordingRunner()
        runner.result = .init(exitCode: 1, message: "boom")
        XCTAssertThrowsError(try makeService(runner: runner).installPlugin())
        XCTAssertEqual(runner.argumentLists, [["plugin", "marketplace", "add", marketplace.path]])
    }

    func testRunResultSuccessPredicate() {
        XCTAssertTrue(ClaudePluginInstallService.RunResult(exitCode: 0, message: "").succeeded)
        XCTAssertFalse(ClaudePluginInstallService.RunResult(exitCode: 1, message: "").succeeded)
    }

    // MARK: Bounded teardown
    //
    // Every seam is injected, so these prove the escalation ordering without a
    // process and without a clock: no signals are sent, no time passes.

    /// Records the teardown steps in the order they were taken.
    private func recordTeardown(
        gracePeriod: TimeInterval = 2,
        exitsAfterWait: Int?
    ) -> (outcome: ClaudePluginInstallService.TerminationOutcome, steps: [String], windows: [TimeInterval]) {
        var steps: [String] = []
        var windows: [TimeInterval] = []
        var waits = 0
        let outcome = ClaudePluginInstallService.terminateBounded(
            gracePeriod: gracePeriod,
            terminate: { steps.append("terminate") },
            kill: { steps.append("kill") },
            waitForExit: { window in
                waits += 1
                steps.append("wait")
                windows.append(window)
                return waits == exitsAfterWait
            }
        )
        return (outcome, steps, windows)
    }

    func testTeardownStopsAtSIGTERMWhenTheChildHonoursIt() {
        // A well-behaved CLI must never be killed: SIGTERM lets it clean up.
        let run = recordTeardown(exitsAfterWait: 1)
        XCTAssertEqual(run.outcome, .exitedOnTerminate)
        XCTAssertEqual(run.steps, ["terminate", "wait"])
        XCTAssertFalse(run.steps.contains("kill"))
    }

    func testTeardownEscalatesToSIGKILLWhenSIGTERMIsIgnored() {
        // The regression this guards: SIGTERM is advisory, so the wait after it
        // is a grace period. Waiting on a TERM-ignoring child forever is how the
        // runner used to wedge the app.
        let run = recordTeardown(gracePeriod: 0.25, exitsAfterWait: 2)
        XCTAssertEqual(run.outcome, .killed)
        XCTAssertEqual(run.steps, ["terminate", "wait", "kill", "wait"])
        XCTAssertEqual(run.windows, [0.25, 0.25], "both waits are bounded by the grace period")
    }

    func testTeardownGivesUpRatherThanWaitingForeverOnAChildThatSurvivesSIGKILL() {
        // Uninterruptible sleep. Nothing we can send helps, so the one thing
        // that must not happen is blocking the caller indefinitely.
        let run = recordTeardown(exitsAfterWait: nil)
        XCTAssertEqual(run.outcome, .abandonedAfterKill)
        XCTAssertEqual(run.steps, ["terminate", "wait", "kill", "wait"], "exactly two bounded waits, then return")
    }

    #if canImport(Darwin)
    // MARK: CLI discovery
    //
    // `isExecutable` is injected throughout: the build host HAS Claude Code
    // installed, so a probe against the real filesystem would pass or fail by
    // accident rather than by logic.

    func testCandidatesCoverTheUsualInstallLocations() {
        let candidates = ClaudePluginInstallService.claudeCLICandidates(
            environment: ["HOME": "/Users/tester", "PATH": "/opt/bin:/usr/bin"]
        )
        XCTAssertEqual(candidates, [
            "/Users/tester/.claude/local/claude",
            "/Users/tester/.local/bin/claude",
            "/opt/bin/claude",
            "/usr/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ])
    }

    func testCandidatesTolerateMissingHomeAndPath() {
        let candidates = ClaudePluginInstallService.claudeCLICandidates(environment: [:])
        XCTAssertEqual(candidates, ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }

    func testLocateReturnsFirstExecutableCandidateInProbeOrder() {
        let located = ClaudePluginInstallService.locateClaudeCLI(
            environment: ["HOME": "/Users/tester", "PATH": "/opt/bin"],
            isExecutable: { $0 == "/opt/bin/claude" || $0 == "/usr/local/bin/claude" }
        )
        XCTAssertEqual(located?.path, "/opt/bin/claude", "PATH must win over the fixed fallbacks")
    }

    func testLocatePrefersUserInstallOverPath() {
        let located = ClaudePluginInstallService.locateClaudeCLI(
            environment: ["HOME": "/Users/tester", "PATH": "/opt/bin"],
            isExecutable: { _ in true }
        )
        XCTAssertEqual(located?.path, "/Users/tester/.claude/local/claude")
    }

    func testLocateReturnsNilWhenNothingIsExecutable() {
        let located = ClaudePluginInstallService.locateClaudeCLI(
            environment: ["HOME": "/Users/tester", "PATH": "/opt/bin"],
            isExecutable: { _ in false }
        )
        XCTAssertNil(located)
    }

    // MARK: Subprocess runner — real child processes

    func testProcessRunnerCapturesOutputAndExitCode() throws {
        let runner = ClaudePluginInstallService.processRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh")
        )
        let result = try runner(.init(arguments: ["-c", "echo hello; exit 3"]))
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.message, "hello")
        XCTAssertFalse(result.succeeded)
    }

    func testProcessRunnerMergesStderr() throws {
        let runner = ClaudePluginInstallService.processRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh")
        )
        let result = try runner(.init(arguments: ["-c", "echo oops >&2; exit 1"]))
        XCTAssertEqual(result.message, "oops")
    }

    /// A `claude` that hangs — on a network fetch, or a prompt we did not
    /// anticipate — must not wedge the app. Before the timeout, the drain
    /// blocked until the child closed the pipe, which for a silent hang is
    /// never.
    func testProcessRunnerTerminatesAChildThatHangsSilently() {
        let runner = ClaudePluginInstallService.processRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeout: 0.5
        )
        // Writes nothing and never exits: the exact shape a deadline-between-
        // chunks check cannot catch.
        XCTAssertThrowsError(try runner(.init(arguments: ["-c", "sleep 30"]))) { error in
            guard case .commandTimedOut(_, _, let seconds)? = error as? ClaudePluginInstallService.ServiceError else {
                return XCTFail("expected .commandTimedOut, got \(error)")
            }
            XCTAssertEqual(seconds, 0.5)
        }
    }

    /// A verbose-but-healthy CLI that overruns the capture cap must be reported
    /// as an overrun, NOT as a timeout. Before the fix both paths set the same
    /// `timedOut` flag and threw `.commandTimedOut`, so a chatty command looked
    /// exactly like a wedged one.
    func testProcessRunnerReportsOutputOverrunDistinctlyFromATimeout() {
        let runner = ClaudePluginInstallService.processRunner(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            timeout: 5
        )
        // `cat /dev/zero` streams without end and overruns the 64 KiB cap almost
        // immediately — it is not hanging, it is producing too much. The
        // generous timeout proves the cap fires first: a broken cap would stall
        // until the deadline and throw `.commandTimedOut` instead.
        XCTAssertThrowsError(try runner(.init(arguments: ["/dev/zero"]))) { error in
            guard case .outputTooLarge(_, let capBytes)? = error as? ClaudePluginInstallService.ServiceError else {
                return XCTFail("expected .outputTooLarge, got \(error)")
            }
            XCTAssertEqual(capBytes, ClaudePluginInstallService.maxCapturedOutputBytes)
        }
    }

    func testProcessRunnerDoesNotHangOnAChildHoldingThePipeOpen() throws {
        // A child that exits but leaves a grandchild holding the write end.
        // EOF never arrives, so only the deadline ends this.
        let runner = ClaudePluginInstallService.processRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeout: 0.5
        )
        XCTAssertThrowsError(try runner(.init(arguments: ["-c", "sleep 30 & exit 0"])))
    }

    func testProcessRunnerStdinIsNullSoAPromptCannotBlock() throws {
        let runner = ClaudePluginInstallService.processRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeout: 5
        )
        // Reading stdin gets EOF immediately rather than waiting for a TTY.
        let result = try runner(.init(arguments: ["-c", "cat; echo done"]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.message, "done")
    }
    #endif
}
