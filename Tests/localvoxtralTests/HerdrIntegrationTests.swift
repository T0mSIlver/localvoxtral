import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

#if canImport(Darwin)

/// The `integration-herdr` lane: the remote-herdr join machinery against a
/// LIVE `herdr` server, over a REAL `ssh -L` forward, with the app's own
/// production types.
///
/// What is real here: `HerdrSocketClient` on a forwarded unix socket,
/// `ClaudeRemoteHerdrForwardService` spawning a real supervised `ssh -N`,
/// `SSHDestinationCanonicalizer.live()` running real `ssh -G`,
/// `ClaudeRemoteEnrollmentService.configureRemoteHerdrPanel` patching a real
/// `~/.config/herdr/config.toml` over a real ssh session, and
/// `HerdrPanelBindingProbe` / `HerdrPanelMicIndicator` driving all of it.
///
/// The ONE fixture is the focused surface: instead of an accessibility read of
/// a terminal window, the lane reads the typescript of a real herdr client
/// running on a pty. Everything the surface displays was painted by herdr.
///
/// Why this lane exists: `docs/agent/remote-herdr-panel-binding.md` records
/// EXTERNAL assumptions about herdr that the join's trust argument rests on —
/// above all that only a whole-view App client renders the agents sidebar. A
/// herdr upgrade that changes any of them would silently un-authorize (or
/// worse, wrongly authorize) field joins. Each such assumption gets its own
/// named test here so the failure is loud and self-describing.
///
/// Enablement (there is deliberately NO `XCTSkip` — a silent skip is
/// indistinguishable from a pass):
/// - env `HERDR_INTEGRATION_TEST_ENABLE=1`, optional
///   `HERDR_INTEGRATION_TEST_DESTINATION=<ssh destination>`
/// - or the marker file `.herdr-integration-enable.json`, written by
///   `./scripts/remote-build.sh integration-herdr [destination]` because the
///   SSH build gate cannot pass per-command environment variables.
/// Every other lane skips this suite by name.
@MainActor
final class HerdrIntegrationTests: XCTestCase {
    private var fixture: HerdrLiveFixture!

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // localvoxtralTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    override func setUp() async throws {
        try await super.setUp()
        let enablement = try HerdrLaneEnablement.resolve(repoRoot: repoRoot)
        let label = String(name.filter { $0.isLetter || $0.isNumber }.suffix(24))
        fixture = try HerdrLiveFixture.bringUp(
            repoRoot: repoRoot,
            destination: enablement.destination,
            label: label
        )
    }

    override func tearDown() async throws {
        fixture?.tearDown()
        fixture = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Open the app's own supervised `ssh -L` to the fixture's herdr socket.
    /// Nothing here is stubbed: this spawns OpenSSH and waits for the local
    /// end to answer.
    private func openForward(
        spawner: any ClaudeRemoteHerdrForwardSpawning = ClaudeRemoteHerdrForwardSpawner(),
        clock: AcceleratedClock = AcceleratedClock(),
        idleTimeout: TimeInterval = 5 * 60
    ) async throws -> (
        service: ClaudeRemoteHerdrForwardService,
        handle: ClaudeRemoteHerdrForwardHandle
    ) {
        let service = ClaudeRemoteHerdrForwardService(
            spawner: spawner,
            workspaces: ClaudeRemoteHerdrForwardWorkspaces(),
            now: clock.now,
            sleepFor: clock.sleep,
            // Generous next to the production 2 s: this is a cold OpenSSH
            // handshake on a machine that may be running another lane, and a
            // flaky bound would be a flaky lane.
            readinessTimeout: 20,
            idleTimeout: idleTimeout
        )
        guard let handle = await service.open(
            alias: fixture.info.alias,
            remoteSocketPath: fixture.info.socketPath
        ) else {
            throw HerdrLaneError.fixtureFailed(
                "the app's ssh -L forward to \(fixture.info.alias) never became dialable"
            )
        }
        return (service, handle)
    }

    /// Wait until the whole-view surface has painted `token`, reading only
    /// what herdr wrote after `mark`.
    private func waitForToken(
        _ token: String,
        on surface: HerdrSurfaceLog,
        timeout: TimeInterval = 20
    ) async throws {
        try await HerdrLaneWait.until("the surface to paint \(token)", timeout: timeout) {
            surface.textSinceMark()?.contains(token) == true
        }
    }

    private func stamp(
        _ token: String,
        through client: HerdrSocketClient,
        socketPath: String,
        ttl: Int? = HerdrPanelBindingProbe.tokenTTLMilliseconds
    ) async -> Bool {
        await client.reportPanelToken(
            socketPath: socketPath,
            paneID: fixture.info.paneID,
            value: token,
            ttlMilliseconds: ttl
        )
    }

    private static func freshToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return HerdrPanelBindingProbe.token(randomBits: generator.next())
    }

    // MARK: - External assumption: what a whole-view client renders

    /// The positive half of the panel-binding premise: a whole-view App client
    /// renders the configured `$lvmark` row, so a stamped nonce becomes
    /// readable text on the focused surface.
    ///
    /// The stamp travels the production path end to end — real
    /// `HerdrSocketClient`, real forwarded socket, real ssh.
    func testWholeViewClientRendersTheStampedPanelToken() async throws {
        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }

        let client = HerdrSocketClient(timeout: 5)
        let token = Self.freshToken()
        fixture.primarySurface.markCurrentEnd()

        let stamped = await stamp(token, through: client, socketPath: handle.localSocketPath)
        XCTAssertTrue(
            stamped,
            "pane.report_metadata was refused through the forwarded socket"
        )
        try await waitForToken(token, on: fixture.primarySurface)
    }

    /// THE load-bearing external assumption.
    ///
    /// `docs/agent/remote-herdr-panel-binding.md`: herdr's render loop paints
    /// the full UI (sidebar included) for App-mode clients and ONLY the raw
    /// pane for `terminal_attach` / `terminal_observe` clients. That is the
    /// whole reason a grid match proves the surface displays a WHOLE-VIEW
    /// client of the stamped server rather than a single-pane attach.
    ///
    /// If a herdr upgrade ever renders the sidebar in attach mode, the panel
    /// binding stops discriminating and this test is what says so. It asserts
    /// both directions against ONE stamp, so "nothing rendered anywhere"
    /// (a dead fixture) can never look like a pass.
    func testAttachClientRendersNoSidebarSoItCannotEchoThePanelToken() async throws {
        let attachSurface = try fixture.startSurface(
            name: "attach",
            mode: .attach,
            paneID: fixture.info.paneID
        )
        // The attach client has to be connected and painting before the stamp,
        // or its silence would prove nothing.
        try await HerdrLaneWait.until("the attach client to paint its pane") {
            attachSurface.byteCount > 0
        }

        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }

        let client = HerdrSocketClient(timeout: 5)
        let token = Self.freshToken()
        fixture.primarySurface.markCurrentEnd()
        attachSurface.markCurrentEnd()

        let stamped = await stamp(token, through: client, socketPath: handle.localSocketPath)
        XCTAssertTrue(stamped)

        // Positive control first: the whole-view surface DOES render it, so
        // the negative below is about attach mode and not about a fixture
        // that painted nothing at all.
        try await waitForToken(token, on: fixture.primarySurface)

        XCTAssertFalse(
            attachSurface.textSinceMark()?.contains(token) == true,
            """
            A `herdr terminal attach` client rendered the agents-panel token. \
            herdr's App-mode/raw-pane split is what makes a grid match prove \
            the surface displays a whole-view client of the stamped server \
            (docs/agent/remote-herdr-panel-binding.md). If this is the new \
            behavior, the remote-herdr surface authorization argument no \
            longer holds and must be reworked — do not relax this lane.
            """
        )
    }

    // MARK: - External assumption: metadata write semantics

    /// herdr's `PaneReportMetadataParams.tokens` is
    /// `HashMap<String, Option<String>>`, and `normalize_metadata_tokens`
    /// treats BOTH `None` and `""` as a clear. The production teardown path
    /// (`HerdrPanelBindingProbe.clear`) sends JSON null and depends on it;
    /// the empty string is the documented equivalent.
    func testPanelTokenIsClearedByBothNullAndEmptyValues() async throws {
        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }
        let client = HerdrSocketClient(timeout: 5)
        let socketPath = handle.localSocketPath

        let first = Self.freshToken()
        let firstStamped = await stamp(first, through: client, socketPath: socketPath)
        XCTAssertTrue(firstStamped)
        XCTAssertEqual(try fixture.paneTokens()["lvmark"], first)

        // The production clear: a JSON null value, no TTL.
        await HerdrPanelBindingProbe.clear(
            metadata: client,
            socketPath: socketPath,
            paneID: fixture.info.paneID
        )
        XCTAssertNil(
            try fixture.paneTokens()["lvmark"],
            "a null token value must clear the panel entry"
        )

        let second = Self.freshToken()
        let secondStamped = await stamp(second, through: client, socketPath: socketPath)
        XCTAssertTrue(secondStamped)
        XCTAssertEqual(try fixture.paneTokens()["lvmark"], second)

        let clearedByEmptyString = await client.reportPanelToken(
            socketPath: socketPath,
            paneID: fixture.info.paneID,
            value: "",
            ttlMilliseconds: nil
        )
        XCTAssertTrue(clearedByEmptyString)
        XCTAssertNil(
            try fixture.paneTokens()["lvmark"],
            "an empty token value must clear the panel entry too"
        )
    }

    /// The documented TTL window is 1…86_400_000 ms and the production stamp
    /// sits inside it. Pinned at both edges so a herdr change to the bound
    /// fails here rather than as a field abstention.
    func testPanelTokenTTLBoundsAreEnforcedAtTheDocumentedEdges() async throws {
        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }
        let client = HerdrSocketClient(timeout: 5)
        let socketPath = handle.localSocketPath

        let belowMinimum = await stamp(
            Self.freshToken(), through: client, socketPath: socketPath, ttl: 0
        )
        XCTAssertFalse(
            belowMinimum,
            "ttl_ms 0 is below herdr's documented minimum and must be refused"
        )
        let atMinimum = await stamp(
            Self.freshToken(), through: client, socketPath: socketPath, ttl: 1
        )
        XCTAssertTrue(atMinimum)
        let atMaximum = await stamp(
            Self.freshToken(), through: client, socketPath: socketPath, ttl: 86_400_000
        )
        XCTAssertTrue(atMaximum)
        let aboveMaximum = await stamp(
            Self.freshToken(), through: client, socketPath: socketPath, ttl: 86_400_001
        )
        XCTAssertFalse(
            aboveMaximum,
            "ttl_ms above herdr's documented maximum must be refused"
        )
        let productionTTL = await stamp(
            Self.freshToken(),
            through: client,
            socketPath: socketPath,
            ttl: HerdrPanelBindingProbe.tokenTTLMilliseconds
        )
        XCTAssertTrue(
            productionTTL,
            "the production TTL must remain inside herdr's accepted window"
        )
    }

    // MARK: - External assumption: the read surface of the API

    /// `pane.current` and `pane.process_info` decode from the live server into
    /// the shapes the join arm reads. In particular `foreground_processes`
    /// must be PRESENT: the client treats an absent key as "herdr could not
    /// detect a foreground set", which is a different (fail-closed) state.
    func testFocusedPaneAndProcessInfoDecodeFromTheLiveServer() async throws {
        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }
        let client = HerdrSocketClient(timeout: 5)

        guard let pane = await client.focusedPane(socketPath: handle.localSocketPath) else {
            return XCTFail("pane.current returned nothing through the forwarded socket")
        }
        XCTAssertEqual(pane.paneID, fixture.info.paneID)

        guard let info = await client.paneForegroundInfo(
            socketPath: handle.localSocketPath,
            paneID: fixture.info.paneID
        ) else {
            return XCTFail("pane.process_info returned nothing")
        }
        XCTAssertNotNil(info.shellPID, "herdr must still report a shell pid")
        guard let processes = info.foregroundProcesses else {
            return XCTFail(
                "herdr no longer reports foreground_processes; the join's foreground "
                + "cross-check would silently degrade to 'detection unavailable'"
            )
        }
        XCTAssertFalse(processes.isEmpty)
        XCTAssertTrue(
            processes.contains { $0.name?.isEmpty == false },
            "the remote arm identifies the agent by NAME, so a named process must arrive"
        )
    }

    /// `pane.read` returns the joined pane's own text, and a request for a
    /// pane that does not exist returns nothing rather than another pane's
    /// text — the property `SocketPaneScreenContext` depends on.
    func testPaneReadReturnsOnlyTheJoinedPanesText() async throws {
        let sentinel = "LVXHERDRLANE\(Int.random(in: 100_000...999_999))"
        _ = try fixture.herdrCLI(["pane", "send-text", fixture.info.paneID, sentinel])

        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }
        let client = HerdrSocketClient(timeout: 5)

        var text: String?
        for _ in 0..<40 {
            text = await client.paneVisibleText(
                socketPath: handle.localSocketPath,
                paneID: fixture.info.paneID
            )
            if text?.contains(sentinel) == true { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(
            text?.contains(sentinel), true,
            "pane.read did not return the text typed into the joined pane"
        )

        let foreign = await client.paneVisibleText(
            socketPath: handle.localSocketPath,
            paneID: "w99:p99"
        )
        XCTAssertNil(foreign, "a read for an unknown pane must return nothing")
    }

    // MARK: - The app's forward

    /// A dictation leases the forward; the next one reuses it. The lease is
    /// what keeps a second dictation from paying the SSH handshake again, and
    /// releasing the last lease must eventually retire the process — proven
    /// on the injected clock, not on wall time.
    func testForwardLeaseIsReusedAcrossDictationsAndTornDownWhenIdle() async throws {
        let spawner = CountingHerdrForwardSpawner()
        let clock = AcceleratedClock()
        let service = ClaudeRemoteHerdrForwardService(
            spawner: spawner,
            workspaces: ClaudeRemoteHerdrForwardWorkspaces(),
            now: clock.now,
            sleepFor: clock.sleep,
            readinessTimeout: 20,
            idleTimeout: 60
        )

        guard let first = await service.open(
            alias: fixture.info.alias, remoteSocketPath: fixture.info.socketPath
        ) else {
            return XCTFail("the first forward never became dialable")
        }
        guard let second = await service.open(
            alias: fixture.info.alias, remoteSocketPath: fixture.info.socketPath
        ) else {
            return XCTFail("the second dictation could not lease the forward")
        }

        XCTAssertEqual(first.localSocketPath, second.localSocketPath)
        XCTAssertEqual(
            spawner.spawnCount, 1,
            "the second dictation spawned another ssh instead of reusing the lease"
        )

        // Both leases still open: nothing may be torn down.
        first.close()
        XCTAssertTrue(ClaudeRemoteHerdrForwardService.dial(second.localSocketPath))

        let socketPath = second.localSocketPath
        second.close()
        // The idle window is spent on the injected clock; the release itself
        // hops through the main actor, so wait for the observable outcome.
        try await HerdrLaneWait.until("the idle forward to be torn down", timeout: 30) {
            !ClaudeRemoteHerdrForwardService.dial(socketPath)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: - ssh -G canonicalization

    /// The alias fallback resolves both sides through the user's REAL ssh
    /// config and compares `(hostname, port)` — never `user`. Two live
    /// aliases make that concrete: one that differs only in `User` must match,
    /// one that differs in port must not.
    func testSSHDestinationCanonicalizationMatchesThroughRealSSHConfig() async throws {
        let canonicalizer = SSHDestinationCanonicalizer.live()
        let enrolled = Self.enrolledHost(alias: fixture.info.alias)

        let sameHost = await canonicalizer.matchingHosts(
            destination: fixture.info.altUserAlias, enrolledHosts: [enrolled]
        )
        XCTAssertEqual(
            sameHost.map(\.id), [enrolled.id],
            "an alias with the same (hostname, port) but a different User must match; "
            + "comparing the effective user would reject the common build-host shape"
        )

        let otherPort = await canonicalizer.matchingHosts(
            destination: fixture.info.otherPortAlias, enrolledHosts: [enrolled]
        )
        XCTAssertTrue(
            otherPort.isEmpty,
            "an alias resolving to a different port must not match an enrolled host"
        )

        let revoked = await canonicalizer.matchingHosts(
            destination: fixture.info.altUserAlias,
            enrolledHosts: [Self.enrolledHost(alias: fixture.info.alias, revoked: true)]
        )
        XCTAssertTrue(revoked.isEmpty, "a revoked host must never be selected")
    }

    private static func enrolledHost(alias: String, revoked: Bool = false) -> ClaudeRemoteHost {
        ClaudeRemoteHost(
            id: "lvx-herdr-lane-host",
            label: alias,
            sshHostAlias: alias,
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: nil,
            revokedAt: revoked ? Date(timeIntervalSince1970: 1) : nil,
            persistentForwardEnabled: true
        )
    }

    // MARK: - Enrollment-time config patch

    /// The remote config patch, run for real over ssh against a real
    /// `~/.config/herdr/config.toml`: it appends its block exactly once, it
    /// reloads the live server, and it refuses to touch a config that already
    /// carries an agents table — including the trailing-comment header shape
    /// its grep has to recognise.
    func testRemoteHerdrPanelConfigPatchAppendsOnceAndRefusesCustomizedTables() async throws {
        let configPath = fixture.herdrConfigPath
        let original = try String(contentsOfFile: configPath, encoding: .utf8)
        defer {
            try? original.write(toFile: configPath, atomically: true, encoding: .utf8)
            try? fixture.reloadConfig()
        }

        let service = ClaudeRemoteEnrollmentService(
            runner: ClaudeRemoteEnrollmentService.processRunner()
        )
        let alias = fixture.info.alias

        // 1. A config with no agents table: the patch appends and reloads.
        try "[theme]\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        let steps = try service.configureRemoteHerdrPanel(sshHostAlias: alias, timeout: 60)
        XCTAssertEqual(steps.count, 1)
        let patched = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(
            patched.contains(ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet),
            "the panel snippet was not appended to the remote config"
        )
        XCTAssertTrue(patched.hasPrefix("[theme]\n"), "the patch must only APPEND")

        // 2. Idempotence: a second run refuses rather than appending again.
        XCTAssertThrowsError(
            try service.configureRemoteHerdrPanel(sshHostAlias: alias, timeout: 60)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .herdrPanelConfigAlreadyCustomized
            )
        }
        XCTAssertEqual(
            try String(contentsOfFile: configPath, encoding: .utf8), patched,
            "the refused second run must leave the config byte-identical"
        )

        // 3. The trailing-comment header variant its grep must recognise.
        try "[ui.sidebar.agents]   # mine, hands off\n"
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try service.configureRemoteHerdrPanel(sshHostAlias: alias, timeout: 60)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .herdrPanelConfigAlreadyCustomized
            )
        }

        // 4. A bare `rows =` key anywhere is equally off limits.
        try "[ui.sidebar.spaces]\nrows = [[\"workspace\"]]\n"
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try service.configureRemoteHerdrPanel(sshHostAlias: alias, timeout: 60)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .herdrPanelConfigAlreadyCustomized
            )
        }
    }

    // MARK: - The probe and the mic indicator, end to end

    /// The real `HerdrPanelBindingProbe` over the real forward: it matches on
    /// the whole-view surface and abstains on the attach surface, which is the
    /// join decision itself rather than its ingredients.
    func testPanelBindingProbeMatchesWholeViewAndAbstainsOnAttach() async throws {
        let attachSurface = try fixture.startSurface(
            name: "attach", mode: .attach, paneID: fixture.info.paneID
        )
        try await HerdrLaneWait.until("the attach client to paint its pane") {
            attachSurface.byteCount > 0
        }

        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }
        let client = HerdrSocketClient(timeout: 5)
        let target = TerminalScreenTarget(pid: 1, bundleID: "com.mitchellh.ghostty")

        let seenTargets = Mutex<[TerminalScreenTarget]>([])
        let primary = fixture.primarySurface
        primary.markCurrentEnd()
        // The probe's settle ALGEBRA (budget, read cap, abstention causes) is
        // pinned deterministically by HerdrPanelBindingProbeTests. Here the
        // virtual clock advances exactly as production would while the real
        // wait is for herdr to paint a frame — so the lane measures herdr's
        // rendering, never this machine's load.
        let matchClock = SurfaceSettleClock(surface: primary)
        let matching = HerdrPanelBindingProbe(
            metadata: client,
            readGrid: { readTarget in
                seenTargets.withLock { $0.append(readTarget) }
                return primary.textSinceMark()
            },
            now: matchClock.now,
            sleepFor: matchClock.sleep
        )
        let outcome = await matching.probe(
            target: target,
            socketPath: handle.localSocketPath,
            paneID: fixture.info.paneID
        )
        guard case .matched(let match) = outcome else {
            return XCTFail("the panel binding probe did not match a whole-view surface: \(outcome)")
        }
        XCTAssertTrue(match.token.hasPrefix("lv-mic-"))
        XCTAssertEqual(
            seenTargets.withLock { $0.first }, target,
            "the probe must read the target it was given"
        )

        attachSurface.markCurrentEnd()
        let attachClock = SurfaceSettleClock(surface: attachSurface)
        let abstaining = HerdrPanelBindingProbe(
            metadata: client,
            readGrid: { _ in attachSurface.textSinceMark() },
            now: attachClock.now,
            sleepFor: attachClock.sleep
        )
        let attachOutcome = await abstaining.probe(
            target: target,
            socketPath: handle.localSocketPath,
            paneID: fixture.info.paneID
        )
        XCTAssertEqual(
            attachOutcome, .noMatch(.settleTimeout),
            "an attach surface must never authorize a remote herdr join"
        )
    }

    /// The nonce's whole lifecycle against the live server: a match keeps the
    /// token alive as the dictation's mic indicator, and every exit path
    /// clears it before the forward closes.
    func testMicIndicatorRefreshesTheTokenAndClearsItOnStop() async throws {
        // The forward's own clock, with a short idle window: releasing the
        // lease must retire the tunnel, and that is how the test observes that
        // the indicator really closed its handle.
        let forwardClock = AcceleratedClock()
        let (service, handle) = try await openForward(clock: forwardClock, idleTimeout: 60)
        defer { service.stopAllForQuit() }
        let client = HerdrSocketClient(timeout: 5)
        let token = Self.freshToken()
        let stamped = await stamp(token, through: client, socketPath: handle.localSocketPath)
        XCTAssertTrue(stamped)

        // A clock of its own, so the refresh cadence cannot move the forward's
        // idle deadline while the lease is still held.
        let indicatorClock = AcceleratedClock()
        let indicator = HerdrPanelMicIndicator(
            metadata: client,
            socketPath: handle.localSocketPath,
            paneID: fixture.info.paneID,
            token: token,
            forward: handle,
            sleepFor: indicatorClock.sleep
        )
        indicator.start()

        // Clear the token behind the indicator's back; its next refresh must
        // put the same value back — that is what keeps the row lit for a
        // dictation longer than one TTL.
        await HerdrPanelBindingProbe.clear(
            metadata: client, socketPath: handle.localSocketPath, paneID: fixture.info.paneID
        )
        XCTAssertNil(try fixture.paneTokens()["lvmark"])
        try await HerdrLaneWait.until("the mic indicator to refresh the token", timeout: 30) {
            (try? self.fixture.paneTokens()["lvmark"]) == token
        }

        await indicator.stopAndWait()
        // The clear is issued while the forward is still open — it has to be,
        // it travels through it — and only then is the lease released.
        XCTAssertNil(
            try fixture.paneTokens()["lvmark"],
            "stopping the indicator must clear the token before releasing the forward"
        )
        let socketPath = handle.localSocketPath
        try await HerdrLaneWait.until(
            "the forward released by the indicator to be torn down", timeout: 30
        ) {
            !ClaudeRemoteHerdrForwardService.dial(socketPath)
        }
    }

}

// MARK: - Test seams

/// The real spawner, counted. Every `ssh` this starts is a real one; only the
/// bookkeeping is added, so "was the lease reused" is answerable without
/// weakening what the lane exercises.
private final class CountingHerdrForwardSpawner: ClaudeRemoteHerdrForwardSpawning, @unchecked Sendable {
    private let inner = ClaudeRemoteHerdrForwardSpawner()
    private let count = Mutex(0)

    var spawnCount: Int { count.withLock { $0 } }

    func spawn(argv: [String]) throws -> any ClaudeRemoteHerdrForwardProcess {
        count.withLock { $0 += 1 }
        return try inner.spawn(argv: argv)
    }
}

/// The panel probe's clock, decoupled from wall time.
///
/// `now()` advances by exactly what the probe asked to sleep, so the settle
/// budget and read cap behave as they do in production. The REAL wait is for
/// the live surface to paint a frame, bounded — a lane must fail because herdr
/// stopped rendering the token, never because the Mac was busy for a second.
final class SurfaceSettleClock: @unchecked Sendable {
    /// Longest real wait for one frame. Nine of these is the worst case, which
    /// is still seconds, and only the abstaining (no-paint) path pays it.
    static let framePatience: TimeInterval = 0.6

    private let elapsed = Mutex<TimeInterval>(0)
    private let origin = Date()
    private let surface: HerdrSurfaceLog

    init(surface: HerdrSurfaceLog) {
        self.surface = surface
    }

    // `Mutex` is non-copyable, so these closures capture `self` (the class is
    // a reference type and @unchecked Sendable) rather than the lock itself.
    var now: @MainActor @Sendable () -> Date {
        { [self] in origin.addingTimeInterval(elapsed.withLock { $0 }) }
    }

    var sleep: @Sendable (TimeInterval) async -> Void {
        { [self] seconds in
            let before = surface.byteCount
            let deadline = Date().addingTimeInterval(Self.framePatience)
            while Date() < deadline, surface.byteCount == before {
                try? await Task.sleep(for: .milliseconds(20))
            }
            elapsed.withLock { $0 += max(0, seconds) }
        }
    }
}

/// A clock that advances by the FULL requested interval while sleeping only a
/// short real one.
///
/// The forward service polls readiness on this seam, so short sleeps must be
/// honored for real (a live ssh needs actual time to answer). Its idle window
/// is minutes, and a lane must not wait them out — so long sleeps are
/// compressed, and `now()` reports the interval as fully elapsed. Every
/// deadline the service checks is therefore satisfied exactly when it would be
/// in production, without the wall clock in the assertion.
final class AcceleratedClock: @unchecked Sendable {
    /// Sleeps up to this long for real; beyond it, only the virtual clock moves.
    static let realSleepCeiling: TimeInterval = 0.05

    private let elapsed = Mutex<TimeInterval>(0)
    private let origin = Date()

    var now: @Sendable () -> Date {
        { [self] in origin.addingTimeInterval(elapsed.withLock { $0 }) }
    }

    var sleep: @Sendable (TimeInterval) async -> Void {
        { [self] seconds in
            let requested = max(0, seconds)
            let real = min(requested, Self.realSleepCeiling)
            if real > 0 {
                try? await Task.sleep(for: .milliseconds(Int(real * 1000)))
            }
            elapsed.withLock { $0 += requested }
        }
    }
}

#endif
