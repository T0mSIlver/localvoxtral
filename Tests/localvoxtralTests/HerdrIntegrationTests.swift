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
/// `ClaudeRemoteEnrollmentService.setupRemoteHerdr` (the setup run's herdr step) patching a real
/// herdr `config.toml` over a real ssh session (the fixture server's own, never
/// the account's), and
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
        print(
            "[herdr-fixture] token.ttl_ms=\(HerdrPanelBindingProbe.tokenTTLMilliseconds) "
                + "refresh_seconds=\(HerdrPanelMicIndicator.refreshInterval) "
                + "surface_wait_seconds=20"
        )
        let sidebarWidth = fixture.primarySurface.observedSidebarWidth().map(String.init)
            ?? "not-rendered"
        print("[herdr-fixture] sidebar.observed_width=\(sidebarWidth) source=rendered-frame")
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
        print(
            "[herdr-fixture] ssh.forward alias=\(fixture.info.alias) "
                + "local_socket=\(handle.localSocketPath) "
                + "remote_socket=\(fixture.info.socketPath)"
        )
        return (service, handle)
    }

    /// Wait until the whole-view surface has painted `token`, reading only
    /// what herdr wrote after `mark`, and keep the stamp alive the way the
    /// product does while waiting.
    ///
    /// WHY THE REFRESH. `stamp` carries
    /// `HerdrPanelBindingProbe.tokenTTLMilliseconds` (8 s), so one stamp
    /// cannot outlive this wait: at 8 s herdr expires the token and stops
    /// painting it. The old fixture stamped ONCE and then waited `timeout`
    /// (20 s), which meant the real budget was 8 s while the signature — and
    /// every failure message — said 20. On a loaded runner the attach-client
    /// test crossed 8 s often enough to fail 3 of 5 runs (2026-09-05), always
    /// at its positive control, and always as a clean 6 s pass / 24 s timeout
    /// split with nothing in between: the signature of a budget that is not
    /// the one being reported.
    ///
    /// The PRODUCT never relies on a single stamp either.
    /// `HerdrPanelMicIndicator` re-stamps every `refreshInterval` (4 s) for
    /// exactly this reason, so the token is refreshed at half its TTL and
    /// never lapses. The fixture now does the same thing on the same cadence,
    /// which makes `timeout` mean what it says AND makes the fixture model the
    /// product instead of a third behaviour that exists nowhere.
    ///
    /// Wall-clock here is deliberate and matches `HerdrLaneWait.until`, whose
    /// comment explains it: this lane waits on LIVE external processes (herdr,
    /// sshd, a pty) and herdr's own TTL is not a clock this test can inject.
    /// The loop below is `until`'s, plus the refresh — kept here rather than
    /// pushed into the shared helper because only the panel token needs it.
    private func waitForToken(
        _ token: String,
        on surface: HerdrSurfaceLog,
        refreshingThrough client: HerdrSocketClient,
        socketPath: String,
        timeout: TimeInterval = 20
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // First refresh one interval in, exactly like the indicator's loop
        // (`sleepFor(refreshInterval)` and only then `refreshOnce()`).
        var nextRefresh = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval)
        while true {
            if surface.textSinceMark()?.contains(token) == true { return }
            guard Date() < deadline else {
                fixture.dumpSurfaceFrames(reason: "timed out waiting for \(token)")
                throw HerdrLaneError.timedOut("the surface to paint \(token)")
            }
            if Date() >= nextRefresh {
                let refreshed = await stamp(token, through: client, socketPath: socketPath)
                XCTAssertTrue(
                    refreshed,
                    "re-stamping the panel token was refused; the wait below would "
                        + "then be measuring an expired token, not a surface that will not paint"
                )
                if !refreshed {
                    fixture.dumpSurfaceFrames(reason: "panel token refresh was refused")
                }
                nextRefresh = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval)
            }
            try? await Task.sleep(for: .milliseconds(100))
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

    /// The lane's client: production timeout, plus a per-request timing tap
    /// so the load study can attribute failures. Each line lands on stdout
    /// (hence in the lane log): method, latency in ms, outcome, and — on
    /// failure only — the server's error payload verbatim (content-free) or
    /// the local cause. Pane ids and socket paths are never printed.
    private static func makeLaneClient() -> HerdrSocketClient {
        HerdrSocketClient(timeout: 5, latencyRecorder: { method, latencySeconds, success, detail in
            let ms = Int((latencySeconds * 1000).rounded())
            print("[herdr-lane-timing] method=\(method) ms=\(ms) ok=\(success) detail=\(detail)")
        })
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

        let client = Self.makeLaneClient()
        let token = Self.freshToken()
        fixture.primarySurface.markCurrentEnd()

        let stamped = await stamp(token, through: client, socketPath: handle.localSocketPath)
        XCTAssertTrue(
            stamped,
            "pane.report_metadata was refused through the forwarded socket"
        )
        try await waitForToken(
            token,
            on: fixture.primarySurface,
            refreshingThrough: client,
            socketPath: handle.localSocketPath
        )
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

        let client = Self.makeLaneClient()
        let token = Self.freshToken()
        fixture.primarySurface.markCurrentEnd()
        attachSurface.markCurrentEnd()

        let stamped = await stamp(token, through: client, socketPath: handle.localSocketPath)
        XCTAssertTrue(stamped)

        // Positive control first: the whole-view surface DOES render it, so
        // the negative below is about attach mode and not about a fixture
        // that painted nothing at all.
        try await waitForToken(
            token,
            on: fixture.primarySurface,
            refreshingThrough: client,
            socketPath: handle.localSocketPath
        )

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
        let client = Self.makeLaneClient()
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
        let client = Self.makeLaneClient()
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
        let client = Self.makeLaneClient()

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
        let client = Self.makeLaneClient()

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
    /// herdr `config.toml` (the fixture server's own): it appends its block exactly once, it
    /// reloads the live server, and it refuses to touch a config that already
    /// carries an agents table — including the trailing-comment header shape
    /// its grep has to recognise.
    func testRemoteHerdrPanelConfigPatchAppendsOnceAndRefusesCustomizedTables() async throws {
        // Over a caller-supplied destination the patch edits THAT host's real
        // config, which this Mac cannot read back or restore — and when the
        // destination is this very account, that is the config of a herdr a
        // human may be running. Fail before any ssh write instead.
        guard fixture.info.provisionedSSH else {
            XCTFail(
                "the config patch test needs the hermetic loopback sshd (its key forces the "
                    + "fixture's own XDG_CONFIG_HOME); a destination run cannot read back or "
                    + "restore the second host's config"
            )
            return
        }
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
        XCTAssertEqual(try service.setupRemoteHerdr(sshHostAlias: alias, timeout: 60), .configured)
        let patched = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(
            patched.contains(ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet),
            "the panel snippet was not appended to the remote config"
        )
        XCTAssertTrue(patched.hasPrefix("[theme]\n"), "the patch must only APPEND")

        // 2. Idempotence: a second run leaves the table alone rather than appending again.
        XCTAssertEqual(try service.setupRemoteHerdr(sshHostAlias: alias, timeout: 60), .customized)
        XCTAssertEqual(
            try String(contentsOfFile: configPath, encoding: .utf8), patched,
            "the refused second run must leave the config byte-identical"
        )

        // 3. The trailing-comment header variant its grep must recognise.
        try "[ui.sidebar.agents]   # mine, hands off\n"
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(try service.setupRemoteHerdr(sshHostAlias: alias, timeout: 60), .customized)

        // 4. A bare `rows =` key anywhere is equally off limits.
        try "[ui.sidebar.spaces]\nrows = [[\"workspace\"]]\n"
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(try service.setupRemoteHerdr(sshHostAlias: alias, timeout: 60), .customized)
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
        let client = Self.makeLaneClient()
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
        let client = Self.makeLaneClient()
        let token = Self.freshToken()
        let stamped = await stamp(token, through: client, socketPath: handle.localSocketPath)
        XCTAssertTrue(stamped)

        // Hold the refresh behind a deterministic tick. The old accelerated
        // 50 ms sleep let the first refresh race the clear below: on the CI
        // runner it could restore the token before the immediate read, while
        // the builder account happened to complete the clear last.
        let (refreshTicks, refreshContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { refreshContinuation.finish() }
        let refreshIntervals = Mutex<[TimeInterval]>([])
        let indicator = HerdrPanelMicIndicator(
            metadata: client,
            socketPath: handle.localSocketPath,
            paneID: fixture.info.paneID,
            token: token,
            forward: handle,
            sleepFor: { seconds in
                refreshIntervals.withLock { $0.append(seconds) }
                var iterator = refreshTicks.makeAsyncIterator()
                _ = await iterator.next()
            }
        )
        indicator.start()
        try await HerdrLaneWait.until("the mic indicator to arm its refresh sleep") {
            !refreshIntervals.withLock { $0.isEmpty }
        }
        XCTAssertEqual(
            refreshIntervals.withLock { $0.first },
            HerdrPanelMicIndicator.refreshInterval
        )

        // Clear the token behind the indicator's back; its next refresh must
        // put the same value back — that is what keeps the row lit for a
        // dictation longer than one TTL.
        await HerdrPanelBindingProbe.clear(
            metadata: client, socketPath: handle.localSocketPath, paneID: fixture.info.paneID
        )
        try await HerdrLaneWait.until(
            "the deliberately cleared mic token to disappear before refresh", timeout: 5
        ) {
            (try? self.fixture.paneTokens()["lvmark"]) == nil
        }
        refreshContinuation.yield()
        try await HerdrLaneWait.until("the mic indicator to refresh the token", timeout: 30) {
            (try? self.fixture.paneTokens()["lvmark"]) == token
        }

        await indicator.stopAndWait()
        // The clear is issued while the forward is still open — it has to be,
        // it travels through it — and only then is the lease released.
        //
        // The clear is WAITED for, not asserted immediately: the stop's socket
        // request can complete (the server acked it) while a `pane get` read
        // still shows the token. Measured 2026-09-07 on the build host: with
        // one concurrent `swift build`, 1 run in 10 failed the immediate read
        // while every socket request in that run succeeded in ~100 ms
        // (loaded p99 123 ms, max 137 ms over 189 requests — 36× inside the
        // 5 s client timeout, so the timeout is NOT the cause). The read
        // lags the ack under CPU contention; it is not a lost clear.
        //
        // The bound stays BELOW the token TTL (8 s from the last refresh), so
        // a genuinely lost clear still fails loudly instead of passing
        // vacuously on expiry.
        try await HerdrLaneWait.until(
            "the stopped mic indicator's token to clear from the server "
                + "(if the Mac was running worker builds concurrently, that load "
                + "is the first suspect — re-run the lane alone)",
            timeout: 5
        ) {
            (try? self.fixture.paneTokens()["lvmark"]) == nil
        }
        let socketPath = handle.localSocketPath
        try await HerdrLaneWait.until(
            "the forward released by the indicator to be torn down", timeout: 30
        ) {
            !ClaudeRemoteHerdrForwardService.dial(socketPath)
        }
    }

    // MARK: - Federation (herdr 0.9)

    /// `herdr machine list --json` reports `selected: true` for the machine
    /// the client is viewing and no selection when it shows Local — and the
    /// production reader (`HerdrMachineFederationReader` over the fixture's
    /// scratch client dir) resolves the SAME answer. This is the contract the
    /// federated join arm (issue #288) will name its target machine by; if a
    /// herdr upgrade changes what "viewing" means on disk, the arm would
    /// ground dictation in the wrong server and this test is what says so.
    ///
    /// No surface is needed: selection is file state (`load_from_paths`), and
    /// a running client keeps its own selection while the CLI reads the file
    /// fresh — so both states are asserted against the files alone.
    func testFederatedMachineSelectionMatchesBetweenCLIAndProductionReader() async throws {
        let federation = try fixture.federate()
        let reader = Self.federationReader(clientDir: federation.clientDir)
        let expectedProfile = HerdrMachineProfile(
            id: federation.profileID,
            label: federation.label,
            target: federation.target,
            session: federation.session,
            enabled: true
        )

        try fixture.setFederationSelection(profileID: federation.profileID)
        let listedMachine = try fixture.federationMachineList(
            clientStateHome: federation.clientStateHome
        )
        XCTAssertEqual(
            listedMachine.count, 1,
            "the lane federates exactly one machine; an unexpected catalog makes every selection assertion below meaningless"
        )
        XCTAssertTrue(
            listedMachine[0].selected,
            "herdr machine list --json must report selected:true for the machine the client is viewing "
                + "(endpoint-selection.json names \(federation.profileID))"
        )
        XCTAssertEqual(
            reader.federation(), .showingMachine(expectedProfile),
            "the production reader must resolve the same viewed machine herdr's own CLI reports "
                + "(herdr's load_from_paths over the fixture's client dir)"
        )
        guard case .catalog(let catalog) = reader.catalog() else {
            return XCTFail(
                "the production reader must decode the fixture's saved-machine catalog instead of abstaining"
            )
        }
        XCTAssertEqual(
            catalog.selectedProfileID, federation.profileID,
            "the catalog's resolved selection must be the federated profile"
        )

        try fixture.setFederationSelection(profileID: nil)
        let listedLocal = try fixture.federationMachineList(
            clientStateHome: federation.clientStateHome
        )
        XCTAssertEqual(listedLocal.count, 1)
        XCTAssertFalse(
            listedLocal[0].selected,
            "herdr machine list --json must report no selection when the client shows Local "
                + "(selected_profile null)"
        )
        XCTAssertEqual(
            reader.federation(), .showingLocal,
            "the production reader must read Local exactly when herdr's CLI reports no selection"
        )
    }

    /// While a remote machine is selected, the LOCAL server still answers
    /// `pane.current` with its own focused pane. This is the shape behind
    /// issue #286 (the local arm must not trust that answer while a machine
    /// is displayed, but the server must still give it): selection lives in
    /// the CLIENT, so the server's answer must not move with it. If herdr
    /// ever scopes `pane.current` to the viewed machine, the guard's premise
    /// is gone and this test names it.
    func testLocalServerAnswersPaneCurrentWhileFederatedMachineSelected() async throws {
        let federation = try fixture.federate()
        try fixture.setFederationSelection(profileID: federation.profileID)
        // Precondition, not decoration: the local server's answer is
        // selection-independent by construction, so without proving the
        // client is actually viewing the machine this test would green even
        // if federation-select were a silent no-op.
        let listed = try fixture.federationMachineList(
            clientStateHome: federation.clientStateHome
        )
        XCTAssertEqual(
            listed.count, 1,
            "the lane federates exactly one machine; without that the selection assertion below is meaningless"
        )
        XCTAssertTrue(
            listed.first?.selected == true,
            "herdr machine list --json must report selected:true for the federated profile "
                + "before asserting anything about the selected state"
        )

        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }
        let client = Self.makeLaneClient()
        guard let pane = await client.focusedPane(socketPath: handle.localSocketPath) else {
            return XCTFail(
                "pane.current returned nothing through the forwarded socket while a federated "
                    + "machine is selected; the local server must still answer with its own focused pane"
            )
        }
        XCTAssertEqual(
            pane.paneID, fixture.info.paneID,
            "pane.current must describe the LOCAL server's focused pane even while the client "
                + "views a federated machine; a machine-scoped answer would ground the local arm "
                + "in the wrong server"
        )
    }

    /// The 0.9 agents panel composes rows from EVERY federated machine at
    /// once, so a token stamped on the remote machine renders while the
    /// machine is displayed — alongside the local pane's own token. A
    /// rendered token therefore proves the surface FEDERATES the stamped
    /// server, not that it DISPLAYS it: this retires the whole-view App
    /// client discriminator for 0.9 clients (docs/agent/remote-herdr-panel-binding.md).
    func testFederatedAgentsPanelShowsBothMachinesWhileMachineDisplayed() async throws {
        try await checkFederatedAgentsPanelRendersBothMachines(viewingMachine: true)
    }

    /// The mirror direction: with Local displayed, the remote machine's
    /// stamped token still renders next to the local one. Together with the
    /// machine-displayed case this pins that federation composes rather than
    /// switches — the panel is the union of all connected machines, and the
    /// viewed machine is marked by background color only, which a text grid
    /// read cannot see (hence distinct tokens per side here).
    func testFederatedAgentsPanelShowsBothMachinesWhileLocalDisplayed() async throws {
        try await checkFederatedAgentsPanelRendersBothMachines(viewingMachine: false)
    }

    private func checkFederatedAgentsPanelRendersBothMachines(viewingMachine: Bool) async throws {
        let federation = try fixture.federate()
        try fixture.setFederationSelection(
            profileID: viewingMachine ? federation.profileID : nil
        )
        // The selection file is startup state (a running client keeps its
        // own), so the surface starts AFTER the write — mirroring what a UI
        // switch persists, called out as such in the fixture.
        let surface = try fixture.startSurface(
            name: viewingMachine ? "fedmachine" : "fedlocal", mode: .app
        )
        try await HerdrLaneWait.until("the federated client to paint its frame") {
            surface.byteCount > 0
        }
        // The viewed endpoint is marked by background color (invisible to a
        // text read), but the status bar names it in plain text.
        let expectedBarName = viewingMachine ? federation.label : "Local"
        try await HerdrLaneWait.until("the federated client to show \(expectedBarName)") {
            surface.lastRenderedFrame()?.contains("· \(expectedBarName)") == true
        }

        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }
        let client = Self.makeLaneClient()
        let localToken = Self.freshToken()
        let remoteToken = Self.freshToken()
        surface.markCurrentEnd()

        let localStamped = await stamp(
            localToken, through: client, socketPath: handle.localSocketPath
        )
        XCTAssertTrue(localStamped, "stamping the local pane was refused through the forwarded socket")
        let remoteStamped = await stampRemote(
            remoteToken, federation: federation, through: client
        )
        XCTAssertTrue(remoteStamped, "stamping the remote pane was refused")

        // Kept alive the way the product does (see waitForToken): each token
        // carries the 8 s TTL, so both sides are refreshed at the indicator's
        // cadence while the surface paints.
        let deadline = Date().addingTimeInterval(20)
        var nextRefresh = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval)
        while surface.textSinceMark().map({ !$0.contains(localToken) || !$0.contains(remoteToken) }) ?? true {
            guard Date() < deadline else {
                fixture.dumpSurfaceFrames(
                    reason: "timed out waiting for both machines' tokens "
                        + "(viewing \(expectedBarName))"
                )
                throw HerdrLaneError.timedOut("the federated surface to paint both machines' tokens")
            }
            if Date() >= nextRefresh {
                _ = await stamp(localToken, through: client, socketPath: handle.localSocketPath)
                _ = await stampRemote(remoteToken, federation: federation, through: client)
                nextRefresh = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Composition, not union-over-time: the cumulative wait above passes
        // if the tokens painted at different moments (a flapping view, two
        // sequential repaints). The 0.9 panel composes every machine's rows at
        // once — the claim this lane retires the whole-view discriminator on
        // — so require a single frame holding both tokens. Both carry the 8 s
        // TTL refreshed seconds ago, so a composed client still shows them.
        // Bounded like the wait above and re-stamped on the product cadence:
        // a healthy client caught mid-repaint by ONE frame read is a
        // timing-shaped red, not a finding (review-2 NEW-2).
        var composedFrame = surface.lastRenderedFrame()
        let composeDeadline = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval * 2)
        while !(composedFrame?.contains(localToken) == true && composedFrame?.contains(remoteToken) == true),
              Date() < composeDeadline {
            if Date() >= nextRefresh {
                _ = await stamp(localToken, through: client, socketPath: handle.localSocketPath)
                _ = await stampRemote(remoteToken, federation: federation, through: client)
                nextRefresh = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval)
            }
            try? await Task.sleep(for: .milliseconds(100))
            composedFrame = surface.lastRenderedFrame()
        }
        XCTAssertTrue(
            composedFrame?.contains(localToken) == true
                && composedFrame?.contains(remoteToken) == true,
            "the federated surface never painted both machines' tokens in ONE frame "
                + "(viewing \(expectedBarName)): union-over-time is not composition, and the "
                + "whole-view discriminator cannot retire on it"
        )
    }

    /// The agents-panel row comes from the LOCAL client config
    /// (`ClientShellConfig::from_config`): with `[ui.sidebar.agents]`
    /// configured locally and absent on the remote side, a token stamped on
    /// the REMOTE pane still renders on a Local-viewing surface. If herdr
    /// ever renders rows from the machine's own config, the enrollment offer
    /// to patch a remote row becomes load-bearing again and this test names it.
    func testFederatedPanelRowComesFromTheLocalClientConfig() async throws {
        let federation = try fixture.federate()
        // Destination mode records no remote config path (that file lives on
        // the second host), so the row-absence half below cannot run there —
        // the whole file read stays inside this guard, and that gap is the
        // disclosed destination-mode limitation, not a silent pass.
        if fixture.info.provisionedSSH, !federation.remoteConfigPath.isEmpty {
            let remoteConfig = try String(
                contentsOfFile: federation.remoteConfigPath, encoding: .utf8
            )
            XCTAssertFalse(
                remoteConfig.contains("[ui.sidebar.agents]"),
                "the REMOTE herdr config must carry no agents row for this test; the rendered "
                    + "row may only come from the LOCAL client config"
            )
        }
        let localConfig = try String(
            contentsOfFile: fixture.herdrConfigPath, encoding: .utf8
        )
        XCTAssertTrue(
            localConfig.contains("$lvmark"),
            "the LOCAL herdr config must carry the lane's $lvmark row; without it no token could render anywhere"
        )

        try fixture.setFederationSelection(profileID: nil)
        let surface = try fixture.startSurface(name: "fedrowconfig", mode: .app)
        try await HerdrLaneWait.until("the federated client to paint its frame") {
            surface.byteCount > 0
        }

        let client = Self.makeLaneClient()
        let remoteToken = Self.freshToken()
        surface.markCurrentEnd()
        let remoteStamped = await stampRemote(
            remoteToken, federation: federation, through: client
        )
        XCTAssertTrue(remoteStamped, "stamping the remote pane was refused")

        let deadline = Date().addingTimeInterval(20)
        var nextRefresh = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval)
        while surface.textSinceMark()?.contains(remoteToken) != true {
            guard Date() < deadline else {
                fixture.dumpSurfaceFrames(reason: "timed out waiting for the remote token")
                throw HerdrLaneError.timedOut("the surface to paint the remote token from local row config")
            }
            if Date() >= nextRefresh {
                _ = await stampRemote(remoteToken, federation: federation, through: client)
                nextRefresh = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Same composition bar as the both-machines cases: one frame must
        // hold the remote token, not merely the cumulative typescript.
        // Bounded and re-stamped for the same reason as the both-machines
        // cases (review-2 NEW-2).
        var rowFrame = surface.lastRenderedFrame()
        let rowDeadline = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval * 2)
        while rowFrame?.contains(remoteToken) != true, Date() < rowDeadline {
            if Date() >= nextRefresh {
                _ = await stampRemote(remoteToken, federation: federation, through: client)
                nextRefresh = Date().addingTimeInterval(HerdrPanelMicIndicator.refreshInterval)
            }
            try? await Task.sleep(for: .milliseconds(100))
            rowFrame = surface.lastRenderedFrame()
        }
        XCTAssertTrue(
            rowFrame?.contains(remoteToken) == true,
            "the surface never painted the remote token in a single frame; "
                + "union-over-time would not prove the row renders from the local config"
        )
    }

    /// An observer of a stamped pane renders no panel token — sitting next to
    /// the existing `terminal attach` case. herdr's render loop paints the
    /// full UI for App-mode clients and only the raw terminal for
    /// attach/observe clients; this closes the panel-binding doc's
    /// "documented hope" about `terminal_observe` with a live assertion.
    func testObserveClientRendersNoPanelToken() async throws {
        // Version gate only: the observer needs no machine, but this case
        // ships with the federation tests, so on a pre-0.9 herdr it refuses
        // with the required version instead of passing vacuously.
        _ = try fixture.federate()
        let observeSurface = try fixture.startSurface(
            name: "observe", mode: .observe, paneID: fixture.info.paneID
        )
        // The observer prints a frame record only when the pane's screen
        // changes, so an idle pane keeps it silent. Type a sentinel first:
        // seeing it in the records proves the observer is connected to THIS
        // pane, and its later silence about the token proves something. One
        // mark covers both: the stamp itself changes no screen bytes, so any
        // frame in the window shows the pane without the panel.
        let sentinel = "LVXHERDROBSERVE\(Int.random(in: 100_000...999_999))"
        observeSurface.markCurrentEnd()
        _ = try fixture.herdrCLI(["pane", "send-text", fixture.info.paneID, sentinel])
        do {
            try await HerdrLaneWait.until("the observer to paint the typed sentinel") {
                HerdrObserveFrame.plainTexts(sinceMark: observeSurface).joined().contains(sentinel)
            }
        } catch {
            let raw = observeSurface.textSinceMark() ?? "<surface log unavailable>"
            print(
                "[herdr-fixture] OBSERVE DEBUG bytes=\(observeSurface.byteCount) "
                    + "frames=\(HerdrObserveFrame.visibleTexts(sinceMark: observeSurface).count) "
                    + "head=\(String(raw.prefix(500)))"
            )
            throw error
        }

        let (service, handle) = try await openForward()
        defer { handle.close(); service.stopAllForQuit() }

        let client = Self.makeLaneClient()
        let token = Self.freshToken()
        fixture.primarySurface.markCurrentEnd()

        let stamped = await stamp(token, through: client, socketPath: handle.localSocketPath)
        XCTAssertTrue(stamped)

        // Positive control first: the whole-view surface DOES render it, so
        // the negative below is about observe mode and not about a fixture
        // that painted nothing at all.
        try await waitForToken(
            token,
            on: fixture.primarySurface,
            refreshingThrough: client,
            socketPath: handle.localSocketPath
        )

        // Continued-liveness gate: the first sentinel proves the observer WAS
        // connected; a second one typed AFTER the stamp window proves it still
        // is at read time. A dead observer keeps only the old frames — which
        // still contain the first sentinel and still lack the token — so
        // without this the negative below would pass vacuously.
        let postStampSentinel = "LVXHERDROBSERVE2\(Int.random(in: 100_000...999_999))"
        let postStampSend = try fixture.herdrCLI(["pane", "send-text", fixture.info.paneID, postStampSentinel])
        do {
            try await HerdrLaneWait.until("the observer to paint the post-stamp sentinel") {
                HerdrObserveFrame.plainTexts(sinceMark: observeSurface).joined().contains(postStampSentinel)
            }
        } catch {
            // Same diagnostic as the first gate: what the observer DID emit
            // since the mark, so a silent observer can be told apart from a
            // decoder that dropped its records.
            let frames = HerdrObserveFrame.plainTexts(sinceMark: observeSurface)
            let primarySawIt = fixture.primarySurface.textSinceMark()?.contains(postStampSentinel) == true
            print(
                "[herdr-fixture] OBSERVE DEBUG (post-stamp) bytes=\(observeSurface.byteCount) "
                    + "frames=\(frames.count) primarySurfaceShowsSentinel=\(primarySawIt) "
                    + "sendTextOutput=\(String(postStampSend.prefix(300))) "
                    + "lastFrame=\(String((frames.last ?? "").suffix(120)))"
            )
            throw error
        }

        // Escape-stripped raw bytes, frames concatenated: what the observer
        // was SENT, not a screen reconstructed from diff frames (see
        // `HerdrObserveFrame.plainTexts`).
        let observed = HerdrObserveFrame.plainTexts(sinceMark: observeSurface).joined()
        XCTAssertTrue(
            observed.contains(sentinel),
            "the observer lost the pane it proved it had: the typed sentinel painted before "
                + "the stamp is gone from the window, so the negative below would be vacuous"
        )
        XCTAssertTrue(
            observed.contains(postStampSentinel),
            "the observer stopped painting after the stamp window: without post-stamp frames "
                + "the token's absence below proves nothing about observe mode"
        )
        XCTAssertFalse(
            observed.contains(token),
            """
            A `herdr terminal session observe` client rendered the agents-panel token. \
            Observers must render only the raw pane, exactly like `terminal attach` \
            (docs/agent/remote-herdr-panel-binding.md). If this is the new \
            behavior, the remote-herdr surface authorization argument no \
            longer holds and must be reworked — do not relax this lane.
            """
        )
    }

    // MARK: - Federation helpers

    private static func federationReader(clientDir: String) -> HerdrMachineFederationReader {
        HerdrMachineFederationReader(
            clientDirectories: [URL(fileURLWithPath: clientDir, isDirectory: true)],
            readFile: HerdrMachineFederationReader.liveReadFile
        )
    }

    /// Stamp the REMOTE pane's panel token. Hermetic mode dials the remote
    /// server's explicit short socket directly (same box); against a real second host the
    /// stamp travels over ssh instead. Pane ids are scoped to one server, so
    /// the remote id is only ever used with the remote path.
    private func stampRemote(
        _ token: String,
        federation: HerdrFederationInfo,
        through client: HerdrSocketClient,
        ttl: Int = HerdrPanelBindingProbe.tokenTTLMilliseconds
    ) async -> Bool {
        if fixture.info.provisionedSSH {
            return await client.reportPanelToken(
                socketPath: federation.remoteSocketPath,
                paneID: federation.remotePaneID,
                value: token,
                ttlMilliseconds: ttl
            )
        }
        let remoteCommand = "herdr pane report-metadata "
            + "\(federation.remotePaneID) --source localvoxtral --token lvmark=\(token) --ttl-ms \(ttl)"
        let result = try? HerdrLaneProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", "--",
                fixture.info.alias, remoteCommand,
            ],
            currentDirectory: repoRoot
        )
        return result?.succeeded == true
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
