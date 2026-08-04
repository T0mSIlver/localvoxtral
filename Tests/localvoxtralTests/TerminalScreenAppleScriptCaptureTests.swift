import ClaudeContextWire
import CoreGraphics
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// iTerm2 / Terminal.app screen context and session joins — the AppleScript
/// capture route added alongside Ghostty's AX route (owner decision,
/// 2026-07-22).
///
/// What these tests defend:
/// - the allowlist truth table: join-eligibility and AX-eligibility are now
///   SEPARATE facts, and the new terminals must never gain the AX one;
/// - the AppleScript route feeds the exact same downstream pipeline as AX
///   text (sanitization, cap, start/stop reconcile, raw-attachment
///   authorization);
/// - the join resolver runs its TTY arm and herdr probe for the new bundles.
@MainActor
final class TerminalScreenAppleScriptCaptureTests: XCTestCase {
    private let loopback = URL(string: "http://127.0.0.1:8472/v1/chat/completions")!
    private let epoch = Date(timeIntervalSince1970: 2_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    private let iterm2 = TerminalScreenTarget(
        pid: 5151, bundleID: TerminalScreenAllowlist.iterm2BundleID
    )
    private let appleTerminal = TerminalScreenTarget(
        pid: 6161, bundleID: TerminalScreenAllowlist.appleTerminalBundleID
    )
    private var appleScriptTargets: [TerminalScreenTarget] { [iterm2, appleTerminal] }

    override func tearDown() async throws {
        TerminalScreenAXReader.debugScreenReadOverride = nil
        TerminalScreenAXReader.debugWindowTitleOverride = nil
        TerminalScreenAXReader.debugScreenWindowIDOverride = nil
        TerminalScreenAXReader.debugTitleWindowIDOverride = nil
        TerminalScreenAppleScriptReader.debugContentsReadOverride = nil
        TerminalScreenContextSource.debugFrontmostTargetOverride = nil
        TerminalScreenContextSource.debugTargetForPIDOverride = nil
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = nil
        TerminalScreenRawAttachmentPolicy.configure(authorizer: nil)
        try await super.tearDown()
    }

    // MARK: - Allowlist truth table

    /// The complete membership table: join-eligible vs AX-capture vs
    /// AppleScript-capture vs excluded, for all three terminals, the excluded
    /// editors, and a random bundle. A future widening that lets a new
    /// terminal slip into the AX set fails here.
    func testAllowlistTruthTable() {
        struct Row {
            let bundleID: String?
            let supported: Bool
            let ax: Bool
            let appleScript: Bool
        }
        var rows: [Row] = [
            Row(bundleID: TerminalScreenAllowlist.ghosttyBundleID,
                supported: true, ax: true, appleScript: false),
            Row(bundleID: TerminalScreenAllowlist.iterm2BundleID,
                supported: true, ax: false, appleScript: true),
            Row(bundleID: TerminalScreenAllowlist.appleTerminalBundleID,
                supported: true, ax: false, appleScript: true),
            Row(bundleID: "com.example.random", supported: false, ax: false, appleScript: false),
            Row(bundleID: "com.googlecode.iterm2.evil",
                supported: false, ax: false, appleScript: false),
            Row(bundleID: "", supported: false, ax: false, appleScript: false),
            Row(bundleID: nil, supported: false, ax: false, appleScript: false),
        ]
        for excluded in TerminalScreenAllowlist.explicitlyExcludedBundleIDs {
            rows.append(Row(bundleID: excluded, supported: false, ax: false, appleScript: false))
        }
        for row in rows {
            let name = row.bundleID ?? "nil"
            XCTAssertEqual(
                TerminalScreenAllowlist.isSupported(row.bundleID), row.supported,
                "isSupported(\(name))"
            )
            XCTAssertEqual(
                TerminalScreenAllowlist.isAXCaptureSupported(row.bundleID), row.ax,
                "isAXCaptureSupported(\(name))"
            )
            XCTAssertEqual(
                TerminalScreenAllowlist.isAppleScriptCaptureSupported(row.bundleID),
                row.appleScript,
                "isAppleScriptCaptureSupported(\(name))"
            )
        }
    }

    /// The capture routes are exclusive and exhaustive over the supported
    /// set — a bundle with two routes would read twice, one with none would
    /// silently never capture. Three routes now: the AX grid, the AppleScript
    /// contents, and cmux's control socket.
    func testEverySupportedBundleHasExactlyOneCaptureRoute() {
        for bundleID in TerminalScreenAllowlist.supportedBundleIDs {
            let routes = [
                TerminalScreenAllowlist.isAXCaptureSupported(bundleID),
                TerminalScreenAllowlist.isAppleScriptCaptureSupported(bundleID),
                TerminalScreenAllowlist.isSocketCaptureSupported(bundleID),
            ]
            XCTAssertEqual(
                routes.filter { $0 }.count, 1,
                "\(bundleID) must have exactly one capture route"
            )
        }
    }

    /// The AppleScript contents chains are the reviewed facts of the route:
    /// the VISIBLE screen (`contents` — Terminal.app's `history` is the whole
    /// scrollback and must never be asked for), the focused session/tab, the
    /// exact bundle id, and a bounded reply.
    func testContentsScriptSourceNamesTheVisibleScreenChainPerTerminal() throws {
        let cases: [(String, String)] = [
            (
                TerminalScreenAllowlist.iterm2BundleID,
                "get contents of current session of current window"
            ),
            (
                TerminalScreenAllowlist.appleTerminalBundleID,
                "get contents of selected tab of front window"
            ),
        ]
        for (bundleID, chain) in cases {
            let source = try XCTUnwrap(
                TerminalScreenAppleScriptReader.scriptSource(forBundleID: bundleID)
            )
            XCTAssertTrue(source.contains(chain), "\(bundleID) must ask: \(chain)")
            XCTAssertFalse(source.contains("history"), "never the scrollback")
            XCTAssertTrue(source.contains("tell application id \"\(bundleID)\""))
            XCTAssertTrue(source.contains("with timeout of 1 second"))
        }
        XCTAssertNil(
            TerminalScreenAppleScriptReader.scriptSource(
                forBundleID: TerminalScreenAllowlist.ghosttyBundleID
            ),
            "Ghostty is captured over its verified AX grid, not AppleScript"
        )
        XCTAssertNil(
            TerminalScreenAppleScriptReader.scriptSource(forBundleID: "com.example.random")
        )
    }

    // MARK: - Capture routing: AX must never fire for the new terminals

    func testCaptureAtStartUsesAppleScriptContentsAndNeverAXForNewTerminals() {
        for target in appleScriptTargets {
            let axReads = Mutex(0)
            TerminalScreenAXReader.debugScreenReadOverride = { _ in
                axReads.withLock { $0 += 1 }
                return "must never be read over AX"
            }
            TerminalScreenAppleScriptReader.debugContentsReadOverride = { pid, bundleID in
                XCTAssertEqual(pid, target.pid, "the read must be pinned to the resolved PID")
                XCTAssertEqual(bundleID, target.bundleID)
                return "$ swift build\u{0}"
            }
            TerminalScreenContextSource.debugFrontmostTargetOverride = { target }
            let capture = TerminalScreenContextSource.captureAtStart(
                settingEnabled: true,
                endpointURL: loopback,
                isAccessibilityTrusted: true
            )
            // Same sanitization pipeline as AX text: the NUL is stripped.
            XCTAssertEqual(capture, TerminalScreenCapture(text: "$ swift build", target: target))
            XCTAssertEqual(
                axReads.withLock { $0 }, 0,
                "\(target.bundleID) must never be captured over AX"
            )
        }
    }

    func testStopReReadUsesAppleScriptAndNeverAXForNewTerminals() {
        for target in appleScriptTargets {
            let axReads = Mutex(0)
            TerminalScreenAXReader.debugScreenReadOverride = { _ in
                axReads.withLock { $0 += 1 }
                return "must never be read over AX"
            }
            TerminalScreenAppleScriptReader.debugContentsReadOverride = { _, _ in "hello" }
            TerminalScreenContextSource.debugTargetForPIDOverride = { _ in target }
            let decision = TerminalScreenContextSource.reconcileAtStop(
                start: TerminalScreenCapture(text: "hello", target: target),
                settingEnabled: true,
                endpointURL: loopback,
                isAccessibilityTrusted: true
            )
            XCTAssertEqual(
                decision, .vocabularyOnly(startText: "hello", cause: .rawUnauthorized),
                "\(target.bundleID): unchanged screen, no authorizer configured"
            )
            XCTAssertEqual(
                axReads.withLock { $0 }, 0,
                "\(target.bundleID) must never be re-read over AX at stop"
            )
        }
    }

    // MARK: - Same pipeline: budget and sanitization

    func testAppleScriptTextTakesTheExactAXSanitizationPath() {
        // Control scalars stripped, trailing padding compacted, blank runs
        // collapsed — and the head capped at the same absolute ceiling.
        let raw = "line one   \u{7}\n\n\n\nline two\t\u{1B}[31m"
            + String(repeating: "x", count: TerminalScreenAXReader.screenCharacterCap)
        TerminalScreenAppleScriptReader.debugContentsReadOverride = { _, _ in raw }
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.iterm2 }
        let capture = TerminalScreenContextSource.captureAtStart(
            settingEnabled: true,
            endpointURL: loopback,
            isAccessibilityTrusted: true
        )
        let expected = TerminalScreenAXReader.sanitizedScreenText(raw)
        XCTAssertNotNil(expected)
        XCTAssertEqual(
            capture?.text, expected,
            "AppleScript text must be byte-identical to the AX pipeline's form"
        )
        XCTAssertEqual(capture?.text.count, TerminalScreenAXReader.screenCharacterCap)
    }

    func testEmptyOrWhitespaceOnlyContentsIsNotContext() {
        for raw in ["", "   \n\n   \n"] {
            TerminalScreenAppleScriptReader.debugContentsReadOverride = { _, _ in raw }
            TerminalScreenContextSource.debugFrontmostTargetOverride = { self.iterm2 }
            let capture = TerminalScreenContextSource.captureAtStart(
                settingEnabled: true,
                endpointURL: loopback,
                isAccessibilityTrusted: true
            )
            XCTAssertNil(capture, "'\(raw)' is not context")
        }
    }

    func testOversizedRawReplyAbstainsOutright() {
        // Beyond the raw ceiling the reply is not a visible screen; it is
        // refused, never truncated into "some" context.
        let oversized = String(
            repeating: "x",
            count: TerminalScreenAppleScriptReader.rawReplyCharacterCeiling + 1
        )
        TerminalScreenAppleScriptReader.debugContentsReadOverride = { _, _ in oversized }
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.appleTerminal }
        let capture = TerminalScreenContextSource.captureAtStart(
            settingEnabled: true,
            endpointURL: loopback,
            isAccessibilityTrusted: true
        )
        XCTAssertNil(capture)
    }

    func testValidatedRawContentsBounds() {
        XCTAssertNil(TerminalScreenAppleScriptReader.validatedRawContents(nil))
        XCTAssertNil(TerminalScreenAppleScriptReader.validatedRawContents(""))
        XCTAssertEqual(TerminalScreenAppleScriptReader.validatedRawContents("ok"), "ok")
        let atCeiling = String(
            repeating: "x",
            count: TerminalScreenAppleScriptReader.rawReplyCharacterCeiling
        )
        XCTAssertEqual(
            TerminalScreenAppleScriptReader.validatedRawContents(atCeiling), atCeiling
        )
        XCTAssertNil(TerminalScreenAppleScriptReader.validatedRawContents(atCeiling + "x"))
    }

    // MARK: - Gate parity: a rejected gate makes no AppleScript call either

    func testRejectedGateNeverCallsAppleScript() {
        let reads = Mutex(0)
        TerminalScreenAppleScriptReader.debugContentsReadOverride = { _, _ in
            reads.withLock { $0 += 1 }
            return "never"
        }
        TerminalScreenContextSource.debugFrontmostTargetOverride = { self.iterm2 }
        for (name, enabled, trusted) in [
            ("setting off", false, true), ("untrusted", true, false),
        ] {
            let capture = TerminalScreenContextSource.captureAtStart(
                settingEnabled: enabled,
                endpointURL: loopback,
                isAccessibilityTrusted: trusted
            )
            XCTAssertNil(capture, name)
        }
        XCTAssertEqual(
            reads.withLock { $0 }, 0,
            "a rejected gate must never send an Apple event"
        )
    }

    // MARK: - Raw attachment: only after an authorized join

    /// The full render path for an AppleScript capture: same truth table as
    /// Ghostty — an unchanged screen renders ONLY when the dictation's join
    /// authorizes this exact target and window; otherwise the text stays
    /// matching-only.
    func testUnchangedScreenRendersOnlyWhenRawAttachmentAuthorized() {
        for target in appleScriptTargets {
            let windowID: CGWindowID = 707
            TerminalScreenAppleScriptReader.debugContentsReadOverride = { _, _ in "$ make test" }
            TerminalScreenAXReader.debugScreenWindowIDOverride = { _ in windowID }
            TerminalScreenContextSource.debugFrontmostTargetOverride = { target }
            TerminalScreenContextSource.debugTargetForPIDOverride = { _ in target }

            let start = TerminalScreenContextSource.captureAtStart(
                settingEnabled: true,
                endpointURL: loopback,
                isAccessibilityTrusted: true
            )
            XCTAssertEqual(start?.windowID, windowID)

            TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { seen, seenWindow in
                seen == target && seenWindow == windowID
            }
            let authorized = TerminalScreenContextSource.reconcileAtStop(
                start: start,
                settingEnabled: true,
                endpointURL: loopback,
                isAccessibilityTrusted: true
            )
            XCTAssertEqual(
                authorized,
                .render(excerpt: "$ make test", startText: "$ make test", elidedChurnLines: 0),
                "\(target.bundleID): authorized join must render"
            )

            TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { _, _ in false }
            let unauthorized = TerminalScreenContextSource.reconcileAtStop(
                start: start,
                settingEnabled: true,
                endpointURL: loopback,
                isAccessibilityTrusted: true
            )
            XCTAssertEqual(
                unauthorized,
                .vocabularyOnly(startText: "$ make test", cause: .rawUnauthorized),
                "\(target.bundleID): no join, no excerpt — matching only"
            )
        }
    }

    func testStopReadFailureKeepsMatchingOnlyTextForAppleScriptRoute() {
        TerminalScreenAppleScriptReader.debugContentsReadOverride = { _, _ in nil }
        TerminalScreenContextSource.debugTargetForPIDOverride = { _ in self.iterm2 }
        let decision = TerminalScreenContextSource.reconcileAtStop(
            start: TerminalScreenCapture(text: "hello", target: iterm2),
            settingEnabled: true,
            endpointURL: loopback,
            isAccessibilityTrusted: true
        )
        XCTAssertEqual(decision, .vocabularyOnly(startText: "hello", cause: .stopReadFailed))
    }

    // MARK: - Session join: TTY arm and herdr probe for the new bundles

    private func makeRegistry(markers: [String] = ["lvx-abcd"]) -> ClaudeSessionRegistry {
        let markerQueue = Mutex(markers)
        let epoch = self.epoch
        return ClaudeSessionRegistry(
            limits: .default,
            now: { epoch },
            isProcessAlive: { _ in true },
            allocateMarkerValue: {
                markerQueue.withLock { $0.isEmpty ? "lvx-exhausted" : $0.removeFirst() }
            }
        )
    }

    private func record(
        tty: String? = nil,
        herdrPaneID: String? = nil,
        herdrSocketPath: String? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: .sessionStart,
            sessionID: "s1",
            timestamp: 0,
            rawCwd: "/repo",
            prompt: nil,
            files: [],
            process: ClaudeHookProcessInfo(
                hookPID: 777,
                claudePID: 9001,
                tty: tty,
                herdrPaneID: herdrPaneID,
                herdrSocketPath: herdrSocketPath
            )
        )
    }

    private struct StubHerdrPanes: HerdrPaneQuerying {
        var focused: HerdrFocusedPane?
        var foreground: HerdrPaneForegroundInfo?
        var visibleText: String?

        func focusedPane(socketPath _: String) async -> HerdrFocusedPane? { focused }
        func paneForegroundInfo(
            socketPath _: String, paneID _: String
        ) async -> HerdrPaneForegroundInfo? { foreground }
        func paneVisibleText(socketPath _: String, paneID _: String) async -> String? {
            visibleText
        }
    }

    /// The TTY arm answers for the new terminals exactly as for Ghostty: the
    /// per-terminal reader's device path is matched against the hook-reported
    /// session TTY, and the join carries the tty mechanism.
    func testResolverRunsTheTTYArmForNewTerminalBundles() async throws {
        for target in appleScriptTargets {
            let registry = makeRegistry()
            XCTAssertNotNil(registry.ingest(record(tty: "/dev/ttys042"), origin: local))
            let askedBundles = Mutex<[String]>([])
            let resolver = ClaudeSessionJoinResolver(
                registry: registry,
                markerInWindowTitle: { _ in nil },
                focusedTerminalTTY: { bundleID in
                    askedBundles.withLock { $0.append(bundleID) }
                    return "/dev/ttys042"
                },
                focusedWindowID: { _ in 101 }
            )
            let resolved = await resolver.resolve(target: target)
            let join = try XCTUnwrap(resolved, "\(target.bundleID) must join via tty")
            XCTAssertEqual(join.mechanism, .ttyDevice)
            XCTAssertEqual(join.snapshot.sessionID, "s1")
            XCTAssertEqual(join.windowID, 101)
            XCTAssertEqual(
                askedBundles.withLock { $0 }, [target.bundleID],
                "the reader must be asked about the focused app's own bundle"
            )
        }
    }

    /// The herdr arm needs only a surface TTY, so it works in the new
    /// terminals for free: surface TTY bound to a herdr client, focused pane
    /// resolved over the socket, join is pane-id equality.
    func testResolverRunsTheHerdrProbeAndPaneJoinForNewTerminalBundles() async throws {
        for target in appleScriptTargets {
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
            let probedTTYs = Mutex<[String]>([])
            let resolver = ClaudeSessionJoinResolver(
                registry: registry,
                markerInWindowTitle: { _ in nil },
                focusedTerminalTTY: { _ in "/dev/ttys-outer" },
                focusedWindowID: { _ in 101 },
                herdrClientProbe: { tty in
                    probedTTYs.withLock { $0.append(tty) }
                    return true
                },
                herdrPanes: StubHerdrPanes(
                    focused: HerdrFocusedPane(paneID: "pane-a", claimedClaudeSessionID: nil),
                    foreground: HerdrPaneForegroundInfo(shellPID: 8000, foregroundPIDs: [9001])
                )
            )
            let resolved = await resolver.resolve(target: target)
            let join = try XCTUnwrap(resolved, "\(target.bundleID) must join via herdr pane")
            XCTAssertEqual(join.mechanism, .herdrPane)
            XCTAssertEqual(
                probedTTYs.withLock { $0 }, ["/dev/ttys-outer"],
                "the probe must be handed \(target.bundleID)'s surface tty"
            )
        }
    }

    /// A random bundle is refused before any seam is consulted: no TTY read,
    /// no herdr probe, no join.
    func testResolverRefusesUnsupportedBundlesBeforeAnySeam() async {
        let registry = makeRegistry()
        XCTAssertNotNil(registry.ingest(record(tty: "/dev/ttys042"), origin: local))
        let seamCalls = Mutex(0)
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                seamCalls.withLock { $0 += 1 }
                return nil
            },
            focusedTerminalTTY: { _ in
                seamCalls.withLock { $0 += 1 }
                return "/dev/ttys042"
            },
            focusedWindowID: { _ in 101 },
            herdrClientProbe: { _ in
                seamCalls.withLock { $0 += 1 }
                return true
            }
        )
        let join = await resolver.resolve(
            target: TerminalScreenTarget(pid: 99, bundleID: "net.kovidgoyal.kitty")
        )
        XCTAssertNil(join)
        XCTAssertEqual(seamCalls.withLock { $0 }, 0)
    }
}
