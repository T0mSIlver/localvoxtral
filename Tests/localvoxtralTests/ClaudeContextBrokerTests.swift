import ClaudeContextWire
import ClaudeHookPublisherCore
import Foundation
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
        broker = ClaudeContextBroker(socketPath: socketPath, registry: registry)
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

    func testBrokerRepliesWithTheAllocatedMarker() throws {
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

    func testRejectedRecordRepliesWithNoMarker() throws {
        // A reply still comes back so the publisher is not left waiting, but it
        // carries nothing to put in a title.
        try broker.start()
        let result = UnixSocketPublisher(timeout: 2.0)
            .publishAndReadReply(line: Data("{not json}\n".utf8), to: socketPath)
        guard case .success(let reply) = result else {
            return XCTFail("publish failed: \(result)")
        }
        let response = try XCTUnwrap(ClaudeBrokerResponse.decodeLine(try XCTUnwrap(reply)))
        XCTAssertNil(response.marker)
    }

    func testPublisherEmitsMarkerOutputForALiveBroker() throws {
        // The end-to-end join through the production publisher entry point.
        try broker.start()
        let json = #"{"hook_event_name":"SessionStart","session_id":"e2e","cwd":"/repo"}"#
        let outcome = ClaudeHookPublisher(
            environment: ClaudeHookPublisher.Environment(
                now: { 1 },
                pid: { 31_337 },
                ppid: { getpid() },
                ttyName: { nil },
                variables: [ClaudeHookSocketPath.environmentKey: socketPath]
            )
        ).run(stdin: Data(json.utf8), fallbackEvent: nil)

        XCTAssertEqual(outcome, .publishedWithMarker("lvx-deadbeef"))
        let stdout = try XCTUnwrap(outcome.stdout)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: stdout) as? [String: Any])
        XCTAssertEqual(object["terminalSequence"] as? String, "\u{1B}]2;lvx-deadbeef\u{07}")
        XCTAssertEqual(object["suppressOutput"] as? Bool, true)
    }

    func testStartRebindsOverAStaleSocketFile() throws {
        // A crashed previous run leaves the socket file behind; bind would fail
        // EADDRINUSE. The directory is verified ours and private, so removing it
        // is safe.
        try ClaudeSocketGuard.prepareDirectory(at: directory.path)
        XCTAssertTrue(FileManager.default.createFile(atPath: socketPath, contents: Data()))
        XCTAssertNoThrow(try broker.start())
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

#endif
