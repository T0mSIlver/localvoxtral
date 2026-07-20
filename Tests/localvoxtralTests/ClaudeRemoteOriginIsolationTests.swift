import ClaudeContextWire
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// A collector that records every call and touches nothing.
///
/// The point is the counter. `ClaudeRepoCollecting` takes a
/// `LocalWorkspacePath`, whose initializer is internal to `ClaudeContextWire`
/// and constructed in exactly one place — so a remote workspace physically
/// cannot be handed to one. This spy is how we prove the consequence rather than
/// only the mechanism.
private final class SpyRepoCollector: ClaudeRepoCollecting, @unchecked Sendable {
    let calls = Mutex<[String]>([])

    func collect(
        workspace: LocalWorkspacePath,
        recentFiles: [ClaudeRecentFile],
        transcript: String
    ) async -> ClaudeRepoSnapshot? {
        calls.withLock { $0.append(workspace.path) }
        return nil
    }

    var callCount: Int { calls.withLock { $0.count } }
}

/// The trust boundary between a remote session and this machine's filesystem.
final class ClaudeRemoteOriginIsolationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let remote = ClaudeTransportOrigin.remote(channel: "ssh:habc")
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    private func makeRegistry(markers: [String] = []) -> ClaudeSessionRegistry {
        let queue = Mutex(markers)
        return ClaudeSessionRegistry(
            now: { [now] in now },
            isProcessAlive: { _ in true },
            allocateMarkerValue: {
                queue.withLock { queue in
                    queue.isEmpty ? ClaudeSessionRegistry.defaultMarkerValue() : queue.removeFirst()
                }
            }
        )
    }

    private func record(
        event: ClaudeHookEvent = .sessionStart,
        sessionID: String = "remote:habc:s-1",
        cwd: String? = "/home/dev/work/service",
        prompt: String? = nil,
        files: [ClaudeFileTouch] = []
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            sessionID: sessionID,
            timestamp: now.timeIntervalSince1970,
            rawCwd: cwd,
            prompt: prompt,
            files: files,
            process: ClaudeHookProcessInfo(hookPID: 1, claudePID: 2)
        )
    }

    // MARK: The compile-time half

    func testARemoteWorkspaceIsAnOpaqueLabelWithNoPath() throws {
        let workspace = try XCTUnwrap(
            ClaudeWorkspaceReference.make(rawCwd: "/home/dev/work/service", origin: remote)
        )
        XCTAssertEqual(workspace, .remoteOpaque(label: "service"))
        XCTAssertNil(workspace.localPath, "a remote cwd has no local path, by construction")
        XCTAssertEqual(workspace.displayName, "service", "safe to show, never to open")
    }

    func testARemoteCwdCannotEscapeIntoAPath() throws {
        // The full path never survives; what is left is a label, and even a
        // caller who ignored the type system would find nothing to open.
        for hostile in [
            "/etc/passwd",
            "../../../../etc/shadow",
            "/home/dev/../../etc",
            "/home/dev/work/..",
            "/home/dev/.ssh",
        ] {
            let workspace = ClaudeWorkspaceReference.make(rawCwd: hostile, origin: remote)
            if let workspace {
                XCTAssertNil(workspace.localPath)
                let label = workspace.displayName
                XCTAssertFalse(label.contains("/"), "'\(hostile)' produced a path-ish label: \(label)")
                XCTAssertFalse(label.hasPrefix("."), "'\(hostile)' produced a hidden/relative label: \(label)")
                XCTAssertNotEqual(label, "..")
            }
        }
    }

    // MARK: The runtime half

    func testARemoteSessionNeverExposesALocalWorkspacePath() throws {
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(registry.ingest(record(), origin: remote))
        XCTAssertNil(
            snapshot.localWorkspacePath,
            "this accessor is the only thing a collector can be handed"
        )
        XCTAssertEqual(snapshot.workspace, .remoteOpaque(label: "service"))
        XCTAssertEqual(snapshot.origin, remote)
    }

    func testARemoteSessionsFilePathsAreWithheldFromLocalConsumers() throws {
        // Per-file paths are plain strings on the wire, so unlike the cwd they
        // have no compile-time gate. `localRecentFiles` is theirs.
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(registry.ingest(
            record(event: .postToolUse, files: [
                ClaudeFileTouch(path: "/etc/passwd", kind: .read),
                ClaudeFileTouch(path: "/home/dev/work/service/main.swift", kind: .edited),
            ]),
            origin: remote
        ))
        XCTAssertEqual(snapshot.recentFiles.count, 2, "still known, for display and grounding")
        XCTAssertEqual(snapshot.localRecentFiles, [], "but never as paths on THIS machine")
    }

    func testALocalSessionsFilePathsAreAvailable() throws {
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(registry.ingest(
            record(event: .postToolUse, sessionID: "s-local", files: [
                ClaudeFileTouch(path: "/home/dev/work/service/main.swift", kind: .edited),
            ]),
            origin: local
        ))
        XCTAssertEqual(snapshot.localRecentFiles.map(\.path), ["/home/dev/work/service/main.swift"])
        XCTAssertEqual(snapshot.localWorkspacePath?.path, "/home/dev/work/service")
    }

    /// The end-to-end statement of the whole feature's safety property.
    func testARemoteRecordCausesZeroLocalFilesystemCalls() async throws {
        let collector = SpyRepoCollector()
        let registry = makeRegistry()

        // Everything a hostile remote could try: an absolute cwd that exists
        // locally, a traversal, and files it would love us to read.
        for cwd in ["/etc", "/home/dev/work/service", "/../../etc", "/Users/dev/.ssh"] {
            let snapshot = try XCTUnwrap(registry.ingest(
                record(
                    event: .postToolUse,
                    sessionID: "remote:habc:\(cwd)",
                    cwd: cwd,
                    files: [ClaudeFileTouch(path: "/etc/passwd", kind: .read)]
                ),
                origin: remote
            ))
            // This is the only door to the collector, and it is shut.
            if let workspace = snapshot.localWorkspacePath {
                _ = await collector.collect(
                    workspace: workspace, recentFiles: [], transcript: ""
                )
            }
        }

        XCTAssertEqual(
            collector.callCount,
            0,
            "no remote record may ever reach a local repository collector"
        )
    }

    func testALocalRecordDoesReachTheCollector() async throws {
        // The negative test above is only meaningful if the positive one works —
        // otherwise it would pass with the collector wired to nothing.
        let collector = SpyRepoCollector()
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(registry.ingest(record(sessionID: "s-local"), origin: local))
        let workspace = try XCTUnwrap(snapshot.localWorkspacePath)
        _ = await collector.collect(workspace: workspace, recentFiles: [], transcript: "")
        XCTAssertEqual(collector.calls.withLock { $0 }, ["/home/dev/work/service"])
    }

    // MARK: Origin is fixed at first sight

    func testARemoteRecordCannotMutateALocalSession() throws {
        let registry = makeRegistry()
        _ = registry.ingest(record(sessionID: "s-1", cwd: "/home/dev/work/service"), origin: local)

        // The same id, arriving over the remote transport.
        let hijack = registry.ingest(
            record(event: .userPromptSubmit, sessionID: "s-1", cwd: "/tmp", prompt: "injected"),
            origin: remote
        )
        XCTAssertNil(hijack, "a remote record naming a local session must be dropped whole")

        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "s-1"))
        XCTAssertEqual(snapshot.origin, local)
        XCTAssertNil(snapshot.latestPriorUserPrompt)
        XCTAssertEqual(snapshot.localWorkspacePath?.path, "/home/dev/work/service")
    }

    func testALocalRecordCannotPromoteARemoteSession() throws {
        let registry = makeRegistry()
        _ = registry.ingest(record(sessionID: "remote:habc:s-1"), origin: remote)

        let promotion = registry.ingest(
            record(sessionID: "remote:habc:s-1", cwd: "/home/dev/work/service"),
            origin: local
        )
        XCTAssertNil(promotion, "origin is fixed at first sight, in both directions")

        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "remote:habc:s-1"))
        XCTAssertEqual(snapshot.origin, remote)
        XCTAssertNil(snapshot.localWorkspacePath)
    }

    func testOneHostCannotMutateAnothersSession() throws {
        let registry = makeRegistry()
        let hostA = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: "hAAA"))
        let hostB = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: "hBBB"))
        let scoped = ClaudeRemoteSessionScope.scopedSessionID(hostID: "hAAA", sessionID: "s-1")

        _ = registry.ingest(record(event: .userPromptSubmit, sessionID: scoped, prompt: "A's work"), origin: hostA)
        let cross = registry.ingest(
            record(event: .userPromptSubmit, sessionID: scoped, prompt: "B's injection"),
            origin: hostB
        )
        XCTAssertNil(cross)
        XCTAssertEqual(registry.snapshot(sessionID: scoped)?.latestPriorUserPrompt, "A's work")
    }

    // MARK: Host and session isolation

    func testTwoHostsWithTheSameSessionIDGetSeparateSessionsAndMarkers() throws {
        let registry = makeRegistry(markers: ["lvx-aaaa1111", "lvx-bbbb2222"])
        let hostA = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: "hAAA"))
        let hostB = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: "hBBB"))

        // Both hosts happen to pick the same Claude session id. Scoping is what
        // keeps them apart — without it, the second would silently take over the
        // first's session and its marker.
        let a = try XCTUnwrap(registry.ingest(
            record(
                event: .userPromptSubmit,
                sessionID: ClaudeRemoteSessionScope.scopedSessionID(hostID: "hAAA", sessionID: "same-id"),
                cwd: "/srv/alpha",
                prompt: "alpha work"
            ),
            origin: hostA
        ))
        let b = try XCTUnwrap(registry.ingest(
            record(
                event: .userPromptSubmit,
                sessionID: ClaudeRemoteSessionScope.scopedSessionID(hostID: "hBBB", sessionID: "same-id"),
                cwd: "/srv/beta",
                prompt: "beta work"
            ),
            origin: hostB
        ))

        XCTAssertNotEqual(a.sessionID, b.sessionID)
        XCTAssertNotEqual(a.marker, b.marker)
        XCTAssertEqual(a.latestPriorUserPrompt, "alpha work")
        XCTAssertEqual(b.latestPriorUserPrompt, "beta work")
        XCTAssertEqual(a.workspace, .remoteOpaque(label: "alpha"))
        XCTAssertEqual(b.workspace, .remoteOpaque(label: "beta"))
        XCTAssertEqual(registry.liveSessions().count, 2)
    }

    func testEachHostsMarkerResolvesOnlyToItsOwnSession() throws {
        let registry = makeRegistry(markers: ["lvx-aaaa1111", "lvx-bbbb2222"])
        let hostA = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: "hAAA"))
        let hostB = ClaudeTransportOrigin.remote(channel: ClaudeRemoteSessionScope.channel(hostID: "hBBB"))
        _ = registry.ingest(record(sessionID: "remote:hAAA:s", cwd: "/srv/alpha"), origin: hostA)
        _ = registry.ingest(record(sessionID: "remote:hBBB:s", cwd: "/srv/beta"), origin: hostB)

        guard case .resolved(let a) = registry.resolve(marker: ClaudeSessionMarker(value: "lvx-aaaa1111")) else {
            return XCTFail("host A's marker must resolve")
        }
        guard case .resolved(let b) = registry.resolve(marker: ClaudeSessionMarker(value: "lvx-bbbb2222")) else {
            return XCTFail("host B's marker must resolve")
        }
        XCTAssertEqual(a.sessionID, "remote:hAAA:s")
        XCTAssertEqual(b.sessionID, "remote:hBBB:s")
    }

    func testAnUnknownMarkerAbstains() {
        let registry = makeRegistry(markers: ["lvx-aaaa1111"])
        _ = registry.ingest(record(), origin: remote)
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-9999ffff")), .unknown)
    }

    func testAStaleRemoteSessionAbstains() throws {
        // A remote pid names a process on another machine, where it could be
        // anything — so remote sessions rely on TTL alone, never on liveness.
        let clock = Mutex(now)
        let registry = ClaudeSessionRegistry(
            now: { clock.withLock { $0 } },
            isProcessAlive: { _ in XCTFail("a remote pid must never be probed"); return true },
            allocateMarkerValue: { "lvx-aaaa1111" }
        )
        _ = registry.ingest(record(), origin: remote)
        XCTAssertEqual(
            registry.resolve(marker: ClaudeSessionMarker(value: "lvx-aaaa1111")),
            .resolved(try XCTUnwrap(registry.snapshot(sessionID: "remote:habc:s-1")))
        )

        clock.withLock { $0 = $0.addingTimeInterval(ClaudeRegistryLimits.default.sessionTTL + 1) }
        XCTAssertEqual(registry.resolve(marker: ClaudeSessionMarker(value: "lvx-aaaa1111")), .stale)
    }

    // MARK: Snippets

    func testRemoteSnippetsAreRetainedMostRecentFirstAndCapped() throws {
        let registry = makeRegistry()
        for index in 0..<(ClaudeSessionReducer.maxRecentSnippets + 4) {
            _ = registry.ingest(
                record(event: .postToolUse),
                origin: remote,
                snippets: [ClaudeContentSnippet(label: "Edit new_string", kind: .toolInput, text: "v\(index)")]
            )
        }
        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "remote:habc:s-1"))
        XCTAssertEqual(snapshot.recentSnippets.count, ClaudeSessionReducer.maxRecentSnippets)
        XCTAssertEqual(snapshot.recentSnippets.first?.text, "v11", "most recent first")
    }

    func testARepeatedSnippetIsPromotedNotDuplicated() throws {
        let registry = makeRegistry()
        let snippet = ClaudeContentSnippet(label: "Edit new_string", kind: .toolInput, text: "same")
        let other = ClaudeContentSnippet(label: "Read file", kind: .toolOutput, text: "other")
        _ = registry.ingest(record(event: .postToolUse), origin: remote, snippets: [snippet])
        _ = registry.ingest(record(event: .postToolUse), origin: remote, snippets: [other])
        _ = registry.ingest(record(event: .postToolUse), origin: remote, snippets: [snippet])

        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "remote:habc:s-1"))
        XCTAssertEqual(snapshot.recentSnippets, [snippet, other])
    }

    func testNonToolEventsAttachNoSnippets() throws {
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(registry.ingest(
            record(event: .userPromptSubmit, prompt: "hello"),
            origin: remote,
            snippets: [ClaudeContentSnippet(label: "Edit new_string", kind: .toolInput, text: "x")]
        ))
        XCTAssertEqual(snapshot.recentSnippets, [], "only tool events carry tool excerpts")
    }
}
