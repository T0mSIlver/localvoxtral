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
        // `yes` would refuse the whole SSH session when the remote's 8473 is
        // already bound — usually by the user's own second window. A dictation
        // nicety must never cost someone their shell.
        let snippet = try plan().sshConfigSnippet
        XCTAssertTrue(snippet.contains("ExitOnForwardFailure no"))
        XCTAssertFalse(snippet.contains("ExitOnForwardFailure yes"))
        XCTAssertTrue(
            snippet.lowercased().contains("silent"),
            "the cost of `no` — a silently absent tunnel — must be stated where it is chosen"
        )
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

    func testTheVerifyProbeChecksTheAllocatedPortAndNamesTheFix() throws {
        let joined = try allocatedPlan().verifyCommands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("http://127.0.0.1:28511/v1/hook/SessionStart"))
        XCTAssertTrue(
            joined.contains(ClaudeRemoteForwardPort.forwardFailureSignature),
            "with ExitOnForwardFailure no, this string is the ONLY evidence of a lost bind"
        )
        // A user reading this output must be told what to do, not handed an
        // OpenSSH debug line — and must not be told another machine took the
        // port when the likeliest cause is their own second window.
        XCTAssertTrue(
            joined.contains(
                ClaudeRemoteForwardPort.contentionMessage(port: 28511, host: "builder")
            ),
            joined
        )
        XCTAssertTrue(joined.contains("from THIS Mac, that is expected and healthy"))
        XCTAssertTrue(joined.lowercased().contains("getting no context from it"))
    }

    func testTheForwardProbeDistinguishesConnectionFailureFromBindFailure() throws {
        // Measured, not assumed (2026-08-04, OpenSSH 10.0p2 against a live
        // sshd): a one-line grep for the forwarding warning is wrong at BOTH
        // edges. This Mac's own live session holding the port makes a fresh
        // probe fail to bind — ssh still exits 0 — so a grep calls a healthy
        // setup contended. An unreachable host never requests a forward at
        // all, so the grep finds nothing and a naive check calls it clean,
        // while ssh exits 255. Exit status has to be read first.
        let probe = try allocatedPlan().verifyCommands.first { $0.contains("ssh -v builder") }
        let command = try XCTUnwrap(probe)
        XCTAssertTrue(command.contains("rc=$?"), "the exit status is the first discriminator")
        XCTAssertTrue(
            command.contains("if [ $rc -ne 0 ]"),
            "a connection that never happened must not be reported as a clean port"
        )
        XCTAssertTrue(command.contains("could not reach builder at all"))
        XCTAssertTrue(command.contains(ClaudeRemoteForwardPort.forwardFailureSignature))
        // The bind-failure branch must not accuse another machine when the
        // likeliest cause is the user's own second window.
        XCTAssertTrue(command.contains("from THIS Mac, that is expected and healthy"))
        XCTAssertTrue(command.contains("forwards cleanly to this Mac"))
        // Order: status check, then the warning, then success.
        let statusIndex = try XCTUnwrap(command.range(of: "if [ $rc -ne 0 ]")).lowerBound
        let warningIndex = try XCTUnwrap(
            command.range(of: ClaudeRemoteForwardPort.forwardFailureSignature)
        ).lowerBound
        XCTAssertLessThan(statusIndex, warningIndex)
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

    func testNotesSayHowToGroundSessionsNobodyIsSittingInFrontOf() throws {
        // The failure this answers is silent by construction: a harness-spawned
        // session on the host publishes hooks into a tunnel no interactive ssh
        // is holding, and nothing anywhere says so.
        let notes = try allocatedPlan().notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("Keep the tunnel open"), "name the control, not the concept")
        XCTAssertTrue(notes.lowercased().contains("remote-control"))
        XCTAssertTrue(notes.lowercased().contains("t3 code"))
    }

    func testNotesExplainTheTwoHalvesAndTheRemainingSingleTenancy() throws {
        let notes = try allocatedPlan().notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("28511"))
        XCTAssertTrue(
            notes.contains("`port` option"),
            "the user must know the ssh block and the plugin option are one setting"
        )
        // Honesty about what per-Mac ports do NOT fix: one remote host stores
        // one port, so it still talks to exactly one Mac.
        XCTAssertTrue(notes.lowercased().contains("most recently installed"))
    }

    func testAPlanWithNoAllocationDescribesThePreFixSetup() throws {
        // Existing enrollments keep working untouched: the default is the
        // legacy shared port, so a caller that has not been taught about
        // allocation still generates exactly what it generated before.
        let snippet = try plan().sshConfigSnippet
        XCTAssertTrue(snippet.contains("RemoteForward 8473 127.0.0.1:8473"))
    }

    func testSSHSnippetNeverContainsTheToken() throws {
        // ~/.ssh/config gets copied between machines and pasted into issues. The
        // credential belongs to the plugin's userConfig on the remote, not here.
        let snippet = try plan().sshConfigSnippet
        XCTAssertFalse(snippet.contains(token))
    }

    func testSSHSnippetIsDelimitedByThisHostsID() throws {
        let snippet = try plan().sshConfigSnippet
        XCTAssertTrue(snippet.contains("# BEGIN localvoxtral claude context (habc1234)"))
        XCTAssertTrue(snippet.contains("# END localvoxtral claude context (habc1234)"))
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

    // MARK: Uninstall / verify

    func testUninstallCoversBothTheRemotePluginAndLocalRevocation() throws {
        let commands = try plan().uninstallCommands
        let joined = commands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("claude plugin uninstall localvoxtral-remote@localvoxtral"))
        XCTAssertTrue(joined.contains("claude plugin marketplace remove localvoxtral"))
        XCTAssertTrue(joined.contains("~/.ssh/config"), "the ssh block is ours to name, not to delete")
        XCTAssertTrue(
            joined.contains("revoke \(host.id)"),
            "revocation is the real off switch and must be in the uninstall path"
        )
    }

    func testVerifyCommandsProbeTheTunnelAndThePlugin() throws {
        let commands = try plan().verifyCommands
        let joined = commands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("ssh -v builder"), "a failed RemoteForward is only visible with -v")
        XCTAssertTrue(joined.contains("claude plugin list"))
        XCTAssertTrue(joined.contains("http://127.0.0.1:8473/v1/hook/SessionStart"))
        for command in commands {
            XCTAssertFalse(command.contains(token), "a preflight must not print the credential")
        }
        // Field report 2026-07-26: the owner read healthy verify output as
        // broken. The commands themselves must say what their output means and
        // survive a login shell that skips rc files. Since 2026-08-04 the
        // interpretation is emitted by the probe itself, per branch, rather
        // than sitting in a comment above it.
        XCTAssertTrue(
            joined.contains("that is expected and healthy"),
            "the forward-failure branch needs its interpretation in its own output"
        )
        XCTAssertTrue(
            joined.contains("401 = SUCCESS"),
            "401 is the pass signal and must be labeled as such"
        )
        XCTAssertTrue(
            joined.contains("PATH=\"$HOME/.claude/local:$HOME/.local/bin"),
            "plugin list must not depend on the remote shell's rc-file PATH"
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

    func testUpdateCommandsSayWhyReinstallingIsNotAnUpdate() throws {
        // These are pasted by a person who has already run the install command
        // once and seen it exit 0. Without this, "I re-ran setup" reads as "I
        // updated", and the host silently stays on the old plugin.
        let joined = try plan().updateCommands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("plugin install"))
        XCTAssertTrue(joined.contains("already"))
        XCTAssertTrue(joined.contains("2.1.220"), "the behavior is version-specific and dated as such")
        XCTAssertTrue(
            joined.lowercased().contains("token is kept"),
            "the first question is whether updating costs the user their token"
        )
    }

    // MARK: Notes

    func testNotesCoverTheCaveatsThatBiteFirst() throws {
        let notes = try plan().notes.joined(separator: "\n").lowercased()
        XCTAssertTrue(notes.contains("tmux"), "a multiplexer owns the title, so the marker does not arrive")
        XCTAssertTrue(notes.contains("set-titles"), "and the fix for it")
        XCTAssertTrue(notes.contains("revok"), "the off switch")
        XCTAssertTrue(notes.contains("rotate"), "what to do when the token leaks into history")
        XCTAssertTrue(notes.contains("histcontrol") || notes.contains("hist_ignore_space"))
        XCTAssertTrue(notes.contains("exitonforwardfailure"))
        XCTAssertTrue(
            notes.contains("plain `ssh`") || notes.contains("plain ssh"),
            "unenrolled SSH must be documented as unchanged: no tunnel, screen-only, unjoined"
        )
        XCTAssertTrue(
            notes.contains("curl") && notes.contains("fail open"),
            "the host dependency (sh + curl) and its fail-open behavior must be stated honestly"
        )
        XCTAssertTrue(
            notes.contains("connect_to") && notes.contains("back off"),
            "the app-down ssh noise (`connect_to … failed`, printed by ssh on this Mac, not by "
                + "the plugin) and the shim's backoff must be stated — the symptom reads as a "
                + "plugin bug and the user must learn whose stderr it is"
        )
    }

    func testNotesStateThatARemoteTokenCannotReachLocalFiles() throws {
        let notes = try plan().notes.joined(separator: "\n").lowercased()
        XCTAssertTrue(notes.contains("remote"))
        XCTAssertTrue(
            notes.contains("never") && notes.contains("local file"),
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

    func testRemoteSetupKeepsTokenInStdinAndOutOfEveryArgv() throws {
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
                    verifyCommands: [], updateCommands: [], uninstallCommands: [], notes: []
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
                    verifyCommands: [], updateCommands: [], uninstallCommands: [], notes: []
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
                    sshConfigSnippet: "", remoteCommands: ["echo hi"], verifyCommands: [],
                    updateCommands: [], uninstallCommands: [], notes: []
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
}
