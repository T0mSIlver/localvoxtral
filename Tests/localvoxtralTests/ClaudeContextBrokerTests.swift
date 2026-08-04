import ClaudeContextWire
import ClaudeHookPublisherCore
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)
import Darwin

/// End-to-end over a real AF_UNIX socket: the production publisher writing to
/// the production broker.
///
/// The socket lives under `/tmp` rather than `NSTemporaryDirectory()` because
/// `sockaddr_un.sun_path` is 104 bytes on Darwin and the per-process temp dir
/// (`/var/folders/…`) can exceed that on its own.
///
/// No polling: the broker's `debugConfigureIngestHook` seam fulfills an
/// expectation the moment a record lands.
final class ClaudeContextBrokerIntegrationTests: XCTestCase {
    private var directory: URL!
    private var broker: ClaudeContextBroker!
    private var registry: ClaudeSessionRegistry!

    private var socketPath: String { directory.appendingPathComponent("ctx.sock").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
        registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 5_000_000) },
            isProcessAlive: { _ in true },
            allocateMarkerValue: { "lvx-deadbeef" }
        )
        broker = ClaudeContextBroker(
            socketPath: socketPath,
            registry: registry,
            shouldEmitLocalTitleMarker: { true }
        )
    }

    override func tearDownWithError() throws {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func send(_ line: Data) -> ClaudeHookPublishFailure? {
        UnixSocketPublisher(timeout: 2.0).publish(line: line, to: socketPath)
    }

    /// Collects what the broker handled, so assertions read a stable snapshot.
    private final class IngestCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<ClaudeHookRecord, ClaudeHookWireError>] = []

        func record(_ result: Result<ClaudeHookRecord, ClaudeHookWireError>) {
            lock.lock()
            results.append(result)
            lock.unlock()
        }

        var all: [Result<ClaudeHookRecord, ClaudeHookWireError>] {
            lock.lock()
            defer { lock.unlock() }
            return results
        }
    }

    private func expectIngest(count: Int = 1) -> (XCTestExpectation, IngestCollector) {
        let expectation = expectation(description: "broker handled \(count) record(s)")
        expectation.expectedFulfillmentCount = count
        let collector = IngestCollector()
        broker.debugConfigureIngestHook { result in
            collector.record(result)
            expectation.fulfill()
        }
        return (expectation, collector)
    }

    // MARK: Lifecycle

    func testStartCreatesSocketWith0600AndPrivateDirectory() throws {
        try broker.start()
        XCTAssertTrue(broker.isRunning)

        let socket = try XCTUnwrap(ClaudeSocketGuard.metadata(ofPath: socketPath))
        XCTAssertEqual(socket.mode, 0o600, "the socket must not be reachable by other users")
        XCTAssertEqual(socket.ownerUID, UInt32(geteuid()))

        let dir = try XCTUnwrap(ClaudeSocketGuard.metadata(ofPath: directory.path))
        XCTAssertEqual(dir.mode, 0o700)
    }

    func testStopRemovesSocket() throws {
        try broker.start()
        broker.stop()
        XCTAssertFalse(broker.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testDoubleStartIsRejected() throws {
        try broker.start()
        XCTAssertThrowsError(try broker.start()) { error in
            XCTAssertEqual(error as? ClaudeContextBroker.StartFailure, .alreadyRunning)
        }
    }

    func testStopThenStartAgainWorks() throws {
        // The accept loop owns the listener fd and closes it on the way out.
        // If stop() failed to wake it, the loop would still hold the socket and
        // this rebind would fail — so this is the lifecycle regression for the
        // self-pipe wakeup.
        try broker.start()
        broker.stop()
        XCTAssertNoThrow(try broker.start())
        XCTAssertTrue(broker.isRunning)

        let (expectation, _) = expectIngest()
        let record = ClaudeHookRecord(
            event: .sessionStart, sessionID: "restarted", timestamp: 1, rawCwd: "/repo"
        )
        XCTAssertNil(send(try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))))
        wait(for: [expectation], timeout: 5)
        XCTAssertNotNil(registry.snapshot(sessionID: "restarted"))
    }

    func testStopIsIdempotent() throws {
        try broker.start()
        broker.stop()
        XCTAssertNoThrow(broker.stop())
        XCTAssertFalse(broker.isRunning)
    }

    func testStopWithNoConnectionEverMadeStillReturns() throws {
        // The accept loop is parked in poll() with nothing pending — exactly
        // the state where a wakeup that relied on shutdown()/close() alone
        // would leave it blocked forever.
        try broker.start()
        broker.stop()
        XCTAssertFalse(broker.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: Marker roundtrip — the focus join

    func testBrokerRepliesWithTheAllocatedMarkerForANonHerdrRecord() throws {
        try broker.start()
        let record = ClaudeHookRecord(
            event: .sessionStart, sessionID: "joined", timestamp: 1, rawCwd: "/repo"
        )
        let line = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))

        let result = UnixSocketPublisher(timeout: 2.0)
            .publishAndReadReply(line: line, to: socketPath)
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }
        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(reply)))
        XCTAssertEqual(response.marker, "lvx-deadbeef", "the reply carries the marker the BROKER minted")

        // And it is the same marker the registry indexed — that identity is the
        // whole focus join.
        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "joined"))
        XCTAssertEqual(snapshot.marker.value, response.marker)
        guard case .resolved = registry.resolve(marker: ClaudeSessionMarker(value: "lvx-deadbeef")) else {
            return XCTFail("the replied marker must resolve back to the session")
        }
    }

    func testBrokerWithholdsTheMarkerForAHerdrHostedRecord() throws {
        // Even with title fallback opted in, herdr intercepts OSC 2 inside the
        // pane, so emitting this marker could never identify Ghostty's surface.
        try broker.start()
        let record = ClaudeHookRecord(
            event: .sessionStart,
            sessionID: "herdr-hosted",
            timestamp: 1,
            rawCwd: "/repo",
            process: ClaudeHookProcessInfo(
                hookPID: 31_337,
                claudePID: getpid(),
                herdrPaneID: "pane-7",
                herdrSocketPath: "/tmp/herdr.sock"
            )
        )
        let result = UnixSocketPublisher(timeout: 2.0).publishAndReadReply(
            line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record)),
            to: socketPath
        )
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }

        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(reply)))
        XCTAssertNil(response.marker)
        XCTAssertEqual(
            registry.snapshot(sessionID: "herdr-hosted")?.marker,
            ClaudeSessionMarker(value: "lvx-deadbeef"),
            "herdr changes reply emission only; registry identity remains allocated"
        )
    }

    func testBrokerWithholdsTheMarkerForAnOpencodeRecord() throws {
        // The herdr rule, per agent: opencode rewrites its own OSC titles
        // mid-turn (and clears them on exit), so a marker sent there could
        // never survive in a title — and the plugin never writes to the
        // terminal anyway. Allocation is unchanged; only emission is gated.
        try broker.start()
        let record = ClaudeHookRecord(
            event: .sessionStart,
            agent: .opencode,
            sessionID: "ses_1",
            timestamp: 1,
            rawCwd: "/repo",
            process: ClaudeHookProcessInfo(hookPID: 4242, claudePID: getpid())
        )
        let result = UnixSocketPublisher(timeout: 2.0).publishAndReadReply(
            line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record)),
            to: socketPath
        )
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }

        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(reply)))
        XCTAssertNil(response.marker)
        XCTAssertEqual(
            registry.snapshot(sessionID: "opencode:ses_1")?.marker,
            ClaudeSessionMarker(value: "lvx-deadbeef"),
            "agent gating changes reply emission only; the scoped session keeps its registry marker"
        )
    }

    func testBrokerEchoesAV1RequestsVersionSoAStalePublisherKeepsItsMarker() throws {
        // Mixed-version end-to-end (review C4): a machine can run an OLD
        // installed plugin (v1 publisher binary) against a NEW app. The old
        // publisher rejects any reply that does not say v1, so the broker must
        // shape each reply as the REQUEST's version — or every stale install
        // silently loses the marker channel until it updates.
        try broker.start()
        let v1Line = Data(
            (#"{"v":1,"event":"SessionStart","session_id":"old-publisher","ts":1,"cwd":"/repo"}"# + "\n").utf8
        )
        let result = UnixSocketPublisher(timeout: 2.0)
            .publishAndReadReply(line: v1Line, to: socketPath)
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }
        let raw = try XCTUnwrap(reply)
        XCTAssertTrue(
            String(decoding: raw, as: UTF8.self).contains(#""v":1"#),
            "the reply must be v1-shaped for a v1 request"
        )
        // And it still round-trips through the response codec with the marker.
        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(raw))
        XCTAssertEqual(response.version, 1)
        XCTAssertEqual(response.marker, "lvx-deadbeef")

        // A v2 request gets a v2-shaped reply.
        let v2Record = ClaudeHookRecord(event: .stop, sessionID: "old-publisher", timestamp: 2)
        let v2Result = UnixSocketPublisher(timeout: 2.0).publishAndReadReply(
            line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(v2Record)),
            to: socketPath
        )
        guard case .success(let v2Reply) = v2Result else {
            return XCTFail("publish failed: \(v2Result)")
        }
        let v2Response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(v2Reply)))
        XCTAssertEqual(v2Response.version, 2)
    }

    func testOpencodeRecordClaimingAForeignPidIsRejectedByThePeerPidCheck() throws {
        // The opencode plugin runs inside the agent process and dials the
        // socket from it, so the kernel's peer pid must equal the record's
        // claimed pid. This connection comes from the TEST process, so a
        // claim of pid 1 is a forgery and must not reach the registry.
        try broker.start()
        let forged = ClaudeHookRecord(
            event: .sessionStart,
            agent: .opencode,
            sessionID: "ses_forged",
            timestamp: 1,
            rawCwd: "/repo",
            process: ClaudeHookProcessInfo(hookPID: 1, claudePID: 1)
        )
        let result = UnixSocketPublisher(timeout: 2.0).publishAndReadReply(
            line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(forged)),
            to: socketPath
        )
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }
        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(reply)))
        XCTAssertNil(response.marker)
        XCTAssertEqual(response.accepted, false, "the pid cross-check is a rejection and must say so")
        XCTAssertNil(
            registry.snapshot(sessionID: "opencode:ses_forged"),
            "a pid-forged opencode record must never reach the registry"
        )
    }

    func testRejectedRecordRepliesWithNoMarker() throws {
        // A reply still comes back so the publisher is not left waiting, but it
        // carries nothing to put in a title — and says the record was refused.
        try broker.start()
        let result = UnixSocketPublisher(timeout: 2.0)
            .publishAndReadReply(line: Data("{not json}\n".utf8), to: socketPath)
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }
        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(reply)))
        XCTAssertNil(response.marker)
        XCTAssertEqual(response.accepted, false)
    }

    // MARK: Acceptance verdict — the reply says what actually happened

    func testRegistryRejectedFocusDeclarationRepliesNotAccepted() throws {
        // The gap #209 documented as residual: a FocusChanged for a session
        // the registry has never seen is refused by the registry, but the
        // reply used to be shape-identical to success — the opencode plugin
        // advanced its focus state and heartbeat-suppressed the retry for
        // 20s, so a fresh session could dictate with the PREVIOUS session's
        // context. The reply now carries the verdict.
        try broker.start()
        let declaration = ClaudeHookRecord(
            event: .focusChanged,
            agent: .opencode,
            sessionID: "ses_unseen",
            timestamp: 1,
            process: ClaudeHookProcessInfo(hookPID: 4242, claudePID: getpid(), tty: "/dev/ttys004")
        )
        let result = UnixSocketPublisher(timeout: 2.0).publishAndReadReply(
            line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(declaration)),
            to: socketPath
        )
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }
        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(reply)))
        XCTAssertEqual(
            response.accepted, false,
            "a registry-refused declaration must not read as delivered"
        )
    }

    func testCommittedRecordAndValidFocusDeclarationReplyAccepted() throws {
        try broker.start()
        // A committed regular record replies accepted — the positive pin.
        let start = ClaudeHookRecord(
            event: .sessionStart,
            agent: .opencode,
            sessionID: "ses_focus",
            timestamp: 1,
            rawCwd: "/repo",
            process: ClaudeHookProcessInfo(hookPID: 4242, claudePID: getpid())
        )
        let startResult = UnixSocketPublisher(timeout: 2.0).publishAndReadReply(
            line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(start)),
            to: socketPath
        )
        guard case .success(let startReply) = startResult else {
            return XCTFail("publish failed: \(startResult)")
        }
        let startResponse = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(startReply)))
        XCTAssertEqual(startResponse.accepted, true, "a committed record must read as accepted")

        // And a declaration for a session the registry KNOWS is accepted too.
        let declaration = ClaudeHookRecord(
            event: .focusChanged,
            agent: .opencode,
            sessionID: "ses_focus",
            timestamp: 2,
            process: ClaudeHookProcessInfo(hookPID: 4242, claudePID: getpid(), tty: "/dev/ttys004")
        )
        let result = UnixSocketPublisher(timeout: 2.0).publishAndReadReply(
            line: try XCTUnwrap(ClaudeHookWireCodec.encodeLine(declaration)),
            to: socketPath
        )
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }
        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(reply)))
        XCTAssertEqual(response.accepted, true)
    }

    func testPublisherEmitsMarkerOutputWhenLocalTitleFallbackIsEnabled() throws {
        // The end-to-end join through the production publisher entry point.
        try broker.start()
        let json = #"{"hook_event_name":"SessionStart","session_id":"e2e","cwd":"/repo"}"#
        let outcome = ClaudeHookPublisher(
            environment: ClaudeHookPublisher.Environment(
                now: { 1 },
                pid: { 31_337 },
                ppid: { getpid() },
                ttyName: { _ in nil },
                variables: [ClaudeHookSocketPath.environmentKey: socketPath]
            )
        ).run(stdin: Data(json.utf8), fallbackEvent: nil)

        XCTAssertEqual(outcome, .publishedWithMarker("lvx-deadbeef"))
        let stdout = try XCTUnwrap(outcome.stdout)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: stdout) as? [String: Any])
        XCTAssertEqual(object["terminalSequence"] as? String, "\u{1B}]2;lvx-deadbeef\u{07}")
        XCTAssertEqual(object["suppressOutput"] as? Bool, true)
    }

    func testPublisherEmitsNoMarkerOutputWhenLocalTitleFallbackIsDisabled() throws {
        // The broker still ingests and allocates a marker: only the outbound
        // local hook response is gated, so TTY joins retain marker-keyed
        // liveness and the registry remains otherwise unchanged.
        broker = ClaudeContextBroker(
            socketPath: socketPath,
            registry: registry,
            shouldEmitLocalTitleMarker: { false }
        )
        try broker.start()
        let json = #"{"hook_event_name":"SessionStart","session_id":"tty-only","cwd":"/repo"}"#
        let outcome = ClaudeHookPublisher(
            environment: ClaudeHookPublisher.Environment(
                now: { 1 },
                pid: { 31_337 },
                ppid: { getpid() },
                ttyName: { _ in "/dev/ttys003" },
                variables: [ClaudeHookSocketPath.environmentKey: socketPath]
            )
        ).run(stdin: Data(json.utf8), fallbackEvent: nil)

        XCTAssertEqual(outcome, .published)
        XCTAssertNil(outcome.stdout, "OFF must produce no terminalSequence for a local hook")
        XCTAssertEqual(
            registry.snapshot(sessionID: "tty-only")?.marker,
            ClaudeSessionMarker(value: "lvx-deadbeef")
        )
    }

    func testStartRebindsOverAStaleSocketFile() throws {
        // A crashed previous run leaves the socket file behind; bind would fail
        // EADDRINUSE. The directory is verified ours and private, so removing it
        // is safe.
        try ClaudeSocketGuard.prepareDirectory(at: directory.path)
        XCTAssertTrue(FileManager.default.createFile(atPath: socketPath, contents: Data()))
        XCTAssertNoThrow(try broker.start())
    }

    func testStartNeverUnlinksASymlinkAtTheSocketPath() throws {
        try ClaudeSocketGuard.prepareDirectory(at: directory.path)
        let target = directory.appendingPathComponent("target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        try FileManager.default.createSymbolicLink(atPath: socketPath, withDestinationPath: target.path)

        XCTAssertThrowsError(try broker.start()) { error in
            XCTAssertEqual(
                error as? ClaudeContextBroker.StartFailure,
                .socketOwnedByLiveInstance(socketPath)
            )
        }
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: socketPath)
        XCTAssertEqual(destination, target.path, "a suspicious link must never be unlinked")
    }

    // MARK: Ingest

    func testPublisherRecordReachesRegistryWithLocalOrigin() throws {
        try broker.start()
        let (expectation, collector) = expectIngest()

        let record = ClaudeHookRecord(
            event: .userPromptSubmit,
            sessionID: "sess-live",
            timestamp: 1,
            rawCwd: "/repo",
            prompt: "wire up the broker",
            process: ClaudeHookProcessInfo(hookPID: 31_337, claudePID: getpid())
        )
        XCTAssertNil(send(try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))))
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(collector.all.count, 1)
        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "sess-live"))
        XCTAssertEqual(snapshot.latestPriorUserPrompt, "wire up the broker")
        // Origin came from getpeereid on the connection, not from the record.
        XCTAssertEqual(snapshot.origin, .localAuthenticated(peerUID: UInt32(geteuid())))
        XCTAssertEqual(snapshot.localWorkspacePath?.path, "/repo")
        XCTAssertEqual(snapshot.marker, ClaudeSessionMarker(value: "lvx-deadbeef"))
    }

    func testWireOriginFieldCannotForgeTrustOverTheSocket() throws {
        // The end-to-end version of the unit test: even a peer that puts an
        // origin on the wire only ever gets the transport's verdict.
        try broker.start()
        let (expectation, _) = expectIngest()
        let json = #"""
        {"v":1,"event":"SessionStart","session_id":"forge","ts":1,"cwd":"/repo","origin":"remote","peer_uid":0}
        """#
        XCTAssertNil(send(Data((json + "\n").utf8)))
        wait(for: [expectation], timeout: 5)

        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "forge"))
        XCTAssertEqual(snapshot.origin, .localAuthenticated(peerUID: UInt32(geteuid())))
    }

    func testMultipleRecordsOnOneConnectionAreAllIngested() throws {
        try broker.start()
        let (expectation, collector) = expectIngest(count: 2)

        var payload = Data()
        for event in [ClaudeHookEvent.sessionStart, .userPromptSubmit] {
            let record = ClaudeHookRecord(
                event: event, sessionID: "multi", timestamp: 1, rawCwd: "/repo", prompt: "p"
            )
            payload.append(try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record)))
        }
        XCTAssertNil(send(payload))
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(collector.all.count, 2)
    }

    func testMalformedLineIsRejectedWithoutKillingTheBroker() throws {
        try broker.start()
        let (rejected, collector) = expectIngest()
        XCTAssertNil(send(Data("{not json}\n".utf8)))
        wait(for: [rejected], timeout: 5)
        guard case .failure = try XCTUnwrap(collector.all.first) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(registry.liveSessions().isEmpty)

        // Still serving.
        let (accepted, _) = expectIngest()
        let record = ClaudeHookRecord(event: .sessionStart, sessionID: "after", timestamp: 1, rawCwd: "/repo")
        XCTAssertNil(send(try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))))
        wait(for: [accepted], timeout: 5)
        XCTAssertNotNil(registry.snapshot(sessionID: "after"))
    }

    func testUnsupportedVersionIsRejected() throws {
        try broker.start()
        let (expectation, collector) = expectIngest()
        let json = #"{"v":99,"event":"Stop","session_id":"s","ts":1}"#
        XCTAssertNil(send(Data((json + "\n").utf8)))
        wait(for: [expectation], timeout: 5)
        guard case .failure(let error) = try XCTUnwrap(collector.all.first) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertEqual(error, .unsupportedVersion(99))
    }

    /// Regression: the cap is on one LINE, not on how much a peer may send.
    /// Checking the pre-split buffer dropped a connection that delivered
    /// several complete records in one chunk — punishing a publisher for being
    /// efficient, and losing real context.
    func testBatchedRecordsExceedingTheLineCapInAggregateAreAllIngested() throws {
        let wire = ClaudeHookLimits(maxLineBytes: 256)
        broker = ClaudeContextBroker(
            socketPath: socketPath,
            registry: registry,
            limits: ClaudeBrokerLimits(wire: wire)
        )
        try broker.start()
        let (expectation, collector) = expectIngest(count: 4)

        // Four lines, each comfortably under the cap, together well over it.
        var payload = Data()
        for index in 0..<4 {
            let record = ClaudeHookRecord(
                event: .postToolUse,
                sessionID: "batched",
                timestamp: 1,
                rawCwd: "/repo",
                toolName: "Read",
                files: [ClaudeFileTouch(path: "/repo/file\(index).swift", kind: .read)]
            )
            let line = try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record, limits: wire))
            XCTAssertLessThanOrEqual(line.count, wire.maxLineBytes, "each line is individually legal")
            payload.append(line)
        }
        XCTAssertGreaterThan(payload.count, wire.maxLineBytes, "but the batch is not")

        XCTAssertNil(send(payload))
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(collector.all.count, 4)
        let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "batched"))
        XCTAssertEqual(snapshot.recentFiles.count, 4, "no record was lost to the aggregate size")
    }

    func testUnterminatedOverlongLineDropsConnectionWithoutIngest() throws {
        broker = ClaudeContextBroker(
            socketPath: socketPath,
            registry: registry,
            limits: ClaudeBrokerLimits(wire: ClaudeHookLimits(maxLineBytes: 256))
        )
        try broker.start()
        // No newline, well past the cap: the broker must drop the connection
        // rather than grow its buffer forever.
        _ = send(Data(String(repeating: "x", count: 4096).utf8))

        // Prove the broker survived by driving a real record through it. The
        // abusive connection can never reach `handle(line:)` at all — it sends
        // no newline, so no line is ever framed — which is why the session
        // assertion below holds under any interleaving.
        let (expectation, _) = expectIngest()
        let record = ClaudeHookRecord(
            event: .sessionStart, sessionID: "survivor", timestamp: 1, rawCwd: "/repo"
        )
        XCTAssertNil(send(try XCTUnwrap(ClaudeHookWireCodec.encodeLine(record))))
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(
            registry.liveSessions().map(\.sessionID), ["survivor"],
            "the abusive peer must not have produced a session"
        )
        XCTAssertTrue(broker.isRunning, "one abusive peer must not stop the broker")
    }

    func testTricklingPeerIsCutOffAtTheAbsoluteDeadline() throws {
        let base: UInt64 = 1_000_000_000
        let expired = Mutex(false)
        let bytesRead = Mutex(0)
        let firstRead = expectation(description: "broker consumed the first trickle byte")
        broker = ClaudeContextBroker(
            socketPath: socketPath,
            registry: registry,
            limits: ClaudeBrokerLimits(readTimeout: 100),
            uptimeNanos: {
                expired.withLock { $0 ? base + 200_000_000_000 : base }
            }
        )
        broker.debugConfigureReadHook { count in
            let total = bytesRead.withLock { bytes -> Int in
                bytes += count
                return bytes
            }
            expired.withLock { $0 = true }
            if total == count { firstRead.fulfill() }
        }
        try broker.start()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        XCTAssertEqual(
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)),
            0
        )
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)

        var first: UInt8 = 0x7B
        XCTAssertEqual(Darwin.send(fd, &first, 1, 0), 1)
        wait(for: [firstRead], timeout: 5)

        // The first byte advanced the injected monotonic clock beyond the
        // connection deadline. A per-read timeout incorrectly accepts this
        // second trickle byte; an absolute deadline closes before reading it.
        var second: UInt8 = 0x22
        _ = Darwin.send(fd, &second, 1, 0)
        shutdown(fd, SHUT_WR)
        var reply = [UInt8](repeating: 0, count: 16)
        while read(fd, &reply, reply.count) > 0 {}

        XCTAssertEqual(bytesRead.withLock { $0 }, 1)
        XCTAssertTrue(registry.liveSessions().isEmpty)
    }

    // MARK: Publisher fail-open

    func testPublishToAbsentSocketReportsNotListening() {
        // The overwhelmingly common case: app not running. The publisher's
        // caller turns this into a silent exit 0.
        let failure = send(Data("{}\n".utf8))
        XCTAssertEqual(failure, .notListening)
    }

    func testPublishToOverlongSocketPathIsRejectedNotCrashed() {
        let failure = UnixSocketPublisher().publish(
            line: Data("{}\n".utf8),
            to: "/tmp/" + String(repeating: "p", count: 200)
        )
        XCTAssertEqual(failure, .socketPathTooLong)
    }

    func testPublishToEmptyPathIsRejected() {
        XCTAssertEqual(UnixSocketPublisher().publish(line: Data("{}\n".utf8), to: ""), .noSocketPath)
    }
}

/// Lifecycle: binding, stopping, and the stale-vs-live socket question.
///
/// Deterministic without a wall clock. `stop()` waits for the accept loop to
/// exit, so every assertion below is about a state that has actually settled —
/// there is nothing to sleep for and nothing to poll.
final class ClaudeContextBrokerLifecycleTests: XCTestCase {
    private var directory: URL!
    private var brokers: [ClaudeContextBroker] = []

    private var socketPath: String { directory.appendingPathComponent("ctx.sock").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // /tmp, not NSTemporaryDirectory(): sun_path is 104 bytes on Darwin.
        directory = URL(fileURLWithPath: "/tmp/lvx-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws {
        for broker in brokers { broker.stop() }
        brokers = []
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeBroker() -> ClaudeContextBroker {
        let broker = ClaudeContextBroker(
            socketPath: socketPath,
            registry: ClaudeSessionRegistry(
                now: { Date(timeIntervalSince1970: 5_000_000) },
                isProcessAlive: { _ in true },
                allocateMarkerValue: { "lvx-deadbeef" }
            )
        )
        brokers.append(broker)
        return broker
    }

    func testStartBindsAndStopRemovesTheSocket() throws {
        let broker = makeBroker()
        try broker.start()
        XCTAssertTrue(broker.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        broker.stop()

        XCTAssertFalse(broker.isRunning)
        // stop() waits for the accept loop's defer, which is what unlinks. If it
        // did not wait, this would be a race rather than an assertion.
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStopThenStartRebindsWithoutLosingTheSocket() throws {
        let broker = makeBroker()
        try broker.start()
        broker.stop()

        try broker.start()

        // The regression: without stop() waiting for the loop, the outgoing
        // loop's unlink lands AFTER the new bind and deletes the socket out from
        // under a broker that reports itself running. Publishers then get
        // ENOENT forever and nothing logs a thing.
        XCTAssertTrue(broker.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStartIsRefusedWhileAlreadyRunning() throws {
        let broker = makeBroker()
        try broker.start()
        XCTAssertThrowsError(try broker.start()) { error in
            XCTAssertEqual(error as? ClaudeContextBroker.StartFailure, .alreadyRunning)
        }
    }

    func testStopIsIdempotent() throws {
        let broker = makeBroker()
        try broker.start()
        broker.stop()
        broker.stop() // Must not double-close the wake fd or hang on the semaphore.
        XCTAssertFalse(broker.isRunning)
    }

    func testASecondLiveInstanceIsRefusedRatherThanHavingItsSocketStolen() throws {
        let first = makeBroker()
        try first.start()

        let second = makeBroker()

        // The bug this replaces: the old code unlinked unconditionally, so the
        // second instance silently severed the first from every publisher on the
        // machine. The first kept accepting on an unlinked inode and nothing
        // reported a problem.
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(
                error as? ClaudeContextBroker.StartFailure,
                .socketOwnedByLiveInstance(socketPath)
            )
        }
        XCTAssertFalse(second.isRunning)
        XCTAssertTrue(first.isRunning, "the live instance must be untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testAStaleSocketFromACrashedRunIsReplaced() throws {
        // A crashed run leaves the file with nothing listening — connect gets
        // ECONNREFUSED. That, and only that, licenses removing it.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(stale, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(stale, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        // Bound but never listen()ed, then closed: the file survives, nothing
        // answers. Exactly the corpse a crash leaves.
        close(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let broker = makeBroker()
        try broker.start()

        XCTAssertTrue(broker.isRunning, "a stale socket must not block startup forever")
    }

    func testIsSocketLiveDistinguishesALiveBrokerFromAnAbsentPath() throws {
        XCTAssertFalse(
            ClaudeContextBroker.isSocketLive(atPath: socketPath),
            "nothing bound yet — ENOENT is not a live owner"
        )
        let broker = makeBroker()
        try broker.start()
        XCTAssertTrue(ClaudeContextBroker.isSocketLive(atPath: socketPath))
        broker.stop()
        XCTAssertFalse(ClaudeContextBroker.isSocketLive(atPath: socketPath))
    }
}

#endif
