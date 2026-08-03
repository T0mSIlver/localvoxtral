import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// The allowlisted env enrichment a REMOTE hook sends as `X-Lvx-Env-*` headers.
///
/// Two things are being pinned here and they pull in opposite directions:
/// the values must ARRIVE (a join arm that never sees a pane id is a feature
/// that silently does not exist), and they must stay INERT — labels about
/// another machine that no local arm, filesystem call, or liveness probe can
/// ever consume.
final class ClaudeRemoteSessionEnvironmentCodecTests: XCTestCase {
    private func headers(_ pairs: [ClaudeRemoteEnvironmentField: String]) -> [String: String] {
        var result: [String: String] = ["authorization": "Bearer t", "content-length": "2"]
        for (field, value) in pairs { result[field.lowercasedHeaderName] = value }
        return result
    }

    // MARK: Allowlist mapping

    func testEveryFieldHasADistinctUnderscoreFreeHeaderNameUnderOneNamespace() {
        var seen: Set<String> = []
        for field in ClaudeRemoteEnvironmentField.allCases {
            XCTAssertTrue(
                field.headerName.hasPrefix("X-Lvx-Env-"),
                "\(field) must live under the one namespace the shim and parser agree on"
            )
            XCTAssertFalse(
                field.headerName.contains("_"),
                "\(field): underscores fold into hyphens in some readers; do not rely on the difference"
            )
            XCTAssertTrue(
                seen.insert(field.lowercasedHeaderName).inserted,
                "\(field) collides with another field's header name"
            )
        }
        // The allowlist itself: it grows only deliberately, so a silent addition
        // (or removal, which would break a join arm) fails here first.
        XCTAssertEqual(ClaudeRemoteEnvironmentField.allCases.count, 10)
    }

    func testEachFieldRoundTripsThroughItsOwnHeader() throws {
        // One value per field, all distinct, so a mis-wired subscript or a
        // copy-pasted header name shows up as a swapped value rather than as a
        // test that still passes.
        var expected = ClaudeRemoteSessionEnvironment()
        var raw: [ClaudeRemoteEnvironmentField: String] = [:]
        for (index, field) in ClaudeRemoteEnvironmentField.allCases.enumerated() {
            let value = "value-\(index)"
            expected[field] = value
            raw[field] = value
        }
        let parsed = try XCTUnwrap(ClaudeRemoteEnvironmentCodec.environment(in: headers(raw)))
        XCTAssertEqual(parsed, expected)
        XCTAssertFalse(parsed.isEmpty)
    }

    func testNoEnvHeadersMeansNoEnvironmentRatherThanAnEmptyOne() {
        XCTAssertNil(ClaudeRemoteEnvironmentCodec.environment(in: headers([:])))
    }

    func testHeadersOutsideTheAllowlistAreIgnored() {
        var raw = headers([.herdrPaneID: "pane-7"])
        raw["x-lvx-env-anything-else"] = "surprise"
        raw["x-forwarded-for"] = "10.0.0.1"
        let parsed = ClaudeRemoteEnvironmentCodec.environment(in: raw)
        XCTAssertEqual(parsed, ClaudeRemoteSessionEnvironment(herdrPaneID: "pane-7"))
    }

    // MARK: Charset — the header-injection defence

    func testValuesCarryingAnythingOutsideTheCharsetAreDropped() {
        // Every one of these is a value the shim's `case` pattern also refuses.
        // The CR/LF cases are the reason the charset is a whitelist: a value
        // that could carry them would be a header-injection primitive, and this
        // side must not depend on the remote host having checked first.
        let hostile: [(String, String)] = [
            ("CRLF header injection", "pane\r\nX-Evil: 1"),
            ("bare LF", "pane\nX-Evil: 1"),
            ("bare CR", "pane\rX-Evil: 1"),
            ("NUL", "pane\u{0}x"),
            ("other C0 control", "pane\u{7}x"),
            ("ESC", "pane\u{1B}]2;lvx-forged\u{7}"),
            ("space", "pane 7"),
            ("tab", "pane\tsource"),
            ("quote", "pane\"7"),
            ("backslash", "pane\\7"),
            ("dollar", "pane$(id)"),
            ("semicolon", "pane;id"),
            ("non-ASCII", "pane-\u{e9}"),
            ("empty", ""),
        ]
        for (name, value) in hostile {
            XCTAssertFalse(
                ClaudeRemoteEnvironmentCodec.isAcceptableValue(value),
                "\(name) must not be an acceptable value"
            )
            XCTAssertNil(
                ClaudeRemoteEnvironmentCodec.environment(in: headers([.herdrPaneID: value])),
                "\(name) must be dropped, leaving no environment at all"
            )
        }
    }

    func testTheCharsetAcceptsTheShapesRealValuesActuallyTake() {
        // Real examples, so a future tightening that would silently break a
        // join arm fails here instead of in the field.
        let realistic = [
            "%3",                                  // tmux pane
            "/tmp/tmux-1000/default,3721,0",       // $TMUX
            "/dev/pts/3",                          // SSH_TTY
            "/run/user/1000/herdr/default.sock",   // herdr socket
            "pane-7", "srv-01:default", "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
            "user@host", "v1.2.3+build", "12345",
        ]
        for value in realistic {
            XCTAssertTrue(
                ClaudeRemoteEnvironmentCodec.isAcceptableValue(value),
                "\(value) is a shape these variables really take"
            )
        }
    }

    // MARK: Caps

    func testAnOversizedValueIsDroppedWhileItsNeighboursSurvive() throws {
        let limits = ClaudeRemoteEnvironmentLimits.default
        let tooLong = String(repeating: "a", count: limits.maxValueBytes + 1)
        let exactlyAtCap = String(repeating: "b", count: limits.maxValueBytes)
        let parsed = try XCTUnwrap(ClaudeRemoteEnvironmentCodec.environment(
            in: headers([.herdrSocketPath: tooLong, .herdrPaneID: exactlyAtCap])
        ))
        XCTAssertNil(parsed.herdrSocketPath, "over the cap")
        XCTAssertEqual(parsed.herdrPaneID, exactlyAtCap, "the cap is inclusive")
    }

    func testTheTotalByteBudgetIsEnforcedAcrossFields() throws {
        // Four values that each pass alone but cannot all fit. The walk is in
        // `allCases` order, so what survives is deterministic rather than
        // dictionary-order noise — that determinism is the assertion.
        let limits = ClaudeRemoteEnvironmentLimits(
            maxValueBytes: 200, maxFieldCount: 12, maxTotalBytes: 300
        )
        let chunk = String(repeating: "c", count: 200)
        let parsed = try XCTUnwrap(ClaudeRemoteEnvironmentCodec.environment(
            in: headers([
                .herdrPaneID: chunk, .herdrSocketPath: chunk,
                .cmuxSurfaceID: chunk, .sshTTY: "/dev/pts/9",
            ]),
            limits: limits
        ))
        XCTAssertEqual(parsed.herdrPaneID, chunk, "first in allCases order")
        XCTAssertNil(parsed.herdrSocketPath, "would exceed the total budget")
        XCTAssertNil(parsed.cmuxSurfaceID)
        // A later SMALL value still fits: the budget skips what does not fit
        // rather than stopping the walk, so one fat value cannot starve the
        // cheap ones behind it.
        XCTAssertEqual(parsed.sshTTY, "/dev/pts/9")
    }

    func testTheFieldCountCapStopsTheWalk() throws {
        let limits = ClaudeRemoteEnvironmentLimits(maxFieldCount: 2)
        var raw: [ClaudeRemoteEnvironmentField: String] = [:]
        for field in ClaudeRemoteEnvironmentField.allCases { raw[field] = "v" }
        let parsed = try XCTUnwrap(
            ClaudeRemoteEnvironmentCodec.environment(in: headers(raw), limits: limits)
        )
        let kept = ClaudeRemoteEnvironmentField.allCases.filter { parsed[$0] != nil }
        XCTAssertEqual(kept, [.herdrPaneID, .herdrSocketPath])
    }

    func testUnicodeWhitespacePaddingIsRejectedRatherThanTrimmedIntoAcceptance() throws {
        // Review finding: the head parser used to trim with Foundation's
        // UNICODE whitespace set, so `pane-7<NBSP>` arrived here already
        // trimmed to `pane-7` and passed the byte check — a malformed wire
        // value laundered into a well-formed one. Asserted end to end, through
        // the real parser, because the bug lived in the seam between the two.
        let padding = ["\u{A0}", "\u{2007}", "\u{3000}", "\u{200B}"]
        for pad in padding {
            XCTAssertFalse(
                ClaudeRemoteEnvironmentCodec.isAcceptableValue("pane-7" + pad),
                "U+\(String(pad.unicodeScalars.first!.value, radix: 16)) is not ASCII and not whitespace to us"
            )
            var head = "POST /v1/hook/Stop HTTP/1.1\r\nAuthorization: Bearer token\r\n"
            head += "X-Lvx-Env-Herdr-Pane-Id: pane-7\(pad)\r\n"
            head += "Content-Length: 2\r\n\r\n{}"
            let (request, _) = try ClaudeRemoteHTTPCodec.parseRequestHead(Data(head.utf8))
            XCTAssertNil(
                ClaudeRemoteEnvironmentCodec.environment(in: request.headers),
                "a non-ASCII pad must reach the validator and be rejected"
            )
        }
        // The legal ASCII pad is still tolerated — this is OWS, not an attack.
        var head = "POST /v1/hook/Stop HTTP/1.1\r\nAuthorization: Bearer token\r\n"
        head += "X-Lvx-Env-Herdr-Pane-Id:  pane-7 \r\n"
        head += "Content-Length: 2\r\n\r\n{}"
        let (request, _) = try ClaudeRemoteHTTPCodec.parseRequestHead(Data(head.utf8))
        XCTAssertEqual(
            ClaudeRemoteEnvironmentCodec.environment(in: request.headers)?.herdrPaneID, "pane-7"
        )
    }

    // MARK: Agreement with the real HTTP head parser

    func testEnvHeadersSurviveTheRealHeadParserAsWrittenOnTheWire() throws {
        // Not a hand-built dictionary: the exact bytes a shim writes, through
        // `parseRequestHead`, which lowercases names — the one place the two
        // spellings have to agree.
        var head = "POST /v1/hook/SessionStart HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        head += "Authorization: Bearer token\r\n"
        for field in ClaudeRemoteEnvironmentField.allCases {
            head += "\(field.headerName): \(field.rawValue)\r\n"
        }
        head += "Content-Length: 2\r\n\r\n{}"
        let (request, _) = try ClaudeRemoteHTTPCodec.parseRequestHead(Data(head.utf8))
        let parsed = try XCTUnwrap(ClaudeRemoteEnvironmentCodec.environment(in: request.headers))
        for field in ClaudeRemoteEnvironmentField.allCases {
            XCTAssertEqual(parsed[field], field.rawValue, "\(field.headerName) did not survive")
        }
    }
}

/// The invariant the whole PR exists to keep: remote env labels never become
/// local identity.
final class ClaudeRemoteEnvironmentIsolationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 3_000_000)
    private let local = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let remote = ClaudeTransportOrigin.remote(channel: "ssh:host-1")

    private func makeRegistry() -> ClaudeSessionRegistry {
        let epoch = epoch
        return ClaudeSessionRegistry(
            now: { epoch },
            isProcessAlive: { _ in true },
            allocateMarkerValue: { "lvx-\(UUID().uuidString.prefix(8).lowercased())" }
        )
    }

    private func record(
        _ event: ClaudeHookEvent = .sessionStart,
        session: String = "remote:host-1:s1",
        process: ClaudeHookProcessInfo? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            sessionID: session,
            timestamp: 0,
            rawCwd: "/srv/app",
            process: process
        )
    }

    /// A remote host reporting a herdr pane/socket that really does exist on
    /// the Mac. Nothing about the wire distinguishes it from an honest report —
    /// the isolation has to come from where the value is STORED.
    private let collidingEnvironment = ClaudeRemoteSessionEnvironment(
        herdrPaneID: "pane-7",
        herdrSocketPath: "/tmp/herdr-local.sock",
        cmuxSurfaceID: "surface-3",
        hookParentPID: "9001"
    )

    func testRemoteEnvironmentIsStoredAndReadableAsRemoteOnly() throws {
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(
            registry.ingest(record(), origin: remote, environment: collidingEnvironment)
        )
        XCTAssertEqual(snapshot.remoteEnvironment, collidingEnvironment)
        XCTAssertEqual(snapshot.remoteSessionEnvironment, collidingEnvironment)
    }

    func testRemoteEnvironmentNeverPopulatesTheProcessBlock() throws {
        // `process` is what every local arm reads. A remote report must leave
        // it exactly as it was — nil, because the remote body parser has no
        // process field at all.
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(
            registry.ingest(record(), origin: remote, environment: collidingEnvironment)
        )
        XCTAssertNil(snapshot.process, "remote env values must not become process identity")
    }

    func testALocalSessionNeverAbsorbsAnEnvironmentEvenWhenOneIsHandedIn() throws {
        // Defence in depth against a future caller: the reducer decides on the
        // ORIGIN, not on whether an argument was supplied.
        let registry = makeRegistry()
        let snapshot = try XCTUnwrap(registry.ingest(
            record(session: "s-local"), origin: local, environment: collidingEnvironment
        ))
        XCTAssertNil(snapshot.remoteEnvironment)
        XCTAssertNil(snapshot.remoteSessionEnvironment)
    }

    func testTheHerdrArmCannotResolveARemoteSessionThroughItsEnvPaneID() {
        // THE test. A remote host says it is in `pane-7`; the Mac genuinely has
        // a `pane-7`. The local herdr arm must not see the remote session at
        // all — not as a match, not as an ambiguity, not even as stale.
        let registry = makeRegistry()
        registry.ingest(record(), origin: remote, environment: collidingEnvironment)
        XCTAssertEqual(
            registry.resolve(herdrPaneID: "pane-7"), .unknown,
            "a remote env pane id must be invisible to the local herdr arm"
        )
    }

    func testARemoteEnvPaneIDCannotTurnALocalMatchIntoAnAmbiguity() throws {
        // The subtler failure: not claiming the pane, but poisoning it. If the
        // remote session were merely origin-filtered out of the winner set but
        // still counted, the honest local session would abstain forever.
        let registry = makeRegistry()
        registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart,
                sessionID: "s-local",
                timestamp: 0,
                process: ClaudeHookProcessInfo(
                    hookPID: 1, claudePID: 9001, herdrPaneID: "pane-7"
                )
            ),
            origin: local
        )
        registry.ingest(record(), origin: remote, environment: collidingEnvironment)
        guard case .resolved(let snapshot) = registry.resolve(herdrPaneID: "pane-7") else {
            return XCTFail("the local session in that pane must still resolve")
        }
        XCTAssertEqual(snapshot.sessionID, "s-local")
    }

    func testARemoteEnvSocketPathNeverEntersTheLocalHerdrDialSet() {
        // `liveLocalHerdrSocketPaths()` feeds `HerdrSocketClient`, which dials
        // what it is given. A remote-supplied path reaching this set would be
        // the app connecting to a socket named by another machine.
        let registry = makeRegistry()
        registry.ingest(record(), origin: remote, environment: collidingEnvironment)
        XCTAssertTrue(
            registry.liveLocalHerdrSocketPaths().isEmpty,
            "a remote env socket path must never be dialable"
        )
    }

    func testARemoteSessionEnvironmentDoesNotSurviveIntoTheTTYArm() {
        // `SSH_TTY` on the remote host names a device in ITS /dev. The tty arm
        // reads `process.tty`, which a remote record can never populate.
        let registry = makeRegistry()
        registry.ingest(
            record(),
            origin: remote,
            environment: ClaudeRemoteSessionEnvironment(sshTTY: "/dev/ttys004")
        )
        XCTAssertEqual(registry.resolve(tty: "/dev/ttys004"), .unknown)
    }

    func testAnEnvironmentWithNothingUsableLeavesTheSnapshotUntouched() throws {
        let registry = makeRegistry()
        registry.ingest(record(), origin: remote, environment: collidingEnvironment)
        let snapshot = try XCTUnwrap(
            registry.ingest(record(.stop), origin: remote, environment: ClaudeRemoteSessionEnvironment())
        )
        XCTAssertEqual(
            snapshot.remoteEnvironment, collidingEnvironment,
            "an empty report is not a retraction"
        )
    }

    func testTheNewestReportReplacesTheOldOneWholesale() throws {
        // The shim publishes everything it can see on every event, so a field
        // that stopped being reported means the user left that pane. Merging
        // would resurrect it.
        let registry = makeRegistry()
        registry.ingest(record(), origin: remote, environment: collidingEnvironment)
        let snapshot = try XCTUnwrap(registry.ingest(
            record(.stop),
            origin: remote,
            environment: ClaudeRemoteSessionEnvironment(cmuxSurfaceID: "surface-9")
        ))
        // Read through the origin-gated accessor: the assertion is about what a
        // consumer can see, not about the stored field.
        XCTAssertEqual(snapshot.remoteSessionEnvironment?.cmuxSurfaceID, "surface-9")
        XCTAssertNil(snapshot.remoteEnvironment?.herdrPaneID, "a stale pane must not linger")
    }
}
