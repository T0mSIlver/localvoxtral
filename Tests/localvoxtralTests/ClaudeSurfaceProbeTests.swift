import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// Test clock — the registry never reads the wall clock itself (AGENTS: no
/// wall-clock in tests), and the probe under test never reads one at all.
private final class ProbeTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
}

private final class ProbeTestLiveness: Sendable {
    private let dead: Mutex<Set<Int32>> = Mutex([])
    var probe: @Sendable (Int32) -> Bool { { [self] pid in dead.withLock { !$0.contains(pid) } } }
}

private final class ProbeTestMarkers: Sendable {
    private let queue: Mutex<[String]>
    init(_ values: [String]) { queue = Mutex(values) }
    var allocate: @Sendable () -> String {
        { [self] in queue.withLock { $0.isEmpty ? "lvx-exhausted" : $0.removeFirst() } }
    }
}

private struct ProbeTestHerdrPanes: HerdrPaneQuerying {
    var focused: HerdrFocusedPane?
    var foreground: HerdrPaneForegroundInfo?

    func focusedPane(socketPath _: String) async -> HerdrFocusedPane? { focused }

    func paneForegroundInfo(
        socketPath _: String,
        paneID _: String
    ) async -> HerdrPaneForegroundInfo? { foreground }

    func paneVisibleText(socketPath _: String, paneID _: String) async -> String? { nil }
}

/// `--probe-surface`: the read-only verb that answers "which arm would this
/// surface join on, and if none, where did it stop?".
///
/// The asymmetry these tests defend is different from the join's own. A wrong
/// join poisons a prompt; a wrong PROBE sends whoever is debugging in the wrong
/// direction, and the expensive failure is a probe whose silence about the
/// permission it lacks reads as "the surface is fine". So every refusal the
/// probe makes before the resolver runs has to arrive as a named cause, and the
/// causes the resolver itself produces have to reach the output unchanged.
@MainActor
final class ClaudeSurfaceProbeTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let ghostty = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )

    // MARK: - Fixtures

    private func record(
        session: String = "s1",
        claudePID: Int32? = 9001,
        tty: String? = nil,
        herdrPaneID: String? = nil,
        herdrSocketPath: String? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .sessionStart,
            sessionID: session,
            timestamp: 0,
            rawCwd: "/repo",
            prompt: nil,
            files: [],
            process: claudePID.map {
                ClaudeHookProcessInfo(
                    hookPID: 777,
                    claudePID: $0,
                    tty: tty,
                    herdrPaneID: herdrPaneID,
                    herdrSocketPath: herdrSocketPath
                )
            }
        )
    }

    /// Every seam injected, always: a registry on the DEFAULT liveness probe
    /// would run a real `kill(pid, 0)` against whatever holds that pid on the
    /// host, which is the live-host-state flake class this repo pins seams for.
    private func makeRegistry(markers: [String] = ["lvx-abcd"]) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            limits: .default,
            now: ProbeTestClock(epoch).now,
            isProcessAlive: ProbeTestLiveness().probe,
            allocateMarkerValue: ProbeTestMarkers(markers).allocate
        )
    }

    private func resolver(
        registry: ClaudeSessionRegistry,
        focusedTTY: String? = nil,
        herdrClient: Bool = false,
        herdrPanes: HerdrPaneQuerying? = nil
    ) -> ClaudeSessionJoinResolver {
        ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in nil },
            focusedTerminalTTY: { _ in focusedTTY },
            focusedWindowID: { _ in 101 },
            herdrClientProbe: { _ in herdrClient },
            herdrPanes: herdrPanes
        )
    }

    // MARK: - Argument parsing

    func testVerbIsOnlyRecognizedWhenAskedFor() {
        XCTAssertEqual(
            ClaudeSurfaceProbe.invocation(arguments: ["/usr/bin/localvoxtral"]),
            .notRequested,
            "a normal launch must reach the app, not the probe"
        )
        XCTAssertEqual(
            ClaudeSurfaceProbe.invocation(arguments: ["localvoxtral", "--probe-surface"]),
            .run(ClaudeSurfaceProbe.Options(json: false))
        )
        XCTAssertEqual(
            ClaudeSurfaceProbe.invocation(arguments: ["localvoxtral", "--probe-surface", "--json"]),
            .run(ClaudeSurfaceProbe.Options(json: true))
        )
        XCTAssertEqual(
            ClaudeSurfaceProbe.invocation(arguments: ["localvoxtral", "--json", "--probe-surface"]),
            .run(ClaudeSurfaceProbe.Options(json: true)),
            "flag order is not part of the contract"
        )
    }

    func testUnrecognizedOptionIsAUsageErrorRatherThanASilentDefault() {
        // A typo that fell through to a default would print a normal-looking
        // summary for something the caller did not ask for.
        guard case .usageError(let message) = ClaudeSurfaceProbe.invocation(
            arguments: ["localvoxtral", "--probe-surface", "--jsonn"]
        ) else {
            return XCTFail("an unknown option must not resolve to a runnable invocation")
        }
        XCTAssertTrue(message.contains("--jsonn"), "the message must name what it rejected")
    }

    func testArgumentZeroIsNeverParsedAsAnOption() {
        // An executable installed at a path that happens to contain the verb
        // must not turn every launch into a probe.
        XCTAssertEqual(
            ClaudeSurfaceProbe.invocation(arguments: ["/opt/--json/localvoxtral"]),
            .notRequested
        )
    }

    // MARK: - Refusals before the resolver runs

    func testMissingAccessibilityGrantIsANamedReasonAndSkipsTheResolve() async {
        let resolved = Mutex(false)
        let summary = await ClaudeSurfaceProbe.summarize(
            accessibilityTrusted: false,
            frontmostTarget: ghostty,
            hasLiveSessions: { true },
            resolve: { _ in
                resolved.withLock { $0 = true }
                return nil
            }
        )
        XCTAssertEqual(summary.arm, "none")
        XCTAssertEqual(
            summary.abstentionReason,
            ClaudeSurfaceProbe.ProbeAbstention.accessibilityNotGranted.rawValue
        )
        XCTAssertFalse(
            resolved.withLock { $0 },
            "without the grant the resolve would spend Apple events to reach abstentions that "
                + "all misattribute the missing permission to the arms"
        )
    }

    func testNoFrontmostApplicationIsANamedReason() async {
        let summary = await ClaudeSurfaceProbe.summarize(
            accessibilityTrusted: true,
            frontmostTarget: nil,
            hasLiveSessions: { true },
            resolve: { _ in XCTFail("nothing to resolve"); return nil }
        )
        XCTAssertEqual(summary.arm, "none")
        XCTAssertEqual(
            summary.abstentionReason,
            ClaudeSurfaceProbe.ProbeAbstention.noFrontmostApplication.rawValue
        )
    }

    func testUnsupportedFrontmostAppIsNamedRatherThanSilent() async {
        // VS Code is terminal-like for insertion and explicitly excluded from
        // joins. The resolver returns nil for it without noting a cause, and a
        // bare `arm: none` with no reason is the least useful diagnostic there
        // is — so the probe names it itself.
        let summary = await ClaudeSurfaceProbe.summarize(
            accessibilityTrusted: true,
            frontmostTarget: TerminalScreenTarget(pid: 900, bundleID: "com.microsoft.VSCode"),
            hasLiveSessions: { true },
            resolve: { _ in XCTFail("an unlisted bundle must not reach the resolver"); return nil }
        )
        XCTAssertEqual(summary.arm, "none")
        XCTAssertEqual(
            summary.abstentionReason,
            ClaudeSurfaceProbe.ProbeAbstention.unsupportedSurface.rawValue
        )
    }

    // MARK: - The resolver's own vocabulary reaches the output

    func testEmptyRegistryIsFramedBeforeTheArmsThatFailBecauseOfIt() async {
        // A one-shot process holds no hook records, so every arm declines for
        // the same reason. Noted FIRST so the chain cannot be misread as the
        // surface having failed.
        let registry = makeRegistry()
        let joinResolver = resolver(registry: registry, focusedTTY: "/dev/ttys003")
        let summary = await ClaudeSurfaceProbe.summarize(
            accessibilityTrusted: true,
            frontmostTarget: ghostty,
            hasLiveSessions: { registry.hasLiveSessions() },
            resolve: { await joinResolver.resolve(target: $0) }
        )
        XCTAssertEqual(summary.arm, "none")
        let reason = summary.abstentionReason ?? ""
        XCTAssertTrue(
            reason.hasPrefix(ClaudeSurfaceProbe.ProbeAbstention.noLiveSessions.rawValue),
            "expected the empty-registry frame first, got \(reason)"
        )
        XCTAssertTrue(
            reason.contains("tty: no live session on this device"),
            "the tty arm's own cause must survive verbatim, not be re-worded by the probe: \(reason)"
        )
    }

    func testAbstentionCausesAreOrderedOldestFirstAcrossArms() async {
        // One session on another device: the tty arm declines, the remote-herdr
        // arm finds nothing it can read, then the marker arm declines. All
        // three, in that order — the ORDER is what tells a reader how far the
        // resolve got, and a set would not.
        //
        // The middle cause comes from this resolver's un-injected ssh seam,
        // which is the same `.undeterminable(.probeUnavailable)` a shipped
        // build reports when it cannot inspect the surface's process table.
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(tty: "/dev/ttys009"), origin: local))
        let joinResolver = resolver(registry: registry, focusedTTY: "/dev/ttys003")
        let summary = await ClaudeSurfaceProbe.summarize(
            accessibilityTrusted: true,
            frontmostTarget: ghostty,
            hasLiveSessions: { registry.hasLiveSessions() },
            resolve: { await joinResolver.resolve(target: $0) }
        )
        XCTAssertEqual(
            summary.abstentionReason,
            "tty: no live session on this device"
                + "; remote-herdr: ssh session undeterminable (probe unavailable)"
                + "; marker: no marker in title"
        )
    }

    func testATTYJoinReportsEveryFieldTheSummaryPromises() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(tty: "/dev/ttys003"), origin: local))
        let joinResolver = resolver(registry: registry, focusedTTY: "/dev/ttys003")
        let summary = await ClaudeSurfaceProbe.summarize(
            accessibilityTrusted: true,
            frontmostTarget: ghostty,
            hasLiveSessions: { registry.hasLiveSessions() },
            resolve: { await joinResolver.resolve(target: $0) }
        )
        XCTAssertEqual(summary.arm, "tty")
        XCTAssertNil(summary.abstentionReason, "no arm declined on the way to this answer")
        XCTAssertEqual(summary.origin, "local")
        XCTAssertEqual(
            summary.terminal, "Ghostty",
            "the four supported terminals are named the same way on every machine"
        )
        XCTAssertEqual(
            summary.herdrBound, false,
            "a tty join is not a herdr binding, and the output must not imply one"
        )
        XCTAssertEqual(summary.workspaceIsLocal, true)
        XCTAssertEqual(ClaudeSurfaceProbe.exitCode(for: summary), 0)
    }

    func testAHerdrJoinReportsHerdrBound() async {
        let registry = makeRegistry()
        XCTAssertNotNil(
            registry.ingest(
                record(
                    tty: "/dev/ttys-inner",
                    herdrPaneID: "pane-a",
                    herdrSocketPath: "/tmp/herdr-a.sock"
                ),
                origin: local
            )
        )
        let joinResolver = resolver(
            registry: registry,
            focusedTTY: "/dev/ttys-outer",
            herdrClient: true,
            herdrPanes: ProbeTestHerdrPanes(
                focused: HerdrFocusedPane(paneID: "pane-a", claimedClaudeSessionID: "s1"),
                foreground: HerdrPaneForegroundInfo(shellPID: 8000, foregroundPIDs: [9001])
            )
        )
        let summary = await ClaudeSurfaceProbe.summarize(
            accessibilityTrusted: true,
            frontmostTarget: ghostty,
            hasLiveSessions: { registry.hasLiveSessions() },
            resolve: { await joinResolver.resolve(target: $0) }
        )
        XCTAssertEqual(summary.arm, "herdrPane")
        XCTAssertEqual(summary.herdrBound, true)
        XCTAssertEqual(summary.terminal, "Ghostty")
    }

    func testExitStatusSplitsJoinedFromNotJoined() {
        XCTAssertEqual(
            ClaudeSurfaceProbe.exitCode(
                for: ClaudeSessionJoinSummary(arm: "none", abstentionReason: nil)
            ),
            1
        )
        XCTAssertEqual(
            ClaudeSurfaceProbe.exitCode(
                for: ClaudeSessionJoinSummary(arm: "tty", abstentionReason: nil)
            ),
            0
        )
    }

    // MARK: - The tap

    func testTheAbstentionTapIsInertOutsideACollection() async {
        // The tap is compiled into shipping builds. A note that accumulated
        // while nobody was collecting would be an unbounded buffer in a process
        // that runs for weeks — and would leak one probe's causes into the next.
        ClaudeJoinAbstentionTap.note("stray: before")
        let (_, causes) = await ClaudeJoinAbstentionTap.collecting {
            ClaudeJoinAbstentionTap.note("inside: one")
        }
        XCTAssertEqual(causes, ["inside: one"])

        ClaudeJoinAbstentionTap.note("stray: after")
        let (_, second) = await ClaudeJoinAbstentionTap.collecting {}
        XCTAssertEqual(second, [], "a collection must start empty, whatever ran before it")
    }
}

/// The JSON shape is the contract every future assertion is written against, so
/// it is asserted literally rather than by round-tripping through a decoder
/// that would forgive a dropped key.
@MainActor
final class ClaudeSessionJoinSummaryJSONTests: XCTestCase {
    func testAbstainedSummaryEmitsEveryKeyWithExplicitNulls() {
        let summary = ClaudeSessionJoinSummary.summarize(
            join: nil, abstentions: ["tty: stale"]
        )
        XCTAssertEqual(
            summary.jsonLine,
            #"{"arm":"none","abstentionReason":"tty: stale","origin":null,"terminal":null,"#
                + #""herdrBound":null,"workspaceIsLocal":null}"#
        )
    }

    func testFullSummaryEmitsBoolsUnquotedAndKeysInTheDocumentedOrder() {
        let summary = ClaudeSessionJoinSummary(
            arm: "remoteHerdrPane",
            abstentionReason: nil,
            origin: "remote",
            terminal: "Ghostty",
            herdrBound: true,
            workspaceIsLocal: false
        )
        let expected = #"{"arm":"remoteHerdrPane","abstentionReason":null,"#
            + #""origin":"remote","terminal":"Ghostty","#
            + #""herdrBound":true,"workspaceIsLocal":false}"#
        XCTAssertEqual(summary.jsonLine, expected)
    }

    func testACauseCarryingQuotesCannotEmitBrokenJSON() throws {
        let summary = ClaudeSessionJoinSummary.summarize(
            join: nil, abstentions: [#"tty: "odd" \ cause"#]
        )
        let data = Data(summary.jsonLine.utf8)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["abstentionReason"] as? String, #"tty: "odd" \ cause"#)
        XCTAssertTrue(object["origin"] is NSNull, "null must survive as null, not vanish")
        XCTAssertEqual(object.keys.count, 6)
    }

    func testEveryMechanismHasItsOwnArmName() {
        // Two arms sharing a name would make a probe run and a dogfood record
        // agree on a lie.
        let mechanisms: [ClaudeSessionJoinMechanism] = [
            .ttyDevice, .titleMarker, .herdrPane, .browserTab, .cmuxSurface, .remoteHerdrPane,
        ]
        let names = mechanisms.map(ClaudeSessionJoinSummary.armName)
        XCTAssertEqual(
            names, ["tty", "titleMarker", "herdrPane", "browserTab", "cmuxSurface",
                    "remoteHerdrPane"]
        )
        XCTAssertFalse(names.contains("none"), "`none` means no arm answered at all")
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testTerminalNamesCoverExactlyTheJoinableTerminals() {
        XCTAssertEqual(
            TerminalScreenAllowlist.displayName(forBundleID: TerminalScreenAllowlist.ghosttyBundleID),
            "Ghostty"
        )
        XCTAssertEqual(
            TerminalScreenAllowlist.displayName(forBundleID: TerminalScreenAllowlist.iterm2BundleID),
            "iTerm2"
        )
        XCTAssertEqual(
            TerminalScreenAllowlist.displayName(
                forBundleID: TerminalScreenAllowlist.appleTerminalBundleID
            ),
            "Terminal.app"
        )
        XCTAssertEqual(
            TerminalScreenAllowlist.displayName(forBundleID: TerminalScreenAllowlist.cmuxBundleID),
            "cmux"
        )
        for bundleID in TerminalScreenAllowlist.supportedBundleIDs {
            XCTAssertNotNil(
                TerminalScreenAllowlist.displayName(forBundleID: bundleID),
                "a joinable terminal with no name would report `terminal: null` on a real join"
            )
        }
        XCTAssertNil(TerminalScreenAllowlist.displayName(forBundleID: "com.microsoft.VSCode"))
        XCTAssertNil(TerminalScreenAllowlist.displayName(forBundleID: nil))
    }
}
