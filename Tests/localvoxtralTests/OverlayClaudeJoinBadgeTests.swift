import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

private final class BadgeTestMarkers: Sendable {
    private let queue: Mutex<[String]>
    init(_ values: [String]) { queue = Mutex(values) }
    var allocate: @Sendable () -> String {
        { [self] in queue.withLock { $0.isEmpty ? "lvx-exhausted" : $0.removeFirst() } }
    }
}

/// The overlay's join badge: what it says, when it says nothing, and what it
/// refuses to render.
///
/// Joins are built through the REAL registry and resolver rather than a literal
/// `ClaudeSessionJoin`, so the workspace label under test is the one the wire
/// path actually produces for each origin.
@MainActor
final class OverlayClaudeJoinBadgeTests: XCTestCase {
    private let ghostty = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "c1")

    private func registry(markers: [String] = ["lvx-abcd"]) -> ClaudeSessionRegistry {
        ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in true },
            allocateMarkerValue: BadgeTestMarkers(markers).allocate
        )
    }

    /// A resolved join for a session whose cwd is `cwd`, via the marker arm.
    private func join(
        cwd: String?,
        origin: ClaudeTransportOrigin? = nil
    ) async -> ClaudeSessionJoin? {
        let registry = registry()
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s1",
                timestamp: 0,
                rawCwd: cwd,
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001)
            ),
            origin: origin ?? local
        )
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            markerInWindowTitle: { _ in
                TerminalScreenAXReader.FocusedWindowMarkerRead(
                    marker: ClaudeSessionMarker(value: "lvx-abcd"), windowID: 101
                )
            }
        )
        return await resolver.resolve(target: ghostty)
    }

    // MARK: - What the badge says

    func testAResolvedLocalJoinNamesItsWorkspace() async {
        let join = await join(cwd: "/Users/dev/work/localvoxtral")
        XCTAssertNotNil(join, "positive control: the badge cases below mean nothing without a join")
        XCTAssertEqual(
            OverlayClaudeJoinBadge.resolve(
                join: join,
                contextFeatureEnabled: true,
                liveSessionsExist: { true }
            ),
            .joined(label: "localvoxtral")
        )
    }

    // A remote session's cwd never survives as a path — `opaqueLabel` reduces it
    // to a bare name. The badge shows that name and nothing else.
    func testAResolvedRemoteJoinNamesItsOpaqueLabel() async {
        let join = await join(cwd: "/srv/checkouts/api-gateway", origin: remote)
        XCTAssertEqual(
            OverlayClaudeJoinBadge.resolve(
                join: join,
                contextFeatureEnabled: true,
                liveSessionsExist: { true }
            ),
            .joined(label: "api-gateway")
        )
    }

    // A join with no cwd is still a real join — it grounds the prompt with the
    // session's prior prompt and files. Falling back to `.unjoined` would call a
    // working setup broken.
    func testAJoinWithoutAWorkspaceStaysJoined() async {
        let join = await join(cwd: nil)
        XCTAssertEqual(
            OverlayClaudeJoinBadge.resolve(
                join: join,
                contextFeatureEnabled: true,
                liveSessionsExist: { true }
            ),
            .joined(label: OverlayClaudeJoinBadge.unnamedWorkspaceLabel)
        )
    }

    // The state the feature exists for: sessions are live, none attached.
    func testNoJoinWithLiveSessionsIsUnjoined() {
        XCTAssertEqual(
            OverlayClaudeJoinBadge.resolve(
                join: nil,
                contextFeatureEnabled: true,
                liveSessionsExist: { true }
            ),
            .unjoined
        )
    }

    // MARK: - When it says nothing

    // A Mac that is not running Claude Code must not wear a permanent
    // complaint about a join that was never attempted.
    func testNoJoinAndNoSessionsIsSilent() {
        XCTAssertEqual(
            OverlayClaudeJoinBadge.resolve(
                join: nil,
                contextFeatureEnabled: true,
                liveSessionsExist: { false }
            ),
            .hidden
        )
    }

    // Both context features off means nothing downstream would have used a
    // join, so there is nothing to report — even when one resolved before the
    // settings changed.
    func testFeaturesOffHideTheBadgeEvenWithAJoin() async {
        let join = await join(cwd: "/repo")
        XCTAssertEqual(
            OverlayClaudeJoinBadge.resolve(
                join: join,
                contextFeatureEnabled: false,
                liveSessionsExist: { true }
            ),
            .hidden
        )
    }

    // The registry lives behind a lock every dictation start already contends
    // for, and a resolved join has already proved a session exists.
    func testTheRegistryIsNotConsultedWhenAJoinResolved() async {
        let join = await join(cwd: "/repo")
        let asked = Mutex(0)
        _ = OverlayClaudeJoinBadge.resolve(
            join: join,
            contextFeatureEnabled: true,
            liveSessionsExist: {
                asked.withLock { $0 += 1 }
                return true
            }
        )
        XCTAssertEqual(asked.withLock { $0 }, 0)
    }

    // The settings gate sits in front of the registry read too: a user with
    // both features off pays nothing.
    func testTheRegistryIsNotConsultedWhenFeaturesAreOff() {
        let asked = Mutex(0)
        _ = OverlayClaudeJoinBadge.resolve(
            join: nil,
            contextFeatureEnabled: false,
            liveSessionsExist: {
                asked.withLock { $0 += 1 }
                return true
            }
        )
        XCTAssertEqual(asked.withLock { $0 }, 0)
    }

    // MARK: - What it refuses to render

    // A LOCAL workspace name is the last component of a real directory, and a
    // macOS path component forbids only `/` and NUL. The panel is measured from
    // the body text alone, so a label carrying a line break would draw outside
    // the height the panel was sized for.
    func testControlCharactersAreStrippedFromTheLabel() {
        XCTAssertEqual(
            OverlayClaudeJoinBadge.displayLabel(forWorkspaceName: "repo\nname\tx"),
            "repo name x"
        )
    }

    // RIGHT-TO-LEFT OVERRIDE is category Cf, which `controlCharacters` covers —
    // a header that reorders around a directory name is not a display this
    // badge may produce.
    func testBidiOverridesAreStrippedFromTheLabel() {
        XCTAssertEqual(
            OverlayClaudeJoinBadge.displayLabel(forWorkspaceName: "repo\u{202E}drowssap"),
            "repodrowssap"
        )
    }

    func testWhitespaceRunsCollapseSoALabelCannotPadThePill() {
        XCTAssertEqual(
            OverlayClaudeJoinBadge.displayLabel(forWorkspaceName: "  my    repo  "),
            "my repo"
        )
    }

    func testAnOverlongLabelIsTruncatedWithAnEllipsis() throws {
        let name = String(repeating: "a", count: 80)
        let label = try XCTUnwrap(OverlayClaudeJoinBadge.displayLabel(forWorkspaceName: name))
        XCTAssertEqual(label.count, OverlayClaudeJoinBadge.maximumLabelLength)
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertTrue(label.hasPrefix("aaa"))
    }

    func testALabelAtTheLimitIsLeftAlone() throws {
        let name = String(repeating: "b", count: OverlayClaudeJoinBadge.maximumLabelLength)
        XCTAssertEqual(OverlayClaudeJoinBadge.displayLabel(forWorkspaceName: name), name)
    }

    // Nothing usable left is nil, which the resolver turns into the unnamed
    // fallback rather than an empty pill.
    func testALabelOfNothingButControlCharactersIsRejected() {
        XCTAssertNil(OverlayClaudeJoinBadge.displayLabel(forWorkspaceName: "\n\t\u{202E}"))
        XCTAssertNil(OverlayClaudeJoinBadge.displayLabel(forWorkspaceName: "   "))
    }
}
