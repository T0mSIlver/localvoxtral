import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)

private final class PanelMetadataRecorder: HerdrPanelMetadataReporting, @unchecked Sendable {
    struct Report: Equatable {
        var socketPath: String
        var paneID: String
        var value: String?
        var ttlMilliseconds: Int?
    }

    let reports = Mutex<[Report]>([])
    private let results = Mutex<[Bool]>([])

    init(results: [Bool] = []) {
        self.results.withLock { $0 = results }
    }

    func reportPanelToken(
        socketPath: String,
        paneID: String,
        value: String?,
        ttlMilliseconds: Int?
    ) async -> Bool {
        reports.withLock {
            $0.append(Report(
                socketPath: socketPath,
                paneID: paneID,
                value: value,
                ttlMilliseconds: ttlMilliseconds
            ))
        }
        return results.withLock { $0.isEmpty ? true : $0.removeFirst() }
    }
}

private final class PanelIndicatorProcess: ClaudeRemoteHerdrForwardProcess, @unchecked Sendable {
    private let running = Mutex(true)
    let terminationCount = Mutex(0)

    var isRunning: Bool { running.withLock { $0 } }

    func terminate() {
        terminationCount.withLock { $0 += 1 }
        running.withLock { $0 = false }
    }
}

@MainActor
final class HerdrPanelBindingProbeTests: XCTestCase {
    private let target = TerminalScreenTarget(pid: 42, bundleID: "com.mitchellh.ghostty")

    func testProbeStampsFreshBoundedTokenAndMatchesTheFocusedGrid() async throws {
        let metadata = PanelMetadataRecorder()
        var randomValues: [UInt64] = [7, 8]
        let grids = Mutex<[String]>([
            "agents \(HerdrPanelBindingProbe.token(randomBits: 7))",
            "agents \(HerdrPanelBindingProbe.token(randomBits: 8))",
        ])
        let probe = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in grids.withLock { $0.removeFirst() } },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepFor: { _ in XCTFail("a first-read match must not sleep") },
            randomBits: { randomValues.removeFirst() }
        )

        let first = await probe.probe(target: target, socketPath: "/tmp/herdr.sock", paneID: "p1")
        let second = await probe.probe(target: target, socketPath: "/tmp/herdr.sock", paneID: "p1")

        guard case .matched(let firstMatch) = first,
              case .matched(let secondMatch) = second
        else { return XCTFail("both fresh tokens should match") }
        XCTAssertNotEqual(firstMatch.token, secondMatch.token)
        for token in [firstMatch.token, secondMatch.token] {
            XCTAssertTrue(token.hasPrefix("lv-mic-"))
            XCTAssertLessThanOrEqual(token.count, 20)
            XCTAssertTrue(token.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
        }
        XCTAssertEqual(metadata.reports.withLock { $0.map(\.ttlMilliseconds) }, [8_000, 8_000])
    }

    func testProbeMatchesOnTheSecondReadWithoutFurtherPolls() async throws {
        let metadata = PanelMetadataRecorder()
        let token = HerdrPanelBindingProbe.token(randomBits: 9)
        var grids = ["agents", "agents \(token)"]
        let sleeps = Mutex<[TimeInterval]>([])
        let probe = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in grids.removeFirst() },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepFor: { seconds in sleeps.withLock { $0.append(seconds) } },
            randomBits: { 9 }
        )

        let outcome = await probe.probe(
            target: target, socketPath: "/tmp/herdr.sock", paneID: "p1"
        )
        XCTAssertEqual(outcome, .matched(.init(token: token)))
        XCTAssertEqual(sleeps.withLock { $0 }, [HerdrPanelBindingProbe.settleDelay])
        XCTAssertTrue(grids.isEmpty, "the successful second read must be the final poll")
    }

    func testASlowRemoteRenderStillMatchesWithinTheSettleBudget() async throws {
        // The first field dictation (2026-08-09): stamp accepted, row visibly
        // rendering — but over a ProxyJump chain the frame took longer than
        // two 120 ms polls, so the probe abstained with settle-timeout while
        // the user watched the token appear. The loop must keep polling for
        // the whole budget, not a fixed two reads.
        let metadata = PanelMetadataRecorder()
        let token = HerdrPanelBindingProbe.token(randomBits: 21)
        var grids = Array(repeating: "agents", count: 7) + ["agents \(token)"]
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let sleeps = Mutex<[TimeInterval]>([])
        let probe = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in grids.removeFirst() },
            now: { clock.withLock { $0 } },
            sleepFor: { seconds in
                sleeps.withLock { $0.append(seconds) }
                clock.withLock { $0 = $0.addingTimeInterval(seconds) }
            },
            randomBits: { 21 }
        )

        let outcome = await probe.probe(
            target: target, socketPath: "/tmp/herdr.sock", paneID: "p1"
        )
        XCTAssertEqual(outcome, .matched(.init(token: token)))
        XCTAssertEqual(sleeps.withLock { $0.count }, 7)
        XCTAssertTrue(grids.isEmpty)
    }

    func testAFrozenClockIsStillBoundedByTheHardReadCap() async {
        // The budget is the real limit; the cap exists so an injected clock
        // that never advances cannot loop forever.
        let metadata = PanelMetadataRecorder()
        let readCount = Mutex(0)
        let probe = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in
                readCount.withLock { $0 += 1 }
                return "agents panel without the token"
            },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepFor: { _ in },
            randomBits: { 22 }
        )

        let outcome = await probe.probe(
            target: target, socketPath: "/tmp/herdr.sock", paneID: "p1"
        )
        XCTAssertEqual(outcome, .noMatch(.settleTimeout))
        XCTAssertEqual(readCount.withLock { $0 }, HerdrPanelBindingProbe.maxGridReads)
    }

    func testStampRefusalReadsNoGrid() async {
        let metadata = PanelMetadataRecorder(results: [false])
        var readCount = 0
        let probe = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in readCount += 1; return "unused" },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepFor: { _ in },
            randomBits: { 10 }
        )

        let outcome = await probe.probe(
            target: target, socketPath: "/tmp/herdr.sock", paneID: "p1"
        )
        XCTAssertEqual(outcome, .noMatch(.stampRefused))
        XCTAssertEqual(readCount, 0)
    }

    func testUnavailableGridAndSettleTimeoutAreDistinct() async {
        let metadata = PanelMetadataRecorder()
        let unavailable = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in nil },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepFor: { _ in },
            randomBits: { 11 }
        )
        let unavailableOutcome = await unavailable.probe(
            target: target, socketPath: "/tmp/herdr.sock", paneID: "p1"
        )
        XCTAssertEqual(unavailableOutcome, .noMatch(.gridReadUnavailable))

        var readCount = 0
        let timeout = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in readCount += 1; return "no token" },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepFor: { _ in },
            randomBits: { 12 }
        )
        let timeoutOutcome = await timeout.probe(
            target: target, socketPath: "/tmp/herdr.sock", paneID: "p1"
        )
        XCTAssertEqual(timeoutOutcome, .noMatch(.settleTimeout))
        XCTAssertEqual(readCount, HerdrPanelBindingProbe.maxGridReads)
    }

    func testMicIndicatorRefreshesAtFourSecondsThenClearsBeforeClosingForward() async {
        let metadata = PanelMetadataRecorder()
        let process = PanelIndicatorProcess()
        let removed = Mutex(0)
        let forward = ClaudeRemoteHerdrForwardHandle(
            workspace: .init(directoryPath: "/tmp/lvx-panel-test", socketPath: "/tmp/lvx-panel-test/h.sock"),
            process: process,
            removeWorkspace: { _ in removed.withLock { $0 += 1 } }
        )
        let (ticks, tickContinuation) = AsyncStream.makeStream(of: Void.self)
        let intervals = Mutex<[TimeInterval]>([])
        let indicator = HerdrPanelMicIndicator(
            metadata: metadata,
            socketPath: forward.localSocketPath,
            paneID: "p1",
            token: "lv-mic-0000000001",
            forward: forward,
            sleepFor: { seconds in
                intervals.withLock { $0.append(seconds) }
                var iterator = ticks.makeAsyncIterator()
                _ = await iterator.next()
            }
        )

        indicator.start()
        while intervals.withLock({ $0.isEmpty }) { await Task.yield() }
        XCTAssertEqual(intervals.withLock { $0.first }, HerdrPanelMicIndicator.refreshInterval)
        tickContinuation.yield()
        while metadata.reports.withLock({ $0.isEmpty }) { await Task.yield() }

        await indicator.stopAndWait()
        tickContinuation.finish()

        let reports = metadata.reports.withLock { $0 }
        XCTAssertEqual(reports.first?.value, "lv-mic-0000000001")
        XCTAssertEqual(reports.first?.ttlMilliseconds, 8_000)
        XCTAssertNil(reports.last?.value, "teardown must explicitly clear the token")
        XCTAssertNil(reports.last?.ttlMilliseconds)
        XCTAssertEqual(process.terminationCount.withLock { $0 }, 1)
        XCTAssertEqual(removed.withLock { $0 }, 1)

        await indicator.stopAndWait()
        XCTAssertEqual(metadata.reports.withLock { $0.count }, 2, "stop is idempotent")
    }

    func testImmediateIndicatorTeardownCannotRefreshAfterItsClear() async {
        let metadata = PanelMetadataRecorder()
        let process = PanelIndicatorProcess()
        let forward = ClaudeRemoteHerdrForwardHandle(
            workspace: .init(directoryPath: "/tmp/lvx-panel-race", socketPath: "/tmp/lvx-panel-race/h.sock"),
            process: process,
            removeWorkspace: { _ in }
        )
        let (ticks, tickContinuation) = AsyncStream.makeStream(of: Void.self)
        let indicator = HerdrPanelMicIndicator(
            metadata: metadata,
            socketPath: forward.localSocketPath,
            paneID: "p1",
            token: "lv-mic-0000000002",
            forward: forward,
            sleepFor: { _ in
                var iterator = ticks.makeAsyncIterator()
                _ = await iterator.next()
            }
        )

        indicator.start()
        await indicator.stopAndWait()
        tickContinuation.finish()

        XCTAssertEqual(metadata.reports.withLock { $0.count }, 1)
        XCTAssertNil(metadata.reports.withLock { $0.first?.value })
    }
}

#endif
