import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

private final class MemorySSHConfigFileSystem: ClaudeRemoteSSHConfigFileSystem {
    struct Storage: Sendable {
        var state: ClaudeRemoteSSHConfigState
        var createdDirectoryPermissions: [UInt16] = []
        var writes: [(data: Data, permissions: UInt16)] = []
    }

    private let storage: Mutex<Storage>

    init(state: ClaudeRemoteSSHConfigState) {
        storage = Mutex(Storage(state: state))
    }

    var snapshot: Storage { storage.withLock { $0 } }

    func readState() throws -> ClaudeRemoteSSHConfigState {
        storage.withLock { $0.state }
    }

    func createSSHDirectory(permissions: UInt16) throws {
        storage.withLock {
            $0.createdDirectoryPermissions.append(permissions)
            $0.state.directoryExists = true
        }
    }

    func atomicWriteConfig(_ data: Data, permissions: UInt16) throws {
        storage.withLock {
            $0.writes.append((data, permissions))
            $0.state.configData = data
            $0.state.configPermissions = permissions
        }
    }
}

enum ClaudeRemoteRemoteConfigStateFixture {
    static func state(configText: String) -> ClaudeRemoteSSHConfigState {
        ClaudeRemoteSSHConfigState(
            directoryExists: true,
            configData: Data(configText.utf8),
            configPermissions: 0o600,
            directoryPermissions: 0o700
        )
    }
}

final class ClaudeRemoteEnrollmentServiceTests: XCTestCase {
    private let host = ClaudeRemoteHost(
        id: "habc1234",
        label: "buildhost",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: nil,
        revokedAt: nil
    )
    private let token = "tokenAAAABBBBCCCCDDDDEEEEFFFF00001111"

    /// Tests/localvoxtralTests/<this file> → repo root. Derived from the source
    /// path, not the build path, so it resolves on any checkout.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The page the sheet links to. Every caveat that used to ship as a `#`
    /// comment or a Notes bullet is asserted against THIS, so the deletions are
    /// moves rather than losses.
    private func documentation() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/remote-claude-context.md"),
            encoding: .utf8
        )
    }

    private func plan(alias: String = "builder") throws -> ClaudeRemoteEnrollmentService.SetupPlan {
        try ClaudeRemoteEnrollmentService.plan(host: host, sshHostAlias: alias, token: token)
    }

    // MARK: SSH config snippet

    func testSSHSnippetForwardsTheListenerPortBothWays() throws {
        let snippet = try plan().sshConfigSnippet
        XCTAssertTrue(snippet.contains("Host builder"))
        // RemoteForward <remote-port> <local-host>:<local-port> — the remote's
        // 127.0.0.1:8473 comes out of our ssh client and lands on our listener.
        XCTAssertTrue(snippet.contains("RemoteForward 8473 127.0.0.1:8473"))
    }

    func testSSHSnippetUsesTheListenersActualPort() throws {
        // A hardcoded 8473 here that drifted from the listener would produce a
        // tunnel to nothing, and fail open — i.e. silently.
        let port = ClaudeRemoteListenerLimits.default.port
        let snippet = try plan().sshConfigSnippet
        XCTAssertTrue(snippet.contains("RemoteForward \(port) 127.0.0.1:\(port)"))
        XCTAssertNotEqual(port, 8471, "8471 is voxmlx")
        XCTAssertNotEqual(port, 8472, "8472 is polishd")
    }

    func testSSHSnippetDoesNotExitOnForwardFailure() throws {
        // `yes` would refuse the whole SSH session when the remote port is
        // already bound — usually by the user's own second window. A dictation
        // nicety must never cost someone their shell.
        let snippet = try plan().sshConfigSnippet
        XCTAssertTrue(snippet.contains("ExitOnForwardFailure no"))
        XCTAssertFalse(snippet.contains("ExitOnForwardFailure yes"))

        // The cost of `no` — a silently absent tunnel — must still be stated,
        // just not inside the block the user pastes (owner rule, 2026-08-04).
        // It has TWO homes now: the docs page says it in prose, and the in-app
        // check is what actually breaks the silence.
        let documentation = try documentation().lowercased()
        XCTAssertTrue(documentation.contains("exitonforwardfailure"))
        XCTAssertTrue(documentation.contains("silent"))
        XCTAssertTrue(documentation.contains("check setup"))
    }

    /// Asserts every `--config` in `text` is a COMPLETE `port=<digits>`
    /// argument.
    ///
    /// Whole-token, not `hasPrefix`: a prefix check accepts
    /// `--config 'port=28511'garbage` and, worse, `--config 'port=1'token=…`,
    /// which is exactly the shape this assertion exists to forbid (review
    /// finding, 2026-08-04). The token is matched to its closing quote and
    /// then required to be followed by whitespace or end-of-string.
    private func assertEveryConfigArgumentIsThePort(
        in text: String, line: UInt = #line
    ) {
        let key = ClaudeRemoteEnrollmentService.portConfigKey
        for range in text.ranges(of: "--config ") {
            let rest = text[range.upperBound...]
            guard let closing = rest.dropFirst().firstIndex(of: "'") else {
                XCTFail("unterminated --config argument in: \(text)", line: line)
                continue
            }
            let argument = String(rest[rest.startIndex...closing])
            let after = rest[rest.index(after: closing)...]
            // The command may itself be wrapped in the ssh single-quoting, so
            // the closing quote can be followed by the wrapper's CLOSING quote
            // — and by nothing else after that. Accepting any `'` was still too
            // lax: shell concatenation makes `--config 'port=1''token=secret'`
            // one argument, and the earlier check validated `'port=1'`, saw the
            // next quote, and ignored the remainder (review finding,
            // 2026-08-04). So a trailing quote is allowed only when it is the
            // last thing on the line.
            let tail: Substring = after.first == "'" ? after.dropFirst() : after
            XCTAssertTrue(
                after.isEmpty || after.first == " " || after.first == "\n"
                    || (after.first == "'" && (tail.isEmpty || tail.first == " " || tail.first == "\n")),
                "a --config argument must END at its closing quote: \(text)"
            )
            let digits = argument.dropFirst("'\(key)=".count).dropLast()
            XCTAssertTrue(
                argument.hasPrefix("'\(key)=") && !digits.isEmpty
                    && digits.allSatisfy(\.isNumber),
                "the only config this path may write is a numeric port, got \(argument)",
                line: line
            )
        }
    }

    /// The anchoring above is load-bearing, so it gets its own test: these are
    /// the exact shapes a prefix check (and then a lone-quote check) let past.
    func testTheConfigArgumentCheckRejectsSmuggledExtras() {
        let key = ClaudeRemoteEnrollmentService.portConfigKey
        for smuggled in [
            "ssh builder 'claude plugin install ref --config '\(key)=1'\(ClaudeRemoteEnrollmentService.tokenConfigKey)=secret''",
            "ssh builder 'claude plugin install ref --config '\(key)=28511'garbage'",
            "ssh builder 'claude plugin install ref --config '\(key)=28511x''",
            "ssh builder 'claude plugin install ref --config 'token=secret''",
        ] {
            XCTExpectFailure("this shape must be rejected by the anchoring: \(smuggled)") {
                assertEveryConfigArgumentIsThePort(in: smuggled)
            }
        }
    }

    // MARK: Per-Mac remote port (issue #215)

    private func allocatedPlan(
        alias: String = "builder",
        remoteForwardPort: UInt16 = 28511
    ) throws -> ClaudeRemoteEnrollmentService.SetupPlan {
        try ClaudeRemoteEnrollmentService.plan(
            host: host,
            sshHostAlias: alias,
            token: token,
            listenerPort: ClaudeRemoteListenerLimits.default.port,
            remoteForwardPort: remoteForwardPort
        )
    }

    func testTheForwardBindsThisMacsPortRemotelyAndTheListenersPortLocally() throws {
        // The two ports are NOT the same number any more, and confusing them is
        // the whole bug: the remote side is per-Mac, the local side is where
        // this app listens.
        let snippet = try allocatedPlan().sshConfigSnippet
        XCTAssertTrue(
            snippet.contains("RemoteForward 28511 127.0.0.1:\(ClaudeRemoteListenerLimits.default.port)"),
            snippet
        )
        XCTAssertFalse(snippet.contains("RemoteForward 8473"), "the shared bind is what #215 removes")
    }

    func testTheInstallCommandCarriesBothTheTokenAndTheMatchingPort() throws {
        // Two halves of one setting. A block that forwards 28511 while the
        // plugin still posts to 8473 fails open — the silent state this whole
        // change exists to prevent — so they are emitted together, always.
        let install = try XCTUnwrap(allocatedPlan().remoteCommands.last)
        XCTAssertTrue(install.contains("--config '\(ClaudeRemoteEnrollmentService.tokenConfigKey)=\(token)'"))
        XCTAssertTrue(install.contains("--config '\(ClaudeRemoteEnrollmentService.portConfigKey)=28511'"))
        // Repeatable `--config` is documented by `claude plugin install --help`
        // and verified on 2.1.220; a comma-joined single flag is NOT the syntax.
        XCTAssertFalse(install.contains("token=\(token),"))
    }

    func testTheTunnelProbeChecksTheAllocatedPortNotTheLegacyOne() throws {
        // The check must ask about the port THIS Mac forwards. Probing 8473 on
        // a per-Mac install would test a tunnel that does not exist there and
        // report a healthy setup as dead.
        let script = String(
            decoding: ClaudeRemoteEnrollmentService.tunnelProbeScript(remoteForwardPort: 28511),
            as: UTF8.self
        )
        XCTAssertTrue(script.contains("http://127.0.0.1:28511/v1/hook/SessionStart"))
        XCTAssertFalse(script.contains("8473"))
    }

    /// Ported from `testTheForwardProbeDistinguishesConnectionFailureFromBindFailure`.
    ///
    /// The measured fact it defended (2026-08-04, OpenSSH 10.0p2) is unchanged:
    /// a grep for the forwarding warning is wrong at BOTH edges, because this
    /// Mac's own live session holding the port makes a fresh probe fail to bind
    /// while ssh still exits 0, and an unreachable host never requests a forward
    /// at all while ssh exits 255. The app no longer greps for it — it probes
    /// the port, where a healthy contended setup still answers 401 — so what
    /// must still hold is that a connection which never happened is never
    /// reported as a verdict about the port, and that the warning's meaning is
    /// still written down where a user meets it.
    func testAConnectionThatNeverHappenedIsNotAVerdictAboutThePort() throws {
        let check = ClaudeRemoteEnrollmentService.tunnelCheck(
            result: .init(exitCode: 255, message: "ssh: connect to host builder port 22: No route to host"),
            sshHostAlias: "builder",
            remoteForwardPort: 28511,
            listenerIsBound: true
        )
        XCTAssertFalse(check.passed)
        XCTAssertEqual(check.summary, "Could not reach builder over SSH.")
        XCTAssertFalse(
            check.summary.contains("28511"),
            "an unreachable host says nothing about the port, and must not pretend to"
        )
        let documentation = try documentation()
        XCTAssertTrue(
            documentation.contains("A second session to the same host"),
            "a bind failure that is your own second window is healthy — the user still needs that"
        )
        XCTAssertTrue(documentation.lowercased().contains("expected"))
    }

    // MARK: SSH config forward state (review finding 1)

    func testForwardStateReportsWhetherThisHostsBlockAlreadyCarriesThePort() throws {
        let legacy = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "", snippet: try plan().sshConfigSnippet, hostID: host.id
        )
        let filesystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteRemoteConfigStateFixture.state(configText: legacy)
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: filesystem)
        XCTAssertEqual(service.sshConfigForwardsPort(8473, hostID: host.id), true)
        XCTAssertEqual(
            service.sshConfigForwardsPort(28511, hostID: host.id), false,
            "a legacy block does not forward the allocated port, and saying it does is the split brain"
        )
        XCTAssertEqual(
            service.sshConfigForwardsPort(28511, hostID: "hunknown"), false,
            "no block at all is not a match either"
        )
    }

    /// MINOR 1 (review round 3). The check must probe the tunnel that EXISTS,
    /// so it needs three distinguishable answers about the local config, not a
    /// yes/no about one port.
    func testTheConfigReadReportsForwardsAbsentAndUnknownSeparately() throws {
        // (a) a block that forwards a port → that port, whatever it is.
        let legacy = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "", snippet: try plan().sshConfigSnippet, hostID: host.id
        )
        let withBlock = ClaudeRemoteEnrollmentService(
            sshConfigFileSystem: MemorySSHConfigFileSystem(
                state: ClaudeRemoteRemoteConfigStateFixture.state(configText: legacy)
            )
        )
        XCTAssertEqual(withBlock.sshConfigForwardState(hostID: host.id), .forwards(8473))

        let allocated = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "", snippet: try allocatedPlan().sshConfigSnippet, hostID: host.id
        )
        let migrated = ClaudeRemoteEnrollmentService(
            sshConfigFileSystem: MemorySSHConfigFileSystem(
                state: ClaudeRemoteRemoteConfigStateFixture.state(configText: allocated)
            )
        )
        XCTAssertEqual(migrated.sshConfigForwardState(hostID: host.id), .forwards(28511))

        // (b) a readable config with no block for this host.
        let foreign = ClaudeRemoteEnrollmentService(
            sshConfigFileSystem: MemorySSHConfigFileSystem(
                state: ClaudeRemoteRemoteConfigStateFixture.state(
                    configText: "Host other\n    RemoteForward 28511 127.0.0.1:8473\n"
                )
            )
        )
        XCTAssertEqual(
            foreign.sshConfigForwardState(hostID: host.id), .absent,
            "someone else's forward is not this host's block"
        )

        // (c) no seam at all — cannot tell, and must never be guessed either way.
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService().sshConfigForwardState(hostID: host.id), .unknown
        )
    }

    /// The pinned `sshConfigForwardsPort` behaviour is unchanged by the
    /// refactor that added the state read — including its two different nils.
    func testTheBooleanForwardCheckKeepsItsCannotTellSemantics() throws {
        let empty = ClaudeRemoteEnrollmentService(
            sshConfigFileSystem: MemorySSHConfigFileSystem(
                state: ClaudeRemoteSSHConfigState(
                    directoryExists: true, configData: nil, configPermissions: nil
                )
            )
        )
        XCTAssertNil(
            empty.sshConfigForwardsPort(28511, hostID: host.id),
            "no config file yet is cannot-tell, and cannot-tell must regenerate"
        )
    }

    /// A tunnel that is alive on the port the config actually forwards must be
    /// reported as exactly that, plus the one step that fixes it — not as "no
    /// tunnel is live", which is what probing this install's allocation would
    /// have said about a perfectly healthy old tunnel.
    func testAStaleConfigPortIsDiagnosedRatherThanMisreported() throws {
        let up = ClaudeRemoteEnrollmentService.tunnelCheck(
            result: .init(exitCode: 0, message: "LVX_HTTP:401"),
            sshHostAlias: "builder",
            remoteForwardPort: 8473,
            listenerIsBound: true,
            staleAllocatedPort: 28511
        )
        XCTAssertFalse(up.passed, "half the setup is on the other port; that is not a pass")
        XCTAssertTrue(up.summary.contains("8473"))
        XCTAssertTrue(up.summary.lowercased().contains("no longer this mac's port"))
        XCTAssertTrue(try XCTUnwrap(up.hint).contains("28511"))
        XCTAssertTrue(try XCTUnwrap(up.hint).contains("step 1"))

        let down = ClaudeRemoteEnrollmentService.tunnelCheck(
            result: .init(exitCode: 0, message: "LVX_HTTP:000"),
            sshHostAlias: "builder",
            remoteForwardPort: 8473,
            listenerIsBound: true,
            staleAllocatedPort: 28511
        )
        XCTAssertFalse(down.passed)
        XCTAssertTrue(down.summary.contains("8473"))
        XCTAssertTrue(try XCTUnwrap(down.hint).contains("28511"))

        // Without a mismatch, nothing changes.
        let current = ClaudeRemoteEnrollmentService.tunnelCheck(
            result: .init(exitCode: 0, message: "LVX_HTTP:401"),
            sshHostAlias: "builder",
            remoteForwardPort: 28511,
            listenerIsBound: true
        )
        XCTAssertTrue(current.passed)
    }

    func testForwardStateIsUnknownWithoutAFilesystemSeamAndNeverGuessesTrue() throws {
        // nil means cannot tell. Callers must regenerate on nil; a `true` here
        // would let the plugin be pointed at a port nothing forwards.
        XCTAssertNil(ClaudeRemoteEnrollmentService().sshConfigForwardsPort(28511, hostID: host.id))
    }

    func testForwardStateIgnoresARemoteForwardOutsideThisHostsBlock() throws {
        // Someone else's `RemoteForward 28511` elsewhere in the config is not
        // this host's block being current.
        let foreign = "Host other\n    RemoteForward 28511 127.0.0.1:8473\n"
        let filesystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteRemoteConfigStateFixture.state(configText: foreign)
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: filesystem)
        XCTAssertEqual(service.sshConfigForwardsPort(28511, hostID: host.id), false)
    }

    func testTheUpdatePathMigratesAnAlreadyEnrolledHostToTheAllocatedPort() throws {
        // A host enrolled before #215 has no `port` option at all, so its shim
        // posts to 8473 while this Mac has moved. This line is the only fix
        // that does not re-send a credential.
        let runnable = try allocatedPlan().updateCommands.filter { !$0.hasPrefix("#") }
        let migration = try XCTUnwrap(runnable.last)
        XCTAssertTrue(migration.contains("--config '\(ClaudeRemoteEnrollmentService.portConfigKey)=28511'"))
        XCTAssertFalse(migration.contains(token))
        XCTAssertFalse(migration.contains("\(ClaudeRemoteEnrollmentService.tokenConfigKey)="))
    }

    func testRegeneratingReplacesAPreExistingLegacyBlockInPlace() throws {
        // Migration on the config side: an install that already has the shared
        // 8473 block must end up with ONE block on the allocated port — not two
        // `Host builder` stanzas, where OpenSSH takes the first and the stale
        // one silently wins.
        let legacy = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "Host other\n    HostName 10.0.0.9\n",
            snippet: try plan().sshConfigSnippet,
            hostID: host.id
        )
        XCTAssertTrue(legacy.contains("RemoteForward 8473 127.0.0.1:8473"))

        let migrated = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: legacy,
            snippet: try allocatedPlan().sshConfigSnippet,
            hostID: host.id
        )
        XCTAssertTrue(migrated.contains("RemoteForward 28511 127.0.0.1:8473"))
        XCTAssertFalse(migrated.contains("RemoteForward 8473"))
        XCTAssertEqual(
            migrated.components(separatedBy: "Host builder").count - 1, 1,
            "a second stanza would let the stale block win by first-match"
        )
        XCTAssertTrue(migrated.contains("Host other"), "everything outside the block is untouched")

        // And applying the migrated snippet again is a no-op, as before.
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
                to: migrated, snippet: try allocatedPlan().sshConfigSnippet, hostID: host.id
            ),
            migrated
        )
    }

    /// Ported from `testNotesSayHowToGroundSessionsNobodyIsSittingInFrontOf`.
    /// The failure it answers is silent by construction: a harness-spawned
    /// session publishes hooks into a tunnel no interactive ssh is holding.
    func testTheDocsPageSaysHowToGroundSessionsNobodyIsSittingInFrontOf() throws {
        let documentation = try documentation()
        XCTAssertTrue(documentation.contains("Keep the tunnel open"), "name the control, not the concept")
        XCTAssertTrue(documentation.lowercased().contains("remote-control"))
        XCTAssertTrue(documentation.lowercased().contains("t3 code"))
    }

    /// Ported from `testNotesExplainTheTwoHalvesAndTheRemainingSingleTenancy`.
    /// The page cannot name one Mac's allocated port (it has none), so it names
    /// the range and the rule instead — and still states, plainly, what per-Mac
    /// ports do NOT fix.
    func testTheDocsPageExplainsTheTwoHalvesAndTheRemainingSingleTenancy() throws {
        let documentation = try documentation()
        XCTAssertTrue(
            documentation.contains("\(ClaudeRemoteForwardPort.rangeLowerBound)")
                && documentation.contains("\(ClaudeRemoteForwardPort.rangeUpperBound)"),
            "the allocation range is the number a user can actually check against"
        )
        XCTAssertTrue(
            documentation.contains("`port` option") || documentation.contains("`port` names"),
            "the user must know the ssh block and the plugin option are one setting"
        )
        XCTAssertTrue(documentation.lowercased().contains("most recently installed"))
    }

    // MARK: Host alias validation

    func testHostAliasIsValidatedNotEscaped() {
        for alias in ["builder", "build-host", "build.host.local", "user_1", "a1"] {
            XCTAssertTrue(ClaudeRemoteEnrollmentService.isValidHostAlias(alias), "'\(alias)' is an alias")
        }
        // Each of these would change the meaning of the generated config: a
        // space splits `Host` into two patterns, `#` comments out the rest of
        // our block, a newline injects arbitrary directives.
        for alias in [
            "", "two words", "host\nRemoteForward 22 evil:22", "host#comment",
            "host\"quoted\"", "$(whoami)", "a/b", "*", "?", String(repeating: "a", count: 129),
        ] {
            XCTAssertFalse(
                ClaudeRemoteEnrollmentService.isValidHostAlias(alias),
                "'\(alias)' must not be accepted as an alias"
            )
        }
    }

    /// Review finding (PR #197): the charset allowed `-` anywhere, so `-V`
    /// passed validation and reached `ssh`'s argv as an OPTION. OpenSSH then
    /// prints its version and exits 0 without connecting — every step reports
    /// success while nothing ran on any host, which is the worst possible
    /// failure for a setup tool. Reachable on the pre-existing setup path too,
    /// not only on the update path this PR adds.
    func testAnAliasCanNeverBeMistakenForAnSSHOption() {
        for alias in ["-V", "-v", "-oProxyCommand", "--", "-", "-F", ".", "..", "..."] {
            XCTAssertFalse(
                ClaudeRemoteEnrollmentService.isValidHostAlias(alias),
                "'\(alias)' must not be accepted as an alias"
            )
        }
        // Hyphens and dots INSIDE a name stay legal — they are ordinary in real
        // host aliases, and rejecting them would push users off the one-click
        // path for no gain.
        for alias in ["build-host", "build.host.local", "a-1.b_2", "x"] {
            XCTAssertTrue(
                ClaudeRemoteEnrollmentService.isValidHostAlias(alias),
                "'\(alias)' is an ordinary alias"
            )
        }
    }

    func testTheSpawnedArgvTerminatesOptionParsingBeforeTheAlias() throws {
        // Second layer under the validator: whatever reaches argv is positional.
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "")
        })
        try service.executeRemoteSetup(try plan(), sshHostAlias: "builder", token: token)
        try service.executeRemotePluginUpdate(sshHostAlias: "builder")

        for invocation in calls.withLock({ $0 }) {
            let terminator = try XCTUnwrap(invocation.argv.firstIndex(of: "--"))
            let alias = try XCTUnwrap(invocation.argv.firstIndex(of: "builder"))
            XCTAssertLessThan(terminator, alias, "the alias must sit after `--`")
        }
    }

    func testPlanRefusesAnInvalidAlias() {
        XCTAssertThrowsError(try plan(alias: "host\nRemoteForward 22 evil:22")) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .invalidHostAlias
            )
        }
    }

    // MARK: Idempotency

    func testApplyingTheSnippetTwiceIsANoOp() throws {
        let snippet = try plan().sshConfigSnippet
        let existing = """
        Host github.com
            User git
            IdentityFile ~/.ssh/id_ed25519
        """
        let once = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: existing, snippet: snippet, hostID: host.id
        )
        let twice = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: once, snippet: snippet, hostID: host.id
        )
        XCTAssertEqual(once, twice, "a second apply must not append a duplicate Host stanza")
        // A duplicate would be worse than untidy: OpenSSH is first-match-wins,
        // so a stale block above a fresh one silently wins.
        XCTAssertEqual(once.components(separatedBy: "Host builder").count - 1, 1)
    }

    func testApplyingToAnEmptyConfigIsAlsoIdempotent() throws {
        let snippet = try plan().sshConfigSnippet
        let once = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "", snippet: snippet, hostID: host.id
        )
        let twice = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: once, snippet: snippet, hostID: host.id
        )
        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.hasPrefix("# BEGIN localvoxtral claude context (habc1234)"))
    }

    func testUnrelatedConfigIsPreservedByteForByte() throws {
        let snippet = try plan().sshConfigSnippet
        let existing = """
        # my careful notes
        Host github.com
            User git
            IdentityFile ~/.ssh/id_ed25519

        Host prod
            HostName 10.0.0.1
            ProxyJump bastion
        """
        let applied = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: existing, snippet: snippet, hostID: host.id
        )
        XCTAssertTrue(applied.hasPrefix(existing), "nothing above our block may move")
        XCTAssertTrue(applied.contains("ProxyJump bastion"))
        XCTAssertTrue(applied.contains("# my careful notes"))

        // And removing it puts the file back exactly as it was.
        let removed = ClaudeRemoteEnrollmentService.removeSSHConfigSnippet(
            from: applied, hostID: host.id
        )
        XCTAssertEqual(removed.trimmingCharacters(in: .newlines), existing)
    }

    func testOurBlockNeverFusesOntoAnotherHostsStanza() throws {
        // An indented keyword landing under the wrong `Host` is a config change
        // the user did not ask for.
        let snippet = try plan().sshConfigSnippet
        let applied = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "Host prod\n    HostName 10.0.0.1", snippet: snippet, hostID: host.id
        )
        let lines = applied.components(separatedBy: "\n")
        let beginIndex = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("# BEGIN localvoxtral") })
        XCTAssertEqual(lines[beginIndex - 1], "", "a blank line must separate us from the stanza above")
    }

    func testUpdatingTheSnippetReplacesTheBlockInPlace() throws {
        let old = try plan(alias: "old-name").sshConfigSnippet
        let new = try plan(alias: "new-name").sshConfigSnippet
        let applied = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "Host other\n    User x\n", snippet: old, hostID: host.id
        )
        let updated = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: applied, snippet: new, hostID: host.id
        )
        XCTAssertTrue(updated.contains("Host new-name"))
        XCTAssertFalse(updated.contains("Host old-name"))
        XCTAssertTrue(updated.contains("Host other"))
    }

    func testRemovingAnAbsentBlockChangesNothing() {
        let existing = "Host prod\n    HostName 10.0.0.1\n"
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService.removeSSHConfigSnippet(from: existing, hostID: "hnope"),
            existing
        )
    }

    func testTwoHostsGetIndependentBlocks() throws {
        let second = ClaudeRemoteHost(
            id: "hdef5678", label: "other", createdAt: host.createdAt, lastSeenAt: nil, revokedAt: nil
        )
        let firstSnippet = try plan(alias: "builder").sshConfigSnippet
        let secondSnippet = try ClaudeRemoteEnrollmentService.plan(
            host: second, sshHostAlias: "other", token: token
        ).sshConfigSnippet

        var config = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "", snippet: firstSnippet, hostID: host.id
        )
        config = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: config, snippet: secondSnippet, hostID: second.id
        )
        XCTAssertTrue(config.contains("Host builder"))
        XCTAssertTrue(config.contains("Host other"))

        // Removing one must leave the other alone.
        let pruned = ClaudeRemoteEnrollmentService.removeSSHConfigSnippet(from: config, hostID: host.id)
        XCTAssertFalse(pruned.contains("Host builder"))
        XCTAssertTrue(pruned.contains("Host other"))
    }

    // MARK: Remote commands

    func testRemoteSetupGoesThroughTheClaudePluginCLI() throws {
        // Never by hand-editing the remote's ~/.claude/settings.json: that file
        // is the user's, Claude Code owns its schema, and the CLI is the
        // supported interface.
        let commands = try plan().remoteCommands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(
            commands[0],
            "claude plugin marketplace add \(ClaudeRemoteEnrollmentService.repositoryMarketplaceReference)"
        )
        XCTAssertTrue(commands[1].contains("claude plugin install localvoxtral-remote@localvoxtral"))
        XCTAssertTrue(commands[1].contains("--config 'token=\(token)'"))
        for command in commands {
            XCTAssertFalse(command.contains("settings.json"), "never touch the user's Claude config")
        }
    }

    func testTheInstallCommandInstallsTheRemotePluginNotTheLocalOne() throws {
        // The two plugins are structurally different — a curl shim and a token
        // versus a publisher-binary shim and peer credentials. Installing the
        // local one on a remote host would fail open forever and look like a
        // tunnel bug.
        let commands = try plan().remoteCommands
        XCTAssertTrue(commands[1].contains(ClaudePluginAssets.remotePluginName))
        XCTAssertFalse(
            commands[1].contains(" \(ClaudePluginAssets.pluginName)@"),
            "must not install the local plugin on a remote host"
        )
    }

    func testTheInstallCommandIsSpacePrefixedToDodgeShellHistory() throws {
        let commands = try plan().remoteCommands
        XCTAssertTrue(commands[1].hasPrefix(" "), "HISTCONTROL=ignorespace / HIST_IGNORE_SPACE")
        XCTAssertFalse(commands[0].hasPrefix(" "), "only the one carrying the credential")
    }

    func testTheMarketplaceReferenceIsTheCurrentRepoOwner() {
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService.repositoryMarketplaceReference,
            "T0mSIlver/localvoxtral"
        )
        XCTAssertFalse(
            ClaudeRemoteEnrollmentService.repositoryMarketplaceReference.contains("tomvaucourt"),
            "the old owner would resolve to nothing"
        )
    }

    // MARK: What left the plan, and where it went

    /// Ported from `testUninstallCoversBothTheRemotePluginAndLocalRevocation`.
    /// Uninstall is no longer a comment-annotated command list in a sheet; it is
    /// a documented procedure. Everything it asserted must still exist.
    func testUninstallIsDocumentedIncludingTheRevocationThatActuallyStopsAHost() throws {
        let documentation = try documentation()
        XCTAssertTrue(documentation.contains("claude plugin uninstall localvoxtral-remote@localvoxtral"))
        XCTAssertTrue(documentation.contains("claude plugin marketplace remove localvoxtral"))
        XCTAssertTrue(documentation.contains("~/.ssh/config"), "the ssh block is ours to name, not to delete")
        XCTAssertTrue(
            documentation.lowercased().contains("revocation is what actually stops the host"),
            "revocation is the real off switch and must be in the uninstall path"
        )
    }

    /// Ported from `testVerifyCommandsProbeTheTunnelAndThePlugin`.
    ///
    /// The commands left the plan — the app runs them now — but a user who
    /// wants to run them by hand still needs them, and still needs to be told
    /// that 401 is the pass and that a non-interactive SSH shell loses `claude`
    /// off PATH.
    func testTheManualChecksAndTheirMeaningLiveInTheDocs() throws {
        let documentation = try documentation()
        XCTAssertTrue(documentation.contains("claude plugin list"))
        XCTAssertTrue(documentation.contains("/v1/hook/SessionStart"))
        XCTAssertTrue(
            documentation.contains("**`401` is the success answer**"),
            "401 is the pass signal and must be labeled as such"
        )
        XCTAssertTrue(
            documentation.contains("PATH=\"$HOME/.claude/local:$HOME/.local/bin"),
            "plugin list must not depend on the remote shell's rc-file PATH"
        )
        XCTAssertFalse(documentation.contains(token), "a doc page must not carry a credential")
    }

    /// The owner rule this change exists for: nothing the user copies carries
    /// commentary. The two BEGIN/END lines are the only exception, and they are
    /// functional — `applySSHConfigSnippet` and `sshConfigForwardsPort` both
    /// find the block by them.
    func testNothingInThePlanCarriesACommentExceptTheTwoDelimiters() throws {
        let plan = try allocatedPlan()
        let commentLines = ([plan.sshConfigSnippet] + plan.remoteCommands + plan.updateCommands)
            .flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#") }
        XCTAssertEqual(
            commentLines,
            [
                ClaudeRemoteEnrollmentService.blockBegin(hostID: host.id),
                ClaudeRemoteEnrollmentService.blockEnd(hostID: host.id),
            ],
            "only the delimiters may be comments — they are functional, the essays were not"
        )
    }

    // MARK: Update

    /// Verified on Claude Code 2.1.220: re-running the enrollment pair on an
    /// enrolled host exits 0 and changes nothing — `marketplace add` says
    /// "already on disk" without refreshing the clone, and `plugin install`
    /// says "already installed" without touching the version. `marketplace
    /// update` + `plugin update` is the only pair that delivers a plugin fix,
    /// and the order matters: `plugin update` installs whatever the local
    /// marketplace clone currently offers.
    func testUpdateCommandsRefreshTheMarketplaceThenThePlugin() throws {
        let commands = try plan().updateCommands
        let runnable = commands.filter { !$0.hasPrefix("#") }
        // Three since per-Mac ports (#215): the third writes only the port, for
        // a host enrolled before the option existed. `plugin update` has no
        // `--config` on 2.1.220, so it cannot be folded into the second.
        XCTAssertEqual(runnable.count, 3)
        XCTAssertTrue(
            runnable[2].contains(
                "claude plugin install \(ClaudeRemoteEnrollmentService.remotePluginReference) "
                    + "--config '\(ClaudeRemoteEnrollmentService.portConfigKey)=8473'"
            ),
            "the migration line must set the port and nothing else: \(runnable[2])"
        )
        XCTAssertTrue(runnable[0].hasPrefix("ssh builder '"))
        XCTAssertTrue(runnable[1].hasPrefix("ssh builder '"))
        XCTAssertTrue(
            runnable[0].contains(
                "claude plugin marketplace update \(ClaudePluginAssets.marketplaceName)"
            )
        )
        XCTAssertTrue(runnable[1].contains("claude plugin update localvoxtral-remote@localvoxtral"))
        XCTAssertTrue(
            runnable[1].contains(ClaudeRemoteEnrollmentService.remotePluginReference),
            "the reference must come from the shared constants, not a second literal"
        )
        XCTAssertFalse(
            runnable[1].contains(" \(ClaudePluginAssets.pluginName)@"),
            "the local plugin is not what a remote host runs"
        )
    }

    func testUpdateCommandsNeverCarryTheToken() throws {
        // `plugin update` preserves the stored config, so this path has no
        // reason to hold the credential — and a command with no token in it
        // cannot leak one into a log, a screenshot, or shell history.
        let commands = try plan().updateCommands
        for command in commands {
            XCTAssertFalse(command.contains(token))
            XCTAssertFalse(command.contains(ClaudeRemoteEnrollmentService.tokenConfigKey + "="))
            // Not a blanket ban on `--config` any more: the port migration is a
            // config write, and it is the whole point of this path since #215.
            // Every `--config` on it must be the port one — that is a stricter
            // statement than "no --config", not a looser one.
            assertEveryConfigArgumentIsThePort(in: command)
        }
    }

    func testUpdateCommandsSurviveANonInteractiveSSHPath() throws {
        // Same failure the verify probe hit: `ssh host 'claude …'` skips the
        // login rc, so claude is routinely off PATH there.
        let runnable = try plan().updateCommands.filter { !$0.hasPrefix("#") }
        for command in runnable {
            XCTAssertTrue(
                command.contains("PATH=\"$HOME/.claude/local:$HOME/.local/bin"),
                "an update must not depend on the remote shell's rc-file PATH"
            )
            XCTAssertTrue(
                command.contains(ClaudeRemoteEnrollmentService.nonInteractiveClaudePathPrefix),
                "the prefix is shared with the verify commands, not re-spelled"
            )
        }
    }

    /// Ported from `testUpdateCommandsSayWhyReinstallingIsNotAnUpdate`.
    ///
    /// The commands are comment-free now (owner rule), so the explanation a
    /// person needs before pasting them — that re-running the install is NOT an
    /// update, and that updating does not cost them their token — has to be
    /// somewhere they will meet it: the panel's own line, and the docs page.
    func testWhyReinstallingIsNotAnUpdateIsStatedOutsideTheCommands() throws {
        let joined = try plan().updateCommands.joined(separator: "\n")
        XCTAssertFalse(joined.contains("#"), "the commands are the commands")

        let documentation = try documentation()
        XCTAssertTrue(documentation.contains("plugin install"))
        XCTAssertTrue(documentation.lowercased().contains("already installed"))
        XCTAssertTrue(documentation.contains("2.1.220"), "the behavior is version-specific and dated as such")
        XCTAssertTrue(
            documentation.lowercased().contains("token is preserved"),
            "the first question is whether updating costs the user their token"
        )
    }

    // MARK: The documentation the sheet links to

    /// Ported from `testNotesCoverTheCaveatsThatBiteFirst` and
    /// `testNotesStateThatARemoteTokenCannotReachLocalFiles`. Eight paragraphs
    /// of bullets in a sheet are exactly the "tiring to read" the owner called
    /// out; they did not disappear, they moved somewhere with headings. Every
    /// clause below was asserted on `notes` before.
    func testTheDocsPageCoversTheCaveatsThatBiteFirst() throws {
        let documentation = try documentation().lowercased()
        XCTAssertTrue(documentation.contains("tmux"), "a multiplexer owns the title, so the marker does not arrive")
        XCTAssertTrue(documentation.contains("set-titles"), "and the fix for it")
        XCTAssertTrue(documentation.contains("revok"), "the off switch")
        XCTAssertTrue(documentation.contains("rotat"), "what to do when the token leaks into history")
        XCTAssertTrue(documentation.contains("histcontrol") || documentation.contains("hist_ignore_space"))
        XCTAssertTrue(documentation.contains("exitonforwardfailure"))
        XCTAssertTrue(
            documentation.contains("plain `ssh`") || documentation.contains("plain ssh"),
            "unenrolled SSH must be documented as unchanged: no tunnel, screen-only, unjoined"
        )
        XCTAssertTrue(
            documentation.contains("curl") && documentation.contains("fail open"),
            "the host dependency (sh + curl) and its fail-open behavior must be stated honestly"
        )
        XCTAssertTrue(
            documentation.contains("connect_to") && documentation.contains("backs off"),
            "the app-down ssh noise and the shim's backoff must be stated — the symptom reads "
                + "as a plugin bug and the user must learn whose stderr it is"
        )
        XCTAssertTrue(
            documentation.contains("never") && documentation.contains("read a file"),
            "the security property is the thing a user most needs stated plainly"
        )
    }

    // MARK: SSH config writing

    func testSSHConfigInsertionCreatesFreshDirectoryAndFileWithPrivatePermissions() throws {
        let fileSystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteSSHConfigState(
                directoryExists: false,
                configData: nil,
                configPermissions: nil
            )
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)

        try service.insertSSHConfig(try plan(), hostID: host.id)

        let snapshot = fileSystem.snapshot
        XCTAssertEqual(snapshot.createdDirectoryPermissions, [0o700])
        XCTAssertEqual(snapshot.writes.count, 1)
        XCTAssertEqual(snapshot.writes.first?.permissions, 0o600)
        XCTAssertTrue(String(decoding: snapshot.writes[0].data, as: UTF8.self).contains("Host builder"))
    }

    func testSSHConfigInsertionAppendsToExistingOtherContentAndPreservesPermissions() throws {
        let existing = "Host github.com\n    User git\n"
        let fileSystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteSSHConfigState(
                directoryExists: true,
                configData: Data(existing.utf8),
                configPermissions: 0o640
            )
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)

        try service.insertSSHConfig(try plan(), hostID: host.id)

        let snapshot = fileSystem.snapshot
        let written = String(decoding: snapshot.writes[0].data, as: UTF8.self)
        XCTAssertTrue(written.hasPrefix(existing))
        XCTAssertTrue(written.contains("Host builder"))
        XCTAssertEqual(snapshot.writes[0].permissions, 0o640)
        XCTAssertTrue(snapshot.createdDirectoryPermissions.isEmpty)
    }

    func testSSHConfigInsertionReplacesExistingHostBlockWithoutDuplication() throws {
        let old = try plan(alias: "old-builder").sshConfigSnippet
        let existing = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "Host other\n    User x\n",
            snippet: old,
            hostID: host.id
        )
        let fileSystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteSSHConfigState(
                directoryExists: true,
                configData: Data(existing.utf8),
                configPermissions: 0o600
            )
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)

        try service.insertSSHConfig(try plan(alias: "new-builder"), hostID: host.id)

        let written = String(decoding: fileSystem.snapshot.writes[0].data, as: UTF8.self)
        XCTAssertTrue(written.contains("Host new-builder"))
        XCTAssertFalse(written.contains("Host old-builder"))
        XCTAssertEqual(written.components(separatedBy: ClaudeRemoteEnrollmentService.blockBegin(hostID: host.id)).count - 1, 1)
        XCTAssertTrue(written.contains("Host other"))
    }

    func testSSHConfigInsertionRefusesASymlinkedConfigWithoutWriting() throws {
        // A rename-based atomic write would replace the symlink with a regular
        // file and silently desync a dotfiles-managed setup.
        let fileSystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteSSHConfigState(
                directoryExists: true,
                configData: nil,
                configPermissions: nil,
                configIsSymlink: true
            )
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)

        XCTAssertThrowsError(try service.insertSSHConfig(try plan(alias: "builder"), hostID: host.id)) {
            XCTAssertEqual(
                $0 as? ClaudeRemoteEnrollmentService.ServiceError, .sshConfigIsSymlink
            )
        }
        XCTAssertTrue(fileSystem.snapshot.writes.isEmpty)
        XCTAssertTrue(fileSystem.snapshot.createdDirectoryPermissions.isEmpty)
    }

    func testSSHConfigInsertionRefusesASymlinkedSSHDirectoryWithoutWriting() throws {
        let fileSystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteSSHConfigState(
                directoryExists: true,
                configData: nil,
                configPermissions: nil,
                directoryIsSymlink: true
            )
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)

        XCTAssertThrowsError(try service.insertSSHConfig(try plan(alias: "builder"), hostID: host.id)) {
            XCTAssertEqual(
                $0 as? ClaudeRemoteEnrollmentService.ServiceError, .sshConfigIsSymlink
            )
        }
        XCTAssertTrue(fileSystem.snapshot.writes.isEmpty)
    }

    func testSSHConfigInsertionRefusesAnUntrustedSSHDirectoryWithoutWriting() throws {
        for state in [
            // group/world-writable
            ClaudeRemoteSSHConfigState(
                directoryExists: true,
                configData: nil,
                configPermissions: nil,
                directoryPermissions: 0o770
            ),
            // not the user's directory
            ClaudeRemoteSSHConfigState(
                directoryExists: true,
                configData: nil,
                configPermissions: nil,
                directoryOwnedByCurrentUser: false
            ),
        ] {
            let fileSystem = MemorySSHConfigFileSystem(state: state)
            let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)

            XCTAssertThrowsError(
                try service.insertSSHConfig(try plan(alias: "builder"), hostID: host.id)
            ) {
                XCTAssertEqual(
                    $0 as? ClaudeRemoteEnrollmentService.ServiceError, .sshDirectoryNotTrusted
                )
            }
            XCTAssertTrue(fileSystem.snapshot.writes.isEmpty)
        }
    }

    func testSSHConfigInsertionAcceptsAConventionallyPermissionedDirectory() throws {
        // 0700 and the common 0755 both lack group/world WRITE, which is the
        // actual attack surface; refusing them would break ordinary setups.
        for mode in [UInt16(0o700), UInt16(0o755)] {
            let fileSystem = MemorySSHConfigFileSystem(
                state: ClaudeRemoteSSHConfigState(
                    directoryExists: true,
                    configData: nil,
                    configPermissions: nil,
                    directoryPermissions: mode
                )
            )
            let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)
            try service.insertSSHConfig(try plan(alias: "builder"), hostID: host.id)
            XCTAssertEqual(fileSystem.snapshot.writes.count, 1)
        }
    }

    // MARK: Execution

    func testExecutionIsRefusedWithoutAnInjectedRunner() throws {
        let service = ClaudeRemoteEnrollmentService()
        XCTAssertThrowsError(
            try service.executeRemoteSetup(try plan(), sshHostAlias: "builder", token: token)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .executionNotConfigured
            )
        }
    }

    func testExecutionRunsExactlyTheRemoteCommandsOverSSH() throws {
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "")
        })
        try service.executeRemoteSetup(try plan(), sshHostAlias: "builder", token: token)

        let recorded = calls.withLock { $0 }
        XCTAssertEqual(recorded.count, 2)
        for invocation in recorded {
            // ClearAllForwardings: setup must not compete for the 8473 tunnel
            // a real session already holds (field report 2026-07-26).
            XCTAssertEqual(
                invocation.argv,
                [
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                    "builder", "/bin/sh", "-s",
                ]
            )
            XCTAssertFalse(invocation.argv.joined(separator: " ").contains(token))
        }
        XCTAssertEqual(
            recorded.map { String(decoding: $0.standardInput, as: UTF8.self) },
            try plan().remoteCommands.map {
                "set -eu\n\(ClaudeRemoteEnrollmentService.claudePathResolverPreamble)\($0)\n"
            }
        )
    }

    /// Field failure 2026-07-26: `ssh <host> /bin/sh -s` runs under sshd's
    /// minimal PATH, so a host where `claude` works interactively still died
    /// with dash's bare "claude: not found". The script must resolve claude
    /// from the known install locations before running, and fail with an
    /// actionable message when it truly is absent.
    func testRemoteScriptResolvesClaudeFromUserLocalInstallLocations() {
        let script = String(
            decoding: ClaudeRemoteEnrollmentService.remoteScript(
                command: "claude plugin list"
            ),
            as: UTF8.self
        )
        XCTAssertTrue(script.hasPrefix("set -eu\n"))
        XCTAssertTrue(script.contains("command -v claude"))
        for location in [".claude/local", ".local/bin", "/opt/homebrew/bin", ".nvm/versions/node"] {
            XCTAssertTrue(script.contains(location), "missing probe location \(location)")
        }
        XCTAssertTrue(script.contains("exit 127"), "a missing claude must fail loudly, not run on")
        XCTAssertTrue(
            script.contains("Run 'command -v claude' in a normal shell"),
            "the failure message must tell the user what to actually do"
        )
        XCTAssertTrue(script.hasSuffix("claude plugin list\n"))
    }

    func testRemoteScriptLeavesNonClaudeCommandsUnguarded() {
        let script = String(
            decoding: ClaudeRemoteEnrollmentService.remoteScript(command: "uname -a"),
            as: UTF8.self
        )
        // A future non-claude step must not be failed by a missing CLI it
        // never needed.
        XCTAssertEqual(script, "set -eu\nuname -a\n")
    }

    /// LOCAL argv freedom, and nothing more.
    ///
    /// What this proves is that no process THIS Mac spawns carries the token in
    /// its arguments — it rides the ssh child's stdin, so `ps` here never sees
    /// it. It says nothing about the remote host, and the old name implied
    /// otherwise (review finding, round 2): `claude plugin install` takes its
    /// config as a flag and has no stdin path, so on the host the token IS in
    /// that command's argv while it runs, and in `~/.claude` afterwards. That
    /// is unavoidable and is documented rather than papered over.
    func testRemoteSetupKeepsTokenOutOfEveryArgvOnTHISMac() throws {
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "")
        })

        try service.executeRemoteSetup(try plan(), sshHostAlias: "builder", token: token)

        let recorded = calls.withLock { $0 }
        XCTAssertTrue(recorded.allSatisfy { !$0.argv.joined(separator: " ").contains(token) })
        XCTAssertTrue(
            recorded.contains { String(decoding: $0.standardInput, as: UTF8.self).contains(token) }
        )
        // …and the remote-side exposure is stated where a user will meet it,
        // rather than being implied away.
        let documentation = try documentation()
        XCTAssertTrue(documentation.contains("local and only local"))
        XCTAssertTrue(documentation.contains("/proc/<pid>/cmdline"))
        XCTAssertTrue(documentation.lowercased().contains("rotate"))
    }

    /// MINOR 5 (review round 2): the snippet's token-freedom assertion was lost
    /// in the port and is restored here, extended to the update commands.
    ///
    /// Both are text that outlives the sheet: `~/.ssh/config` gets copied
    /// between machines and pasted into issues, and the update commands are
    /// shown long after the one-time token is gone. Neither may ever carry it.
    func testNeitherTheSnippetNorTheUpdateCommandsEverCarryTheToken() throws {
        let plan = try allocatedPlan()
        XCTAssertFalse(plan.sshConfigSnippet.contains(token))
        for command in plan.updateCommands {
            XCTAssertFalse(command.contains(token), command)
            XCTAssertFalse(command.contains("\(ClaudeRemoteEnrollmentService.tokenConfigKey)="))
        }
        // The install command is the ONE place it belongs, so a test that
        // passed because the token was mistyped would be worthless.
        XCTAssertTrue(plan.remoteCommands.joined().contains(token))
    }

    func testExecutionStopsAtTheFirstFailure() throws {
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 1, message: "marketplace not found")
        })
        XCTAssertThrowsError(
            try service.executeRemoteSetup(try plan(), sshHostAlias: "builder", token: token)
        ) { error in
            guard case .commandFailed(let step, _, let exitCode, let message)? =
                error as? ClaudeRemoteEnrollmentService.ServiceError
            else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertEqual(step, 0)
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(message, "marketplace not found")
        }
        XCTAssertEqual(calls.withLock { $0 }.count, 1, "an install after a failed marketplace add is noise")
    }

    func testSuccessfulCapturedOutputIsRedactedBeforeLeavingTheService() throws {
        let token = token
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 0, message: "remote echoed \(token)")
        })

        let steps = try service.executeRemoteSetup(
            try plan(),
            sshHostAlias: "builder",
            token: token
        )

        XCTAssertEqual(steps.count, 2)
        for step in steps {
            XCTAssertFalse(step.message.contains(token))
            XCTAssertTrue(step.message.contains(ClaudeRemoteTokenRedaction.placeholder))
        }
    }

    func testAFailureNeverCarriesTheTokenIntoTheError() throws {
        let token = token
        let calls = Mutex(0)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            let call = calls.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            if call == 0 { return .init(exitCode: 0, message: "marketplace ready") }
            return .init(
                exitCode: 1,
                message: "failed running: claude plugin install --config 'token=\(token)'"
            )
        })
        XCTAssertThrowsError(
            try service.executeRemoteSetup(
                ClaudeRemoteEnrollmentService.SetupPlan(
                    sshConfigSnippet: "",
                    remoteCommands: ClaudeRemoteEnrollmentService.remoteCommands(token: token, remoteForwardPort: 28511),
                    updateCommands: []
                ),
                sshHostAlias: "builder",
                token: token
            )
        ) { error in
            guard case .commandFailed(_, let command, _, let message)? =
                error as? ClaudeRemoteEnrollmentService.ServiceError
            else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertFalse(
                command.contains(token),
                "the displayed command in the error must not carry the plaintext token"
            )
            XCTAssertFalse(
                message.contains(token),
                "remote output that echoes the token must be redacted before it is thrown"
            )
            // Redacted, not merely truncated: the surrounding text has to
            // survive or the error stops being diagnosable.
            XCTAssertTrue(message.contains(ClaudeRemoteTokenRedaction.placeholder))
            XCTAssertTrue(message.contains("failed running"))
        }
    }

    func testAFailureDescriptionNeverCarriesTheToken() throws {
        // The catch-all: whatever else an error grows, interpolating it must
        // never print the secret.
        let token = token
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 1, message: "boom: token=\(token)")
        })
        do {
            try service.executeRemoteSetup(
                ClaudeRemoteEnrollmentService.SetupPlan(
                    sshConfigSnippet: "",
                    remoteCommands: ClaudeRemoteEnrollmentService.remoteCommands(token: token, remoteForwardPort: 28511),
                    updateCommands: []
                ),
                sshHostAlias: "builder",
                token: token
            )
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(String(describing: error).contains(token))
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
    }

    func testRemoteTimeoutMapsToClearRedactedServiceError() throws {
        let token = token
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            throw ClaudeRemoteEnrollmentService.RunnerFailure.timedOut(
                seconds: 12,
                message: "last output contained \(token)"
            )
        })

        XCTAssertThrowsError(
            try service.executeRemoteSetup(try plan(), sshHostAlias: "builder", token: token)
        ) { error in
            guard case .commandTimedOut(let step, _, let seconds, let message)? =
                error as? ClaudeRemoteEnrollmentService.ServiceError
            else {
                return XCTFail("expected commandTimedOut, got \(error)")
            }
            XCTAssertEqual(step, 0)
            XCTAssertEqual(seconds, 12)
            XCTAssertFalse(message.contains(token))
            XCTAssertTrue(message.contains(ClaudeRemoteTokenRedaction.placeholder))
        }
    }

    func testExecutionRefusesAnInvalidAlias() {
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            XCTFail("the runner must never be reached with an invalid alias")
            return .init(exitCode: 0, message: "")
        })
        XCTAssertThrowsError(
            try service.executeRemoteSetup(
                ClaudeRemoteEnrollmentService.SetupPlan(
                    sshConfigSnippet: "", remoteCommands: ["echo hi"], updateCommands: []
                ),
                sshHostAlias: "a b",
                token: token
            )
        )
    }

    // MARK: Update execution

    func testPluginUpdateExecutionIsRefusedWithoutAnInjectedRunner() throws {
        let service = ClaudeRemoteEnrollmentService()
        XCTAssertThrowsError(try service.executeRemotePluginUpdate(sshHostAlias: "builder")) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .executionNotConfigured
            )
        }
    }

    func testPluginUpdateRunsExactlyTheTwoClaudeCommandsOverSSH() throws {
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "")
        })

        let steps = try service.executeRemotePluginUpdate(
            sshHostAlias: "builder", remoteForwardPort: 28500
        )

        let recorded = calls.withLock { $0 }
        XCTAssertEqual(steps.count, 3)
        for invocation in recorded {
            XCTAssertEqual(
                invocation.argv,
                [
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                    "builder", "/bin/sh", "-s",
                ]
            )
        }
        XCTAssertEqual(
            recorded.map { String(decoding: $0.standardInput, as: UTF8.self) },
            ClaudeRemoteEnrollmentService.remotePluginUpdateCommands(remoteForwardPort: 28500).map {
                "set -eu\n\(ClaudeRemoteEnrollmentService.claudePathResolverPreamble)\($0)\n"
            }
        )
        // Nothing on this path has the credential, so nothing on it can spill
        // one: no argv, no script, no captured step. The port migration DOES
        // carry a `--config`, which is why this asserts the token specifically
        // rather than banning the flag: `install --config port=` merges by key
        // and leaves the stored token untouched (verified on Claude Code
        // 2.1.220), so it is a config write with nothing secret in it.
        for invocation in recorded {
            XCTAssertFalse(invocation.argv.joined(separator: " ").contains("token"))
            let script = String(decoding: invocation.standardInput, as: UTF8.self)
            XCTAssertFalse(script.contains("\(ClaudeRemoteEnrollmentService.tokenConfigKey)="))
            assertEveryConfigArgumentIsThePort(in: script)
        }
    }

    func testPluginUpdateStopsAtTheFirstFailure() throws {
        // A `plugin update` against a marketplace clone that failed to refresh
        // would "succeed" onto the version the host already has.
        let calls = Mutex(0)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            calls.withLock { $0 += 1 }
            return .init(exitCode: 1, message: "marketplace not found")
        })
        XCTAssertThrowsError(try service.executeRemotePluginUpdate(sshHostAlias: "builder")) { error in
            guard case .commandFailed(let step, let command, let exitCode, let message)? =
                error as? ClaudeRemoteEnrollmentService.ServiceError
            else {
                return XCTFail("expected commandFailed, got \(error)")
            }
            XCTAssertEqual(step, 0)
            XCTAssertEqual(exitCode, 1)
            XCTAssertEqual(message, "marketplace not found")
            XCTAssertTrue(command.contains("marketplace update"))
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testPluginUpdateRefusesAnInvalidAlias() {
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            XCTFail("the runner must never be reached with an invalid alias")
            return .init(exitCode: 0, message: "")
        })
        XCTAssertThrowsError(try service.executeRemotePluginUpdate(sshHostAlias: "a b")) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .invalidHostAlias
            )
        }
    }

    func testExecutionNeverTouchesTheSSHConfig() throws {
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "")
        })
        try service.executeRemoteSetup(try plan(), sshHostAlias: "builder", token: token)
        for invocation in calls.withLock({ $0 }) {
            XCTAssertFalse(invocation.argv.joined(separator: " ").contains(".ssh/config"))
        }
    }

    // MARK: Verification

    private struct VerificationRun {
        var checks: [ClaudeRemoteEnrollmentService.VerificationCheck]
        var invocations: [ClaudeRemoteEnrollmentService.Invocation]
    }

    /// Drives `executeVerification` against scripted results, in call order:
    /// the tunnel probe first, the plugin probe second. `Mutex` is noncopyable,
    /// so the recorded invocations come back as a value rather than through an
    /// inout parameter.
    private func verify(
        alias: String = "builder",
        remoteForwardPort: UInt16 = 8473,
        listenerIsBound: Bool = true,
        results: [ClaudeRemoteEnrollmentService.RunResult]
    ) throws -> VerificationRun {
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let index = Mutex(0)
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return index.withLock { value -> ClaudeRemoteEnrollmentService.RunResult in
                defer { value += 1 }
                return results[min(value, results.count - 1)]
            }
        })
        return VerificationRun(
            checks: try service.executeVerification(
                sshHostAlias: alias,
                remoteForwardPort: remoteForwardPort,
                listenerIsBound: listenerIsBound
            ),
            invocations: calls.withLock { $0 }
        )
    }

    func testVerificationIsRefusedWithoutAnInjectedRunner() {
        // Same opt-in as execution: a service with no runner spawns nothing,
        // ever, and says so instead of quietly reaching for a default.
        let service = ClaudeRemoteEnrollmentService()
        XCTAssertThrowsError(
            try service.executeVerification(sshHostAlias: "builder", listenerIsBound: true)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .executionNotConfigured
            )
        }
    }

    func testVerificationRefusesAnInvalidAlias() {
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            XCTFail("the runner must never be reached with an invalid alias")
            return .init(exitCode: 0, message: "")
        })
        XCTAssertThrowsError(
            try service.executeVerification(sshHostAlias: "a b", listenerIsBound: true)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .invalidHostAlias
            )
        }
    }

    /// The tunnel probe must NOT clear forwardings, unlike every other
    /// connection this type opens. Its whole point is that the alias's own Host
    /// block asks for the RemoteForward; clearing it would test a tunnel the
    /// probe just disabled.
    func testTheTunnelProbeDoesNotClearForwardingsAndSendsNoCredential() throws {
        let recorded = try verify(
            results: [.init(exitCode: 0, message: "LVX_HTTP:401"), .init(exitCode: 0, message: "")]
        ).invocations
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(
            recorded[0].argv,
            ["ssh", "-o", "BatchMode=yes", "--", "builder", "/bin/sh", "-s"]
        )
        XCTAssertFalse(
            recorded[0].argv.contains("ClearAllForwardings=yes"),
            "the probe exists to observe the forward, not to suppress it"
        )
        // BatchMode everywhere: a check must never sit on a password prompt.
        // `--` everywhere: an alias can never be read as an option.
        for invocation in recorded {
            XCTAssertTrue(invocation.argv.contains("BatchMode=yes"))
            XCTAssertTrue(invocation.argv.contains("--"))
            XCTAssertTrue(invocation.timeout > 0, "every probe is bounded")
        }
        // Verification needs no credential at all — the 401 IS the point.
        let everything = recorded
            .map { $0.argv.joined(separator: " ") + String(decoding: $0.standardInput, as: UTF8.self) }
            .joined()
        XCTAssertFalse(everything.contains(token))
        XCTAssertFalse(everything.lowercased().contains("authorization"))
        XCTAssertFalse(everything.contains("--config"))
    }

    func testTheTunnelProbeIsReadOnly() throws {
        let recorded = try verify(
            remoteForwardPort: 28511,
            results: [.init(exitCode: 0, message: "LVX_HTTP:401"), .init(exitCode: 0, message: "")]
        ).invocations
        let script = String(decoding: recorded[0].standardInput, as: UTF8.self)
        XCTAssertTrue(script.contains("http://127.0.0.1:28511/v1/hook/SessionStart"))
        XCTAssertTrue(script.contains("%{http_code}"))
        XCTAssertFalse(script.contains("plugin install"))
        XCTAssertFalse(script.contains("rm "))
    }

    func testEachProbeGetsItsOwnTimeoutSoOneSlowHostCannotStarveTheOther() throws {
        // Review finding, round 1: with a single shared deadline, a tunnel probe
        // that burned the whole budget left the plugin probe with zero and the
        // user learned nothing about the plugin.
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let index = Mutex(0)
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            let call = index.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            if call == 0 {
                // Consumed its entire budget and then some.
                throw ClaudeRemoteEnrollmentService.RunnerFailure.timedOut(
                    seconds: 20, message: "stalled"
                )
            }
            return .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral")
        })

        let checks = try service.executeVerification(
            sshHostAlias: "builder", listenerIsBound: true, timeout: 20
        )

        let recorded = calls.withLock { $0 }
        XCTAssertEqual(recorded.count, 2, "the second probe must still run")
        XCTAssertEqual(recorded[0].timeout, 20)
        XCTAssertEqual(
            recorded[1].timeout, 20,
            "the plugin probe gets its own full budget, not the remains of the tunnel probe's"
        )
        XCTAssertFalse(try XCTUnwrap(checks.first { $0.kind == .tunnel }).passed)
        XCTAssertTrue(
            try XCTUnwrap(checks.first { $0.kind == .plugin }).passed,
            "one broken probe must not hide the other's answer"
        )
    }

    func testA401MeansTheTunnelIsUpWhenOurOwnListenerIsBound() throws {
        let checks = try verify(
            results: [.init(exitCode: 0, message: "LVX_HTTP:401\n"), .init(exitCode: 0, message: "")]
        ).checks
        let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertTrue(tunnel.passed, "401 is the SUCCESS signal, and the app must say so, not the user")
        XCTAssertTrue(tunnel.summary.contains("Tunnel is up"))
    }

    /// Review finding, round 1: a 401 proves something on this Mac answered
    /// through the tunnel, not that it was us. When our own bind failed, the
    /// squatter holding the listener port is what replied — and the old verdict
    /// called that a pass.
    func testA401DoesNotPassWhenOurListenerIsNotBound() throws {
        let checks = try verify(
            remoteForwardPort: 28511,
            listenerIsBound: false,
            results: [.init(exitCode: 0, message: "LVX_HTTP:401"), .init(exitCode: 0, message: "")]
        ).checks
        let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        XCTAssertTrue(tunnel.summary.contains("Something else answered"))
        XCTAssertTrue(tunnel.summary.contains("28511"))
        XCTAssertTrue(
            tunnel.hint?.contains("not listening") ?? false,
            "the remedy is the port conflict on THIS Mac, and the user must be sent there"
        )
    }

    func testCurlConnectFailureIsReportedAsNoLiveTunnelNotAsAnSSHFailure() throws {
        // The script always exits 0 and prints one token, so 000 can only mean
        // "nothing answered on the forwarded port".
        let checks = try verify(
            results: [.init(exitCode: 0, message: "LVX_HTTP:000"), .init(exitCode: 0, message: "")]
        ).checks
        let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        XCTAssertEqual(tunnel.summary, "No tunnel is live right now.")
        XCTAssertTrue(
            tunnel.hint?.contains("SSH session") ?? false,
            "the forward exists only while a session is open — say it, once"
        )
    }

    func testNothingAnsweringWithNoLocalListenerBlamesTheMacNotTheTunnel() throws {
        // Both halves are down; telling the user to open an SSH session would
        // send them to fix the wrong machine.
        let checks = try verify(
            listenerIsBound: false,
            results: [.init(exitCode: 0, message: "LVX_HTTP:000"), .init(exitCode: 0, message: "")]
        ).checks
        let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        XCTAssertTrue(tunnel.summary.lowercased().contains("not listening"))
        XCTAssertTrue(tunnel.hint?.contains("this Mac") ?? false)
    }

    /// Review finding, round 1: a host with no `curl` can never deliver context
    /// no matter how healthy the tunnel is — the shim is a curl one-liner — and
    /// the old script reported it as an ordinary connect failure.
    func testAHostWithoutCurlIsItsOwnVerdict() throws {
        let script = String(
            decoding: ClaudeRemoteEnrollmentService.tunnelProbeScript(remoteForwardPort: 8473),
            as: UTF8.self
        )
        XCTAssertTrue(script.contains("command -v curl"), "the sentinel must be decided on the host")

        let checks = try verify(
            results: [
                .init(exitCode: 0, message: ClaudeRemoteEnrollmentService.missingCurlSentinel),
                .init(exitCode: 0, message: ""),
            ]
        ).checks
        let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        XCTAssertTrue(tunnel.summary.contains("curl is missing"))
        XCTAssertFalse(
            tunnel.summary.contains("No tunnel"),
            "a missing curl is not an absent tunnel and has a different fix"
        )
    }

    func testAnSSHFailureIsDistinctFromAnAbsentTunnel() throws {
        let checks = try verify(
            results: [
                .init(exitCode: 255, message: "ssh: Could not resolve hostname builder"),
                .init(exitCode: 255, message: "ssh: Could not resolve hostname builder"),
            ]
        ).checks
        let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        XCTAssertEqual(tunnel.summary, "Could not reach builder over SSH.")
        XCTAssertTrue(tunnel.detail.contains("255"), "the exit code is the diagnosable part we own")
    }

    func testAStrangerAnsweringOnThePortIsItsOwnVerdict() throws {
        // A squatter that returns 200 is not a pass, and not "no tunnel"
        // either: the user has to learn something else holds the port.
        let checks = try verify(
            remoteForwardPort: 28511,
            results: [.init(exitCode: 0, message: "LVX_HTTP:200"), .init(exitCode: 0, message: "")]
        ).checks
        let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        XCTAssertTrue(tunnel.summary.contains("28511"))
    }

    func testThePluginCheckPassesOnlyWhenTheRemotePluginIsListed() throws {
        let present = try verify(
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401"),
                .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral  enabled"),
            ]
        ).checks
        XCTAssertTrue(try XCTUnwrap(present.first { $0.kind == .plugin }).passed)

        let absent = try verify(
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401"),
                .init(exitCode: 0, message: "some-other-plugin@elsewhere  enabled"),
            ]
        ).checks
        let check = try XCTUnwrap(absent.first { $0.kind == .plugin })
        XCTAssertFalse(check.passed)
        XCTAssertTrue(check.summary.contains("not installed"))
        XCTAssertTrue(check.hint?.contains("step 2") ?? false)
    }

    func testAMissingClaudeOnTheHostIsItsOwnVerdictNotAMissingPlugin() throws {
        // Field failure 2026-07-26: `ssh host /bin/sh -s` runs with sshd's
        // minimal PATH. "claude is not installed here" and "the plugin is not
        // installed" are different problems with different fixes.
        let checks = try verify(
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401"),
                .init(exitCode: 127, message: "localvoxtral: 'claude' was not found on this host's non-interactive PATH"),
            ]
        ).checks
        let plugin = try XCTUnwrap(checks.first { $0.kind == .plugin })
        XCTAssertFalse(plugin.passed)
        XCTAssertTrue(plugin.summary.contains("Claude Code was not found"))
        XCTAssertFalse(plugin.summary.contains("plugin is not installed"))
    }

    /// MINOR 4 (review round 3). 127 is the shell's generic "command not
    /// found"; only our own preamble message identifies it as `claude`.
    /// Claiming Claude Code is missing off a bare 127 sends the user to install
    /// something that is already there.
    func testABare127IsNotClaimedToBeAMissingClaudeCode() throws {
        let bare = try verify(
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401"),
                .init(exitCode: 127, message: "sh: 1: something-else: not found"),
            ]
        ).checks
        let plugin = try XCTUnwrap(bare.first { $0.kind == .plugin })
        XCTAssertFalse(plugin.passed)
        XCTAssertFalse(plugin.summary.contains("Claude Code was not found"))
        XCTAssertTrue(plugin.summary.contains("Could not list plugins"))
        XCTAssertTrue(plugin.detail.contains("127"), "the exit code is ours to report")
        XCTAssertFalse(plugin.detail.contains("something-else"), "and the host's bytes are not")

        // With the preamble's own message it IS that verdict.
        let resolved = try verify(
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401"),
                .init(
                    exitCode: 127,
                    message: "localvoxtral: 'claude' was not found on this host's non-interactive PATH"
                ),
            ]
        ).checks
        XCTAssertTrue(
            try XCTUnwrap(resolved.first { $0.kind == .plugin }).summary
                .contains("Claude Code was not found")
        )
    }

    /// NIT 6 (review round 3): the third `RunnerFailure` case had no test.
    func testAnOverlongProbeAnswerIsItsOwnVerdictAndLeaksNothing() throws {
        let leaked = "tokenLLLLMMMMNNNNOOOOPPPP55554444"
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            throw ClaudeRemoteEnrollmentService.RunnerFailure.outputTooLarge(
                capBytes: 64 * 1024, message: "…\(leaked)…"
            )
        })

        let checks = try service.executeVerification(sshHostAlias: "builder", listenerIsBound: true)

        XCTAssertEqual(checks.count, 2)
        for check in checks {
            XCTAssertFalse(check.passed)
            XCTAssertEqual(check.summary, "The host produced too much output to read.")
            XCTAssertEqual(check.detail, "Probe output exceeded 64 KB and was stopped.")
            XCTAssertFalse(check.detail.contains(leaked))
            XCTAssertFalse(check.summary.contains(leaked))
        }
    }

    func testThePluginProbeResolvesClaudeFromUserLocalInstallLocations() throws {
        let recorded = try verify(
            results: [.init(exitCode: 0, message: "LVX_HTTP:401"), .init(exitCode: 0, message: "")]
        ).invocations
        let script = String(decoding: recorded[1].standardInput, as: UTF8.self)
        XCTAssertTrue(script.contains("command -v claude"))
        XCTAssertTrue(script.hasSuffix("claude plugin list\n"))
    }

    /// Review finding, round 1, and the reason no probe output travels at all:
    /// `claude plugin list` prints the plugin's stored userConfig. After a
    /// rotation that is the host's OLD token — a value this process no longer
    /// knows and therefore CANNOT redact. A redactor cannot save a secret it has
    /// never seen, so the output simply does not leave the probe.
    func testNoProbeOutputEverReachesAVerdict() throws {
        let leaked = "tokenZZZZYYYYXXXXWWWWVVVV99998888"
        let run = try verify(
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401\nbanner: \(leaked)"),
                .init(
                    exitCode: 0,
                    message: "localvoxtral-remote@localvoxtral  enabled  config: token=\(leaked)"
                ),
            ]
        )
        for check in run.checks {
            XCTAssertFalse(check.summary.contains(leaked), check.summary)
            XCTAssertFalse(check.hint?.contains(leaked) ?? false)
            XCTAssertFalse(check.detail.contains(leaked), check.detail)
            // Not "redacted" — absent. A placeholder would mean the output made
            // it into the string and was scrubbed, which is exactly the design
            // that cannot work for a token we no longer hold.
            XCTAssertFalse(check.detail.contains(ClaudeRemoteTokenRedaction.placeholder))
        }
        // And the pass still says something useful about what it matched.
        let plugin = try XCTUnwrap(run.checks.first { $0.kind == .plugin })
        XCTAssertTrue(plugin.passed)
        XCTAssertTrue(plugin.detail.contains(ClaudePluginAssets.remotePluginName))
    }

    func testAFailedPluginProbeStillLeaksNothingFromTheHost() throws {
        let leaked = "tokenQQQQRRRRSSSSTTTTUUUU77776666"
        let run = try verify(
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401"),
                .init(exitCode: 3, message: "error: could not read config token=\(leaked)"),
            ]
        )
        let plugin = try XCTUnwrap(run.checks.first { $0.kind == .plugin })
        XCTAssertFalse(plugin.passed)
        XCTAssertFalse(plugin.detail.contains(leaked))
        XCTAssertTrue(plugin.detail.contains("3"), "the exit code is ours to report")
    }

    /// MINOR 2 (review round 2). The probe's answer is a line the probe itself
    /// printed; a login banner, an rc-file echo or a MOTD that happens to end
    /// in `401` must not be able to decide a verdict.
    func testOnlyTheProbesOwnFramedLineDecidesTheVerdict() throws {
        let script = String(
            decoding: ClaudeRemoteEnrollmentService.tunnelProbeScript(remoteForwardPort: 8473),
            as: UTF8.self
        )
        XCTAssertTrue(script.contains(ClaudeRemoteEnrollmentService.httpFramePrefix))

        // Chatty host, framed answer last: the frame wins.
        let noisy = try verify(
            results: [
                .init(
                    exitCode: 0,
                    message: "Welcome to builder\nLast login: 401\nLVX_HTTP:401"
                ),
                .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
            ]
        ).checks
        XCTAssertTrue(try XCTUnwrap(noisy.first { $0.kind == .tunnel }).passed)

        // Chatty host, NO framed answer: an unframed `401` must not pass, and
        // must read as "nothing answered" rather than as a status.
        let unframed = try verify(
            results: [
                .init(exitCode: 0, message: "Welcome to builder\n401"),
                .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
            ]
        ).checks
        let tunnel = try XCTUnwrap(unframed.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed, "an unframed line is not our probe speaking")
        XCTAssertEqual(tunnel.summary, "No tunnel is live right now.")
    }

    func testAFramedAnswerThatIsNotAStatusCodeIsTreatedAsSilence() throws {
        // Truncation, a wrapper's rewrite, anything: three digits or it is not
        // a code, and a non-code must never be reported as one.
        let checks = try verify(
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:not-a-code"),
                .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
            ]
        ).checks
        let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        XCTAssertEqual(tunnel.summary, "No tunnel is live right now.")
        XCTAssertFalse(tunnel.detail.contains("not-a-code"), "unparsed host text must not travel")
    }

    /// MAJOR 1 (review round 2), service half: the local fact is re-applied to
    /// an already-computed verdict, so a listener that died during the probes
    /// cannot leave a stale ✓ standing.
    func testReconcilingWithAnUnboundListenerDowngradesOnlyThePassingTunnelCheck() throws {
        let checks = try verify(
            remoteForwardPort: 28511,
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401"),
                .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
            ]
        ).checks
        XCTAssertEqual(checks.map(\.passed), [true, true])

        let reconciled = ClaudeRemoteEnrollmentService.reconciled(
            checks, remoteForwardPort: 28511, listenerIsBound: false
        )
        let tunnel = try XCTUnwrap(reconciled.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed)
        XCTAssertTrue(tunnel.summary.contains("Something else answered"))
        XCTAssertTrue(tunnel.summary.contains("28511"))
        // The plugin verdict describes the HOST and is untouched: an unbound
        // listener here does not make "installed over there" less true.
        XCTAssertTrue(try XCTUnwrap(reconciled.first { $0.kind == .plugin }).passed)

        // Still bound ⇒ nothing changes at all.
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService.reconciled(
                checks, remoteForwardPort: 28511, listenerIsBound: true
            ),
            checks
        )
    }

    /// MINOR 2 (review round 3). The read window cuts both ways: a listener
    /// that was down at launch and up by the time the probes answered means the
    /// 401 WAS ours, and pinning the squatter call would tell the user to fix
    /// something they already fixed.
    func testAListenerThatRebindsDuringTheProbesTurnsTheSquatterCallBackIntoAPass() throws {
        let checks = try verify(
            listenerIsBound: false,
            results: [
                .init(exitCode: 0, message: "LVX_HTTP:401"),
                .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
            ]
        ).checks
        let launched = try XCTUnwrap(checks.first { $0.kind == .tunnel })
        XCTAssertFalse(launched.passed)
        XCTAssertEqual(launched.decidedBy, .localListener, "this verdict is OURS, not the host's")

        let reconciled = ClaudeRemoteEnrollmentService.reconciled(
            checks, remoteForwardPort: 8473, listenerIsBound: true
        )
        let tunnel = try XCTUnwrap(reconciled.first { $0.kind == .tunnel })
        XCTAssertTrue(tunnel.passed)
        XCTAssertTrue(tunnel.summary.contains("Tunnel is up"))
    }

    /// …but only that one. A rebind cannot turn what the HOST said into
    /// something else.
    func testARebindNeverUpgradesAVerdictTheHostDecided() throws {
        for hostAnswer in [
            ClaudeRemoteEnrollmentService.missingCurlSentinel,
            "LVX_HTTP:000",
            "LVX_HTTP:200",
        ] {
            let checks = try verify(
                listenerIsBound: false,
                results: [
                    .init(exitCode: 0, message: hostAnswer),
                    .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
                ]
            ).checks
            let tunnel = try XCTUnwrap(checks.first { $0.kind == .tunnel })
            XCTAssertEqual(tunnel.decidedBy, .remote, hostAnswer)

            let reconciled = ClaudeRemoteEnrollmentService.reconciled(
                checks, remoteForwardPort: 8473, listenerIsBound: true
            )
            XCTAssertFalse(
                try XCTUnwrap(reconciled.first { $0.kind == .tunnel }).passed,
                "\(hostAnswer) is the host's word, and our listener cannot overrule it"
            )
        }
    }

    func testReconcilingNeverUpgradesAFailedVerdict() throws {
        // A host that said "curl is missing" is not made healthy by this Mac's
        // listener being fine.
        let checks = try verify(
            results: [
                .init(exitCode: 0, message: ClaudeRemoteEnrollmentService.missingCurlSentinel),
                .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
            ]
        ).checks
        let reconciled = ClaudeRemoteEnrollmentService.reconciled(
            checks, remoteForwardPort: 8473, listenerIsBound: true
        )
        XCTAssertEqual(reconciled, checks)
        XCTAssertFalse(try XCTUnwrap(reconciled.first { $0.kind == .tunnel }).passed)
    }

    func testVerificationNeverWritesTheSSHConfig() throws {
        let fileSystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteSSHConfigState(
                directoryExists: true, configData: nil, configPermissions: nil
            )
        )
        let service = ClaudeRemoteEnrollmentService(
            runner: { _ in .init(exitCode: 0, message: "LVX_HTTP:401") },
            sshConfigFileSystem: fileSystem
        )
        _ = try service.executeVerification(sshHostAlias: "builder", listenerIsBound: true)
        XCTAssertTrue(fileSystem.snapshot.writes.isEmpty)
        XCTAssertTrue(fileSystem.snapshot.createdDirectoryPermissions.isEmpty)
    }
}
