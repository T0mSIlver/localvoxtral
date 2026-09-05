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
    let standardErrorLines: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        standardErrorLines = stream
        stderrContinuation = continuation
    }

    var isRunning: Bool { running.withLock { $0 } }
    var processIdentifier: pid_t { 4_243 }

    func waitUntilExit() async -> ClaudeRemoteForwardExitStatus {
        .unavailable
    }

    func terminate() {
        terminationCount.withLock { $0 += 1 }
        running.withLock { $0 = false }
        stderrContinuation.finish()
    }

    func forceTerminate() {
        terminate()
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

    /// herdr renders an agents-panel row through `truncate_end`, so a sidebar
    /// narrower than the token is columns wide replaces its tail with `…`.
    /// Measured on the owner's Mac 2026-09-05 at sidebar width 20: the row was
    /// rendering and the join still abstained "row-not-rendered".
    func testATruncatedRowStillMatchesWhileItCarriesTheEntropyFloor() async {
        let metadata = PanelMetadataRecorder()
        let token = HerdrPanelBindingProbe.token(randomBits: 0xDEAD_BEEF_CAFE_1234)
        let nonce = token.dropFirst(HerdrPanelBindingProbe.tokenPrefix.count)
        let rendered = HerdrPanelBindingProbe.tokenPrefix
            + nonce.prefix(HerdrPanelBindingProbe.minimumRenderedNonceDigits)
            + "…"
        let probe = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in "claude  work\n   \(rendered)" },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepFor: { _ in XCTFail("a first-read match must not sleep") },
            randomBits: { 0xDEAD_BEEF_CAFE_1234 }
        )

        let outcome = await probe.probe(
            target: target, socketPath: "/tmp/herdr.sock", paneID: "p1"
        )

        XCTAssertEqual(outcome, .matched(.init(token: token)))
    }

    /// One digit under the floor is refused, and refused with its OWN cause:
    /// "the row is cut" and "there is no token in the grid" have opposite
    /// fixes, and the join's diagnostics used to collapse them into
    /// `row-not-rendered`, which points the user at the one thing that is
    /// already configured correctly.
    func testATooShortTruncationIsRefusedWithItsOwnCause() async {
        let metadata = PanelMetadataRecorder()
        let token = HerdrPanelBindingProbe.token(randomBits: 0x0123_4567_89AB_CDEF)
        let nonce = token.dropFirst(HerdrPanelBindingProbe.tokenPrefix.count)
        let rendered = HerdrPanelBindingProbe.tokenPrefix
            + nonce.prefix(HerdrPanelBindingProbe.minimumRenderedNonceDigits - 1)
            + "…"
        var readCount = 0
        let probe = HerdrPanelBindingProbe(
            metadata: metadata,
            readGrid: { _ in readCount += 1; return "claude  work\n   \(rendered)" },
            now: { Date(timeIntervalSince1970: 1_000) },
            sleepFor: { _ in XCTFail("a column budget cannot grow while we wait") },
            randomBits: { 0x0123_4567_89AB_CDEF }
        )

        let outcome = await probe.probe(
            target: target, socketPath: "/tmp/herdr.sock", paneID: "p1"
        )

        XCTAssertEqual(outcome, .noMatch(.rowTruncated))
        XCTAssertEqual(readCount, 1, "a too-short row ends the attempt on the first read")
        // The count the operator needs is carried, not just the cause: the
        // shortfall against the floor is how many more columns that row wants.
        XCTAssertEqual(
            HerdrPanelBindingProbe.renderedMatch(
                grid: "claude  work\n   \(rendered)",
                token: token
            ),
            .truncatedTooShort(
                retainedDigits: HerdrPanelBindingProbe.minimumRenderedNonceDigits - 1
            )
        )
    }

    func testRenderedMatchGradesThePrefixItActuallyFound() {
        let token = HerdrPanelBindingProbe.token(randomBits: 0xFEED_FACE_1234_5678)
        let nonce = String(token.dropFirst(HerdrPanelBindingProbe.tokenPrefix.count))

        XCTAssertEqual(
            HerdrPanelBindingProbe.renderedMatch(grid: "x \(token) y", token: token),
            .full
        )
        XCTAssertEqual(
            HerdrPanelBindingProbe.renderedMatch(
                grid: "x \(HerdrPanelBindingProbe.tokenPrefix)\(nonce.prefix(9))… y",
                token: token
            ),
            .truncatedButSufficient(retainedDigits: 9)
        )
        XCTAssertEqual(
            HerdrPanelBindingProbe.renderedMatch(
                grid: "x \(HerdrPanelBindingProbe.tokenPrefix)\(nonce.prefix(3))… y",
                token: token
            ),
            .truncatedTooShort(retainedDigits: 3)
        )
        XCTAssertEqual(
            HerdrPanelBindingProbe.renderedMatch(grid: "no token here", token: token),
            .absent
        )
        // A DIFFERENT token's rendering is not this token's evidence.
        let other = HerdrPanelBindingProbe.token(randomBits: 0x1111_2222_3333_4444)
        XCTAssertEqual(
            HerdrPanelBindingProbe.renderedMatch(grid: "x \(other) y", token: token),
            .absent
        )
        // Nor is one that merely SHARES a long prefix. This is the case a
        // naive prefix search gets wrong: nine of ten digits agree, and
        // accepting it would let one socket's stamp be confirmed by another
        // socket's rendering.
        XCTAssertEqual(
            HerdrPanelBindingProbe.renderedMatch(
                grid: "agents  \(HerdrPanelBindingProbe.token(randomBits: 6))",
                token: HerdrPanelBindingProbe.token(randomBits: 5)
            ),
            .absent
        )
        // The same two tokens, this time genuinely truncated: the run ENDS
        // after eight digits, so it is our token's row and it clears the floor.
        XCTAssertEqual(
            HerdrPanelBindingProbe.renderedMatch(
                grid: "agents  lv-mic-00000000…",
                token: HerdrPanelBindingProbe.token(randomBits: 5)
            ),
            .truncatedButSufficient(retainedDigits: 8)
        )
    }

    /// `row-not-rendered` has four causes this side cannot tell apart, so the
    /// log carries the one fact that separates them in practice — the shape of
    /// the grid that was read, as counts. An 80x24 client cannot show a six-row
    /// agent entry below a workspace list; a 133x50 one can.
    func testGridGeometryReportsTheShapeThatExplainsAMissingRow() {
        let small = ([String](repeating: String(repeating: "x", count: 80), count: 24))
            .joined(separator: "\n")
        XCTAssertEqual(HerdrPanelBindingProbe.gridGeometry(small).rows, 24)
        XCTAssertEqual(HerdrPanelBindingProbe.gridGeometry(small).columns, 80)

        // Ragged input is the normal case: a grid's lines are trimmed of their
        // trailing blanks, so the width is the widest line, not the last one.
        let ragged = "short\nthe widest line here\nmid"
        XCTAssertEqual(HerdrPanelBindingProbe.gridGeometry(ragged).rows, 3)
        XCTAssertEqual(HerdrPanelBindingProbe.gridGeometry(ragged).columns, 20)

        XCTAssertEqual(HerdrPanelBindingProbe.gridGeometry("").rows, 1)
        XCTAssertEqual(HerdrPanelBindingProbe.gridGeometry("").columns, 0)
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
