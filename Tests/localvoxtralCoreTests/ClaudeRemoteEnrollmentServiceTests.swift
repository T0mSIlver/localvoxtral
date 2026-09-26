import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore
import localvoxtralTestSupport

private final class MemoryLocalHerdrConfigFileSystem: ClaudeLocalHerdrConfigFileSystem {
    struct Storage: Sendable {
        var state: ClaudeLocalHerdrConfigState
        var createdDirectoryPermissions: [UInt16] = []
        var writes: [(data: Data, permissions: UInt16, expectedConfigPresent: Bool)] = []
    }

    private let storage: Mutex<Storage>

    init(state: ClaudeLocalHerdrConfigState) {
        storage = Mutex(Storage(state: state))
    }

    var snapshot: Storage { storage.withLock { $0 } }

    func readState() throws -> ClaudeLocalHerdrConfigState {
        storage.withLock { $0.state }
    }

    func createConfigDirectory(permissions: UInt16) throws {
        storage.withLock {
            $0.createdDirectoryPermissions.append(permissions)
            $0.state.directoryExists = true
        }
    }

    func atomicWriteConfig(_ data: Data, permissions: UInt16, expectedConfigPresent: Bool) throws {
        storage.withLock {
            $0.writes.append((data, permissions, expectedConfigPresent))
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

    /// Tests/localvoxtralCoreTests/<this file> → repo root. Derived from the source
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

    /// The block this build writes for `host` behind `sandbox-vpn`.
    private func expectedBlock(remoteForwardPort: UInt16 = 28_542) -> String {
        ClaudeRemoteEnrollmentService.sshConfigSnippet(
            host: host, sshHostAlias: "sandbox-vpn", listenerPort: 8473,
            remoteForwardPort: remoteForwardPort
        )
    }

    private func plan(alias: String = "builder") throws -> ClaudeRemoteEnrollmentService.SetupPlan {
        try ClaudeRemoteEnrollmentService.plan(host: host, sshHostAlias: alias)
    }

    private func runShellScript(
        _ script: Data,
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()
        input.fileHandleForWriting.write(script)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: SSH config snippet

    func testSSHSnippetForwardsTheListenerPortBothWays() throws {
        let snippet = try plan().sshConfigSnippet
        XCTAssertTrue(snippet.contains("Host builder"))
        // RemoteForward <remote-port> <local-host>:<local-port> — the remote's
        // 127.0.0.1:8473 comes out of our ssh client and lands on our listener.
        // Read from the listener, not hardcoded: a snippet port that drifted
        // from it would be a tunnel to nothing, and fail open.
        let port = ClaudeRemoteListenerLimits.default.port
        XCTAssertEqual(port, 8473, "the documented port, already in users' ssh configs")
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
        for violation in configArgumentViolations(in: text) {
            XCTFail(violation, line: line)
        }
    }

    /// What `assertEveryConfigArgumentIsThePort` fails with, one message per
    /// broken rule; empty when every `--config` is the port.
    private func configArgumentViolations(in text: String) -> [String] {
        let key = ClaudeRemoteEnrollmentService.portConfigKey
        var violations: [String] = []
        for range in text.ranges(of: "--config ") {
            let rest = text[range.upperBound...]
            guard let closing = rest.dropFirst().firstIndex(of: "'") else {
                violations.append("unterminated --config argument in: \(text)")
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
            if !(after.isEmpty || after.first == " " || after.first == "\n"
                || (after.first == "'" && (tail.isEmpty || tail.first == " " || tail.first == "\n")))
            {
                violations.append("a --config argument must END at its closing quote: \(text)")
            }
            let digits = argument.dropFirst("'\(key)=".count).dropLast()
            if !(argument.hasPrefix("'\(key)=") && !digits.isEmpty && digits.allSatisfy(\.isNumber)) {
                violations.append("the only config this path may write is a numeric port, got \(argument)")
            }
        }
        return violations
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
            XCTAssertFalse(
                configArgumentViolations(in: smuggled).isEmpty,
                "this shape must be rejected by the anchoring: \(smuggled)")
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
        let install = try pluginSetupScripts(before: nil, token: token)[1]
        XCTAssertTrue(install.contains(
            "--config '\(ClaudeRemoteEnrollmentService.tokenConfigKey)=\(token)'"
                + " --config '\(ClaudeRemoteEnrollmentService.portConfigKey)=28511'"
        ))
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

    // MARK: SSH config block currency (review finding 1, extended 2026-09-06)

    func testForwardStateReportsWhetherThisHostsBlockAlreadyCarriesThePort() throws {
        let legacy = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "", snippet: try plan().sshConfigSnippet, hostID: host.id
        )
        let filesystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteRemoteConfigStateFixture.state(configText: legacy)
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: filesystem)
        let legacyBlock = try plan().sshConfigSnippet
        XCTAssertEqual(service.sshConfigBlockIsCurrent(snippet: legacyBlock, hostID: host.id), true)
        let allocated = ClaudeRemoteEnrollmentService.sshConfigSnippet(
            host: host, sshHostAlias: "builder", listenerPort: 8473, remoteForwardPort: 28511
        )
        XCTAssertEqual(
            service.sshConfigBlockIsCurrent(snippet: allocated, hostID: host.id), false,
            "a legacy block does not forward the allocated port, and saying it does is the split brain"
        )
        XCTAssertEqual(
            service.sshConfigBlockIsCurrent(snippet: allocated, hostID: "hunknown"), false,
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

    /// The block check keeps its cannot-tell semantics: no config file yet is
    /// nil, not false.
    func testTheBooleanForwardCheckKeepsItsCannotTellSemantics() throws {
        let empty = ClaudeRemoteEnrollmentService(
            sshConfigFileSystem: MemorySSHConfigFileSystem(
                state: ClaudeRemoteSSHConfigState(
                    directoryExists: true, configData: nil, configPermissions: nil
                )
            )
        )
        XCTAssertNil(
            empty.sshConfigBlockIsCurrent(snippet: expectedBlock(), hostID: host.id),
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
        XCTAssertNil(
            ClaudeRemoteEnrollmentService().sshConfigBlockIsCurrent(snippet: expectedBlock(), hostID: host.id)
        )
    }

    /// Each row: the directive lines between our BEGIN/END markers, and
    /// whether that block is current for `expectedBlock()`.
    func testSSHConfigCurrencyOfHandWrittenBlocks() throws {
        let rows: [(name: String, lines: [String], current: Bool, why: String)] = [
            // The owner's exact shape, and the one this check exists for now: a
            // host enrolled before `SendEnv LC_LVX_TTY` existed already forwards
            // the right port, so a port-only currency check reported "current" and
            // `Update Plugin…` skipped the local rewrite — the line the release
            // notes promise that button adds never arrived (review finding B1).
            ("ABlockWithTheRIGHTPortButNoSendEnvIsNOTCurrent", [
                "Host sandbox-vpn",
                "    RemoteForward 28542 127.0.0.1:8473",
                "    ExitOnForwardFailure no",
            ], false, "the port matches and the block is still stale"),
            // `# SendEnv LC_LVX_TTY` contains the substring and sends nothing.
            ("ACOMMENTEDSendEnvDoesNotMakeABlockCurrent", [
                "Host sandbox-vpn",
                "    RemoteForward 28542 127.0.0.1:8473",
                "    ExitOnForwardFailure no",
                "    # SendEnv LC_LVX_TTY",
            ], false, ""),
            ("SSHConfigCurrencyAcceptsTabsAndRepeatedSpacesBetweenDirectiveFields", [
                "Host sandbox-vpn",
                "\tRemoteForward\t28542\t127.0.0.1:8473",
                "  ExitOnForwardFailure    no",
                "    SendEnv   LC_LVX_TTY",
            ], true, "OpenSSH accepts any horizontal whitespace between directive fields"),
        ]
        for row in rows {
            let block = (
                [ClaudeRemoteEnrollmentService.blockBegin(hostID: host.id)]
                    + row.lines
                    + [ClaudeRemoteEnrollmentService.blockEnd(hostID: host.id)]
            ).joined(separator: "\n")
            let filesystem = MemorySSHConfigFileSystem(
                state: ClaudeRemoteRemoteConfigStateFixture.state(configText: block)
            )
            let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: filesystem)
            XCTAssertEqual(
                service.sshConfigBlockIsCurrent(snippet: expectedBlock(), hostID: host.id), row.current,
                "\(row.name): \(row.why)"
            )
        }
    }

    /// Port and `SendEnv` right, the rest wrong: each of these is a dead or
    /// misrouted tunnel that a port-and-SendEnv check called current, so the
    /// update run skipped the rewrite and the row hid its button.
    func testABlockIsCurrentOnlyWhenEveryDirectiveMatches() throws {
        let expected = expectedBlock()
        func isCurrent(_ block: String) -> Bool? {
            ClaudeRemoteEnrollmentService(
                sshConfigFileSystem: MemorySSHConfigFileSystem(
                    state: ClaudeRemoteRemoteConfigStateFixture.state(
                        configText: "Host other\n    User me\n\n\(block)\n"
                    )
                )
            ).sshConfigBlockIsCurrent(snippet: expected, hostID: host.id)
        }
        XCTAssertEqual(isCurrent(expected), true)
        XCTAssertEqual(
            isCurrent(expected.replacingOccurrences(of: "127.0.0.1:8473", with: "127.0.0.1:9999")),
            false, "the forward reaches the wrong local port"
        )
        XCTAssertEqual(
            isCurrent(expected.replacingOccurrences(of: "Host sandbox-vpn", with: "Host builder")),
            false, "the block names another alias"
        )
        XCTAssertEqual(
            isCurrent(expected.replacingOccurrences(of: "    ExitOnForwardFailure no\n", with: "")),
            false, "a directive is missing"
        )
        XCTAssertEqual(
            isCurrent(expected.replacingOccurrences(
                of: "    SendEnv LC_LVX_TTY", with: "    SendEnv LC_LVX_TTY\n    User root"
            )),
            false, "a directive was added"
        )
        XCTAssertEqual(
            isCurrent(expected.replacingOccurrences(
                of: "    SendEnv LC_LVX_TTY", with: "    SendEnv LC_LVX_TTY\n\n    # a note"
            )),
            true, "blank and comment lines do not change what ssh reads"
        )
        XCTAssertEqual(
            isCurrent(expected
                .replacingOccurrences(of: "ExitOnForwardFailure no", with: "exitonforwardfailure=no")
                .replacingOccurrences(of: "SendEnv LC_LVX_TTY", with: "SENDENV = LC_LVX_TTY")),
            true, "OpenSSH keywords are case-insensitive and may take an ="
        )
        XCTAssertEqual(
            isCurrent(expected.replacingOccurrences(of: "LC_LVX_TTY", with: "lc_lvx_tty")),
            false, "argument case still counts"
        )
    }

    func testForwardStateIgnoresARemoteForwardOutsideThisHostsBlock() throws {
        // Someone else's `RemoteForward 28511` elsewhere in the config is not
        // this host's block being current.
        let foreign = "Host other\n    RemoteForward 28511 127.0.0.1:8473\n"
        let filesystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteRemoteConfigStateFixture.state(configText: foreign)
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: filesystem)
        XCTAssertEqual(
            service.sshConfigBlockIsCurrent(
                snippet: expectedBlock(remoteForwardPort: 28511), hostID: host.id
            ),
            false
        )
    }

    func testTheUpdatePathMigratesAnAlreadyEnrolledHostToTheAllocatedPort() throws {
        // A host enrolled before #215 has no `port` option at all, so its shim
        // posts to 8473 while this Mac has moved. This line is the only fix
        // that does not re-send a credential.
        let update = try pluginSetupScripts(before: "1.4.0", token: nil)[1]
        let migration = try XCTUnwrap(update.components(separatedBy: "\n").last)
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
        _ = try? service.setupRemotePlugin(sshHostAlias: "builder", token: token, remoteForwardPort: 28_511)
        _ = try? service.setupRemoteHerdr(sshHostAlias: "builder")

        let recorded = calls.withLock { $0 }
        XCTAssertEqual(recorded.count, 2, "one listing, one herdr script")
        for invocation in recorded {
            let terminator = try XCTUnwrap(invocation.argv.firstIndex(of: "--"))
            let alias = try XCTUnwrap(invocation.argv.firstIndex(of: "builder"))
            XCTAssertLessThan(terminator, alias, "the alias must sit after `--`")
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
            host: second, sshHostAlias: "other"
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

    // MARK: Remote plugin scripts

    /// The three scripts `setupRemotePlugin` can send as its install call, one
    /// per state the first listing reports: absent (with the enrollment
    /// token), stale and current (the update run's, without one).
    private func pluginMutationScripts() throws -> (install: String, update: String, current: String) {
        (
            try pluginSetupScripts(before: nil, token: token)[1],
            try pluginSetupScripts(before: "1.4.0", token: nil)[1],
            try pluginSetupScripts(before: ClaudeRemoteEnrollmentService.remotePluginVersion, token: nil)[1]
        )
    }

    func testRemoteSetupGoesThroughTheClaudePluginCLI() throws {
        // Never by hand-editing the remote's ~/.claude/settings.json: that file
        // is the user's, Claude Code owns its schema, and the CLI is the
        // supported interface.
        let scripts = try pluginSetupScripts(before: nil, token: token)
        XCTAssertEqual(
            scripts[1],
            "set -eu\n" + ClaudeRemoteEnrollmentService.claudePathResolverPreamble
                + "claude plugin marketplace add \(ClaudeRemoteEnrollmentService.repositoryMarketplaceReference)\n"
                + "claude plugin install localvoxtral-remote@localvoxtral --config 'token=\(token)' --config 'port=28511'"
        )
        for script in scripts {
            XCTAssertFalse(script.contains("settings.json"), "never touch the user's Claude config")
        }
    }

    func testTheInstallCommandInstallsTheRemotePluginNotTheLocalOne() throws {
        // The two plugins are structurally different — a curl shim and a token
        // versus a publisher-binary shim and peer credentials. Installing the
        // local one on a remote host would fail open forever and look like a
        // tunnel bug.
        let scripts = try pluginMutationScripts()
        for script in [scripts.install, scripts.update, scripts.current] {
            XCTAssertTrue(script.contains("claude plugin install \(ClaudeRemoteEnrollmentService.remotePluginReference) "))
            XCTAssertFalse(
                script.contains(" \(ClaudePluginAssets.pluginName)@"),
                "must not install the local plugin on a remote host"
            )
        }
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
    /// functional — `applySSHConfigSnippet` and `sshConfigBlockIsCurrent` both
    /// find the block by them.
    func testNothingInThePlanCarriesACommentExceptTheTwoDelimiters() throws {
        let commentLines = try allocatedPlan().sshConfigSnippet
            .components(separatedBy: "\n")
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
    func testAStalePluginIsRefreshedMarketplaceFirstThenThePlugin() throws {
        // Three since per-Mac ports (#215): the third writes only the port, for
        // a host enrolled before the option existed. `plugin update` has no
        // `--config` on 2.1.220, so it cannot be folded into the second.
        XCTAssertEqual(
            try pluginMutationScripts().update,
            "set -eu\n" + ClaudeRemoteEnrollmentService.claudePathResolverPreamble
                + "claude plugin marketplace update \(ClaudePluginAssets.marketplaceName)\n"
                + "claude plugin update localvoxtral-remote@localvoxtral\n"
                + "claude plugin install \(ClaudeRemoteEnrollmentService.remotePluginReference) "
                + "--config '\(ClaudeRemoteEnrollmentService.portConfigKey)=28511'"
        )
    }

    func testTheUpdatePathNeverCarriesTheToken() throws {
        // `plugin update` preserves the stored config, so this path has no
        // reason to hold the credential — and a script with no token in it
        // cannot leak one into a log or an error.
        let scripts = try pluginMutationScripts()
        for script in [scripts.update, scripts.current] {
            XCTAssertFalse(script.contains(token))
            XCTAssertFalse(script.contains(ClaudeRemoteEnrollmentService.tokenConfigKey + "="))
            // Not a blanket ban on `--config` any more: the port migration is a
            // config write, and it is the whole point of this path since #215.
            // Every `--config` on it must be the port one — that is a stricter
            // statement than "no --config", not a looser one.
            assertEveryConfigArgumentIsThePort(in: script)
        }
    }

    func testEveryPluginSetupScriptSurvivesANonInteractiveSSHPath() throws {
        // Same failure the verify probe hit: `ssh host /bin/sh -s` skips the
        // login rc, so claude is routinely off PATH there.
        let scripts = try pluginSetupScripts(before: "1.4.0", token: nil)
            + pluginSetupScripts(before: nil, token: token)
        for script in scripts {
            XCTAssertTrue(
                script.hasPrefix("set -eu\n" + ClaudeRemoteEnrollmentService.claudePathResolverPreamble),
                "a setup script must not depend on the remote shell's rc-file PATH"
            )
        }
    }

    /// Ported from `testUpdateCommandsSayWhyReinstallingIsNotAnUpdate`.
    ///
    /// The app runs the update itself now, so the explanation a person needs
    /// before running it by hand — that re-running the install is NOT an
    /// update, and that updating does not cost them their token — lives on
    /// the docs page.
    func testWhyReinstallingIsNotAnUpdateIsInTheDocs() throws {
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
    /// clause below was asserted on `notes` before — except the tmux one, which
    /// main's `testNotesCoverTheCaveatsThatBiteFirst` (2026-09-05) inverted when
    /// the window-title marker was removed: no OSC 2 is written any more, so
    /// prescribing `set-titles` would be advice for a mechanism that no longer
    /// exists. The page names the multiplexer limits of the joins that replaced
    /// it instead.
    func testTheDocsPageCoversTheCaveatsThatBiteFirst() throws {
        let documentation = try documentation().lowercased()
        XCTAssertTrue(documentation.contains("tmux"), "the multiplexer limits live with the join, not a title marker")
        XCTAssertFalse(
            documentation.contains("set-titles"),
            "the tmux/screen title caveat went with the title marker (2026-09-05): no OSC 2 is written any more, so telling a user to configure their multiplexer's title passthrough would be advice for a mechanism that no longer exists"
        )
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

    func testTheDocsPageListsEveryAutomatedSetupCommandOutsideSettings() throws {
        let documentation = try documentation()
        for command in [
            "ssh -o BatchMode=yes -o ClearAllForwardings=yes -- <alias> /bin/sh -s",
            "ssh -o BatchMode=yes -- <alias> /bin/sh -s",
            "ssh -G -- <alias>",
            "claude plugin list --json",
            "claude plugin marketplace add T0mSIlver/localvoxtral",
            "claude plugin marketplace update localvoxtral",
            "claude plugin update localvoxtral-remote@localvoxtral",
            "claude plugin install localvoxtral-remote@localvoxtral",
            "printf 'LVX_TTY:%s\\n' \"${LC_LVX_TTY-}\"",
            "command -v herdr",
            "herdr server reload-config",
            "command -v curl",
            "/v1/hook/SessionStart",
            "claude plugin list`",
        ] {
            XCTAssertTrue(documentation.contains(command), "missing command documentation: \(command)")
        }
        XCTAssertTrue(documentation.contains(ClaudeShellRCSetup.snippet(for: .zsh)))
        XCTAssertTrue(documentation.contains(ClaudeShellRCSetup.snippet(for: .fish)))
        XCTAssertTrue(documentation.contains(ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet))
    }

    /// The list above is literals; this ties the `claude` half of it to what
    /// `setupRemotePlugin` actually sends, so a changed script cannot leave
    /// the page describing the old one.
    func testTheDocsPageListsEveryClaudeCommandThePluginSetupRuns() throws {
        let documentation = try documentation()
        let scripts = try pluginSetupScripts(before: "1.4.0", token: nil)
            + pluginSetupScripts(before: nil, token: token)
        let commands = Set(
            scripts.flatMap { $0.components(separatedBy: "\n") }
                .filter { $0.hasPrefix("claude ") }
                .map { $0.components(separatedBy: " --config ")[0] }
        )
        XCTAssertEqual(commands.count, 5, "list, marketplace add/update, plugin update/install: \(commands)")
        for command in commands {
            XCTAssertTrue(documentation.contains(command), "missing command documentation: \(command)")
        }
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

        try service.insertSSHConfig(snippet: try plan().sshConfigSnippet, hostID: host.id)

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

        try service.insertSSHConfig(snippet: try plan().sshConfigSnippet, hostID: host.id)

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

        try service.insertSSHConfig(snippet: try plan(alias: "new-builder").sshConfigSnippet, hostID: host.id)

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

        XCTAssertThrowsError(try service.insertSSHConfig(snippet: try plan(alias: "builder").sshConfigSnippet, hostID: host.id)) {
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

        XCTAssertThrowsError(try service.insertSSHConfig(snippet: try plan(alias: "builder").sshConfigSnippet, hostID: host.id)) {
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
                try service.insertSSHConfig(snippet: try plan(alias: "builder").sshConfigSnippet, hostID: host.id)
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
            try service.insertSSHConfig(snippet: try plan(alias: "builder").sshConfigSnippet, hostID: host.id)
            XCTAssertEqual(fileSystem.snapshot.writes.count, 1)
        }
    }

    // MARK: Execution

    /// Calls the service refuses before doing any work. A service with no
    /// runner (or no local file system) spawns nothing, ever, and says so
    /// instead of quietly reaching for a default. An invalid alias is refused
    /// before SSH: the shared runner below fails any row that reaches it.
    func testServiceCallsAreRefusedBeforeAnyWork() throws {
        typealias Service = ClaudeRemoteEnrollmentService
        let token = token
        let runnerCalls = Mutex(0)
        let guarded = Service(runner: { _ in
            runnerCalls.withLock { $0 += 1 }
            XCTFail("the runner must never be reached with an invalid alias")
            return .init(exitCode: 0, message: "")
        })
        let rows: [(name: String, expected: Service.ServiceError, call: () throws -> Void)] = [
            ("PluginSetupIsRefusedWithoutAnInjectedRunner", .executionNotConfigured, {
                _ = try Service().setupRemotePlugin(sshHostAlias: "builder", token: token, remoteForwardPort: 28_511)
            }),
            ("VerificationIsRefusedWithoutAnInjectedRunner", .executionNotConfigured, {
                _ = try Service().executeVerification(sshHostAlias: "builder", listenerIsBound: true)
            }),
            ("HerdrSetupIsRefusedWithoutAnInjectedRunner", .executionNotConfigured, {
                _ = try Service().setupRemoteHerdr(sshHostAlias: "builder")
            }),
            ("LocalHerdrPanelConfigurationIsRefusedWithoutAnInjectedFileSystem",
             .localHerdrConfigEditingNotConfigured, {
                _ = try Service().configureLocalHerdrPanel()
            }),
            ("PlanRefusesAnInvalidAlias", .invalidHostAlias, {
                _ = try self.plan(alias: "host\nRemoteForward 22 evil:22")
            }),
            ("PluginSetupRefusesAnInvalidAlias", .invalidHostAlias, {
                _ = try guarded.setupRemotePlugin(sshHostAlias: "a b", token: token, remoteForwardPort: 28_511)
            }),
            ("VerificationRefusesAnInvalidAlias", .invalidHostAlias, {
                _ = try guarded.executeVerification(sshHostAlias: "a b", listenerIsBound: true)
            }),
            ("HerdrSetupRefusesAnInvalidAliasBeforeSSH", .invalidHostAlias, {
                _ = try guarded.setupRemoteHerdr(sshHostAlias: "builder; touch /tmp/no")
            }),
        ]
        for row in rows {
            XCTAssertThrowsError(try row.call(), row.name) { error in
                XCTAssertEqual(error as? Service.ServiceError, row.expected, row.name)
            }
        }
        XCTAssertEqual(runnerCalls.withLock { $0 }, 0)
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
    /// No process THIS Mac spawns carries the token in its arguments: it rides
    /// the ssh child's stdin, so `ps` here never sees it. On the host,
    /// `claude plugin install` takes its config as a flag and has no stdin
    /// path, so the token IS in that command's argv there and in `~/.claude`
    /// afterwards. That is documented rather than papered over.
    func testRemoteSetupKeepsTokenOutOfEveryArgvOnTHISMac() throws {
        let calls = PluginSetupCalls()
        let service = ClaudeRemoteEnrollmentService(
            runner: pluginSetupRunner(
                before: nil, after: ClaudeRemoteEnrollmentService.remotePluginVersion, calls: calls
            )
        )

        XCTAssertEqual(
            try service.setupRemotePlugin(sshHostAlias: "builder", token: token, remoteForwardPort: 28_511),
            .installed
        )

        XCTAssertTrue(calls.all.allSatisfy { !$0.argv.joined(separator: " ").contains(token) })
        XCTAssertTrue(calls.scripts.contains { $0.contains(token) })
        // …and the remote-side exposure is stated where a user will meet it,
        // rather than being implied away.
        let documentation = try documentation()
        XCTAssertTrue(documentation.contains("local and only local"))
        XCTAssertTrue(documentation.contains("/proc/<pid>/cmdline"))
        XCTAssertTrue(documentation.lowercased().contains("rotate"))
    }

    /// MINOR 5 (review round 2): the snippet's token-freedom assertion was lost
    /// in the port and is restored here.
    ///
    /// `~/.ssh/config` gets copied between machines and pasted into issues, so
    /// the block may never carry the token. The update path's scripts are
    /// pinned token-free in `testTheUpdatePathNeverCarriesTheToken`, and the
    /// install script's token in
    /// `testTheInstallCommandCarriesBothTheTokenAndTheMatchingPort`.
    func testTheSnippetNeverCarriesTheToken() throws {
        XCTAssertFalse(try allocatedPlan().sshConfigSnippet.contains(token))
    }

    /// An error is the most-copied string in the app: alerts, the log, bug
    /// reports. Host output that echoes the token, and a runner timeout whose
    /// captured output does, must both leave the service without it.
    func testAPluginSetupFailureNeverCarriesTheToken() throws {
        let token = token
        let echoingInstall = ClaudeRemoteEnrollmentService(
            runner: pluginSetupRunner(
                before: nil,
                after: nil,
                install: .init(exitCode: 1, message: "failed running: claude plugin install --config 'token=\(token)'"),
                calls: PluginSetupCalls()
            )
        )
        let timingOut = ClaudeRemoteEnrollmentService(runner: { _ in
            throw ClaudeRemoteEnrollmentService.RunnerFailure.timedOut(
                seconds: 12, message: "last output contained \(token)"
            )
        })
        for (name, service) in [("install failure", echoingInstall), ("timeout", timingOut)] {
            XCTAssertThrowsError(
                try service.setupRemotePlugin(sshHostAlias: "builder", token: token, remoteForwardPort: 28_511),
                name
            ) { error in
                XCTAssertFalse(String(describing: error).contains(token), name)
                XCTAssertFalse(error.localizedDescription.contains(token), name)
            }
        }
        XCTAssertThrowsError(
            try timingOut.setupRemotePlugin(sshHostAlias: "builder", token: token, remoteForwardPort: 28_511)
        ) { error in
            guard case .commandTimedOut(_, _, let seconds, _)? =
                error as? ClaudeRemoteEnrollmentService.ServiceError
            else { return XCTFail("expected commandTimedOut, got \(error)") }
            XCTAssertEqual(seconds, 12, "a timeout stays a timeout")
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

    /// The first tunnel probe clears forwardings (#656). A probe that carried
    /// the alias's RemoteForward bound the port itself and curled through its
    /// own forward, so it passed on a host where nothing else ever holds the
    /// tunnel: every host Claude Desktop alone reaches.
    func testTheFirstTunnelProbeCannotOpenTheTunnelItChecksAndSendsNoCredential() throws {
        let recorded = try verify(
            results: [.init(exitCode: 0, message: "LVX_HTTP:401"), .init(exitCode: 0, message: "")]
        ).invocations
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(
            recorded[0].argv,
            ["ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--", "builder", "/bin/sh", "-s"]
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

    /// One verdict of `executeVerification`: the probes' scripted answers
    /// (tunnel probe, then plugin probe) and what the check of `kind` must say.
    /// `why` is appended to every assertion message of the row.
    private struct VerdictCase {
        let name: String
        var remoteForwardPort: UInt16 = 8473
        var listenerIsBound = true
        let results: [ClaudeRemoteEnrollmentService.RunResult]
        var kind: ClaudeRemoteEnrollmentService.VerificationCheck.Kind = .tunnel
        let passed: Bool
        var summary: String?
        var summaryContains: [String] = []
        var summaryLacks: [String] = []
        var hintContains: [String] = []
        var detailContains: [String] = []
        var detailLacks: [String] = []
        var why = ""
    }

    func testVerificationVerdicts() throws {
        let leaked = "tokenQQQQRRRRSSSSTTTTUUUU77776666"
        let cases: [VerdictCase] = [
            VerdictCase(
                name: "A401MeansTheTunnelIsUpWhenOurOwnListenerIsBound",
                results: [.init(exitCode: 0, message: "LVX_HTTP:401\n"), .init(exitCode: 0, message: "")],
                passed: true,
                summaryContains: ["Tunnel is up"],
                why: "401 is the SUCCESS signal, and the app must say so, not the user"
            ),
            // Review finding, round 1: a 401 proves something on this Mac answered
            // through the tunnel, not that it was us. When our own bind failed, the
            // squatter holding the listener port is what replied — and the old verdict
            // called that a pass.
            VerdictCase(
                name: "A401DoesNotPassWhenOurListenerIsNotBound",
                remoteForwardPort: 28511,
                listenerIsBound: false,
                results: [.init(exitCode: 0, message: "LVX_HTTP:401"), .init(exitCode: 0, message: "")],
                passed: false,
                summaryContains: ["Something else answered", "28511"],
                hintContains: ["not listening"],
                why: "the remedy is the port conflict on THIS Mac, and the user must be sent there"
            ),
            // The script always exits 0 and prints one token, so 000 can only mean
            // "nothing answered on the forwarded port".
            // The first probe found nothing standing, and the second opened the
            // config block's own forward: still nothing.
            VerdictCase(
                name: "CurlConnectFailureThroughBothProbesBlamesTheConfigNotSSH",
                results: [
                    .init(exitCode: 0, message: "LVX_HTTP:000"),
                    .init(exitCode: 0, message: "LVX_HTTP:000"),
                    .init(exitCode: 0, message: ""),
                ],
                passed: false,
                summary: "The SSH config did not open a tunnel.",
                hintContains: ["remote forwarding"],
                why: "the second probe was the SSH session; advising one would repeat it"
            ),
            // #656: the config block works, and nothing keeps it open between
            // checks. The old single probe passed here.
            VerdictCase(
                name: "ATunnelOnlyTheCheckOpenedIsNotAPass",
                results: [
                    .init(exitCode: 0, message: "LVX_HTTP:000"),
                    .init(exitCode: 0, message: "LVX_HTTP:401"),
                    .init(exitCode: 0, message: ""),
                ],
                passed: false,
                summary: "Your SSH config opens the tunnel, but nothing keeps it open.",
                hintContains: ["Keep the tunnel open"],
                why: "hooks arrive only while something holds the forward"
            ),
            VerdictCase(
                name: "AnSSHFailureIsDistinctFromAnAbsentTunnel",
                results: [
                    .init(exitCode: 255, message: "ssh: Could not resolve hostname builder"),
                    .init(exitCode: 255, message: "ssh: Could not resolve hostname builder"),
                ],
                passed: false,
                summary: "Could not reach builder over SSH.",
                detailContains: ["255"],
                why: "the exit code is the diagnosable part we own"
            ),
            // A squatter that returns 200 is not a pass, and not "no tunnel"
            // either: the user has to learn something else holds the port.
            VerdictCase(
                name: "AStrangerAnsweringOnThePortIsItsOwnVerdict",
                remoteForwardPort: 28511,
                results: [.init(exitCode: 0, message: "LVX_HTTP:200"), .init(exitCode: 0, message: "")],
                passed: false,
                summaryContains: ["28511"]
            ),
            // Field failure 2026-07-26: `ssh host /bin/sh -s` runs with sshd's
            // minimal PATH. "claude is not installed here" and "the plugin is not
            // installed" are different problems with different fixes.
            VerdictCase(
                name: "AMissingClaudeOnTheHostIsItsOwnVerdictNotAMissingPlugin",
                results: [
                    .init(exitCode: 0, message: "LVX_HTTP:401"),
                    .init(exitCode: 127, message: "localvoxtral: 'claude' was not found on this host's non-interactive PATH"),
                ],
                kind: .plugin,
                passed: false,
                summaryContains: ["Claude Code was not found"],
                summaryLacks: ["plugin is not installed"]
            ),
            VerdictCase(
                name: "AFailedPluginProbeStillLeaksNothingFromTheHost",
                results: [
                    .init(exitCode: 0, message: "LVX_HTTP:401"),
                    .init(exitCode: 3, message: "error: could not read config token=\(leaked)"),
                ],
                kind: .plugin,
                passed: false,
                detailContains: ["3"],
                detailLacks: [leaked],
                why: "the exit code is ours to report"
            ),
            // Truncation, a wrapper's rewrite, anything: three digits or it is not
            // a code, and a non-code must never be reported as one.
            VerdictCase(
                name: "AFramedAnswerThatIsNotAStatusCodeIsTreatedAsSilence",
                results: [
                    .init(exitCode: 0, message: "LVX_HTTP:not-a-code"),
                    .init(exitCode: 0, message: "LVX_HTTP:not-a-code"),
                    .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
                ],
                passed: false,
                summary: "The SSH config did not open a tunnel.",
                detailLacks: ["not-a-code"],
                why: "unparsed host text must not travel"
            ),
        ]
        for row in cases {
            let label = "\(row.name): \(row.why)"
            let checks = try verify(
                remoteForwardPort: row.remoteForwardPort,
                listenerIsBound: row.listenerIsBound,
                results: row.results
            ).checks
            guard let check = checks.first(where: { $0.kind == row.kind }) else {
                XCTFail("\(row.name): no \(row.kind) check")
                continue
            }
            XCTAssertEqual(check.passed, row.passed, label)
            if let summary = row.summary { XCTAssertEqual(check.summary, summary, label) }
            for text in row.summaryContains { XCTAssertTrue(check.summary.contains(text), "\(label) [\(text)]") }
            for text in row.summaryLacks { XCTAssertFalse(check.summary.contains(text), "\(label) [\(text)]") }
            for text in row.hintContains {
                XCTAssertTrue(check.hint?.contains(text) ?? false, "\(label) [\(text)]")
            }
            for text in row.detailContains { XCTAssertTrue(check.detail.contains(text), "\(label) [\(text)]") }
            for text in row.detailLacks { XCTAssertFalse(check.detail.contains(text), "\(label) [\(text)]") }
        }
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
                .init(exitCode: 0, message: "Welcome to builder\n401"),
                .init(exitCode: 0, message: "localvoxtral-remote@localvoxtral"),
            ]
        ).checks
        let tunnel = try XCTUnwrap(unframed.first { $0.kind == .tunnel })
        XCTAssertFalse(tunnel.passed, "an unframed line is not our probe speaking")
        XCTAssertEqual(tunnel.summary, "The SSH config did not open a tunnel.")
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

    // MARK: herdr agents-panel configuration

    func testHerdrAgentsHeaderWithTrailingCommentIsRefusedWithoutEditingTheConfig() throws {
        let calls = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            calls.withLock { $0.append(invocation) }
            return .init(exitCode: 0, message: "captured")
        })
        _ = try? service.setupRemoteHerdr(sshHostAlias: "builder")
        let invocation = try XCTUnwrap(calls.withLock { $0.first })

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvx-herdr-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = "[ui.sidebar.agents] # keep my custom panel\n"
        try Data(original.utf8).write(to: configURL)
        // The script checks for herdr before it reads the config; a stub that
        // fails if run proves the refusal comes first.
        let herdr = directory.appendingPathComponent("herdr")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: herdr)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)

        let result = try runShellScript(
            invocation.standardInput,
            environment: [
                "HERDR_CONFIG_PATH": configURL.path,
                "PATH": "\(directory.path):/usr/bin:/bin",
            ]
        )

        XCTAssertEqual(result.status, 42, "the existing table must take the refusal path")
        XCTAssertTrue(result.output.contains("LVX_HERDR_CUSTOMIZED"))
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }

    /// 42 is the refusal exit only with the refusal frame beside it; a reload
    /// that dies with the same code is a failure. A timeout keeps its category.
    func testHerdrSetupTreatsAnUnmarkedExit42AndATimeoutAsFailures() {
        let unmarked = ClaudeRemoteEnrollmentService(runner: { _ in
            .init(exitCode: 42, message: "reload failed")
        })
        XCTAssertThrowsError(try unmarked.setupRemoteHerdr(sshHostAlias: "builder")) { error in
            guard case .commandFailed(_, _, let exitCode, _)? =
                error as? ClaudeRemoteEnrollmentService.ServiceError
            else { return XCTFail("expected commandFailed, got \(error)") }
            XCTAssertEqual(exitCode, 42)
        }

        let timingOut = ClaudeRemoteEnrollmentService(runner: { _ in
            throw ClaudeRemoteEnrollmentService.RunnerFailure.timedOut(seconds: 12, message: "ssh timed out")
        })
        XCTAssertThrowsError(try timingOut.setupRemoteHerdr(sshHostAlias: "builder")) { error in
            guard case .commandTimedOut(_, _, let seconds, _)? =
                error as? ClaudeRemoteEnrollmentService.ServiceError
            else { return XCTFail("expected commandTimedOut, got \(error)") }
            XCTAssertEqual(seconds, 12)
        }
    }

    // MARK: local herdr agents-panel configuration

    func testLocalHerdrPanelStatusMatchesWhatSetUpWouldDo() {
        func status(_ content: String?, symlink: Bool = false) -> ClaudeRemoteEnrollmentService.LocalHerdrPanelStatus {
            ClaudeRemoteEnrollmentService(
                localHerdrConfigFileSystem: MemoryLocalHerdrConfigFileSystem(
                    state: ClaudeLocalHerdrConfigState(
                        directoryExists: content != nil,
                        configData: content.map { Data($0.utf8) },
                        configPermissions: content == nil ? nil : 0o644,
                        configIsSymlink: symlink
                    )
                )
            ).localHerdrPanelStatus()
        }
        let snippet = ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet
        XCTAssertEqual(status(nil), .notAdded)
        XCTAssertEqual(status("[keys]\nprefix = \"ctrl-b\"\n"), .notAdded)
        XCTAssertEqual(status("[keys]\nprefix = \"ctrl-b\"\n\n\(snippet)\n"), .added)
        XCTAssertEqual(
            status(snippet.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"), .added,
            "a CRLF file holding the row still holds it"
        )
        XCTAssertEqual(status("[ui.sidebar.agents]\nrows = [[\"agent\"]]\n"), .customized)
        XCTAssertEqual(status(snippet, symlink: true), .unknown)
        XCTAssertEqual(ClaudeRemoteEnrollmentService().localHerdrPanelStatus(), .unknown)
    }

    func testLocalHerdrPanelConfigurationAppendsTheRowOnce() throws {
        let fileSystem = MemoryLocalHerdrConfigFileSystem(
            state: ClaudeLocalHerdrConfigState(
                directoryExists: false,
                configData: nil,
                configPermissions: nil
            )
        )
        let service = ClaudeRemoteEnrollmentService(
            localHerdrConfigFileSystem: fileSystem
        )

        let steps = try service.configureLocalHerdrPanel()

        XCTAssertEqual(steps, [
            .init(
                index: 0,
                command: "configure local herdr agents panel",
                message: ClaudeRemoteEnrollmentService.localHerdrPanelReloadStatus
            )
        ])
        XCTAssertEqual(fileSystem.snapshot.createdDirectoryPermissions, [0o755])
        let writes = fileSystem.snapshot.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.permissions, 0o644)
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(writes.first?.data), as: UTF8.self),
            ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet + "\n"
        )
        // The appended config now carries the table, so a second offer must
        // take the customized refusal path rather than duplicate the block.
        XCTAssertThrowsError(try service.configureLocalHerdrPanel()) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteEnrollmentService.ServiceError,
                .localHerdrPanelConfigAlreadyCustomized
            )
        }
        XCTAssertEqual(fileSystem.snapshot.writes.count, 1)
    }

    func testLocalHerdrPanelConfigurationRefusesExistingAgentsConfiguration() {
        let rows: [(name: String, original: String)] = [
            ("LocalHerdrPanelConfigurationRefusesACustomizedTable", "[ui.sidebar.agents]\nrows = [[\"state_icon\"]]\n"),
            ("LocalHerdrPanelConfigurationRefusesAnExistingRowsKey", "[ui.sidebar]\nrows = [[\"state_icon\"]]\n"),
        ]
        for row in rows {
            let fileSystem = MemoryLocalHerdrConfigFileSystem(
                state: ClaudeLocalHerdrConfigState(
                    directoryExists: true,
                    configData: Data(row.original.utf8),
                    configPermissions: 0o644
                )
            )
            let service = ClaudeRemoteEnrollmentService(
                localHerdrConfigFileSystem: fileSystem
            )

            XCTAssertThrowsError(try service.configureLocalHerdrPanel(), row.name) { error in
                XCTAssertEqual(
                    error as? ClaudeRemoteEnrollmentService.ServiceError,
                    .localHerdrPanelConfigAlreadyCustomized,
                    row.name
                )
            }
            XCTAssertTrue(fileSystem.snapshot.writes.isEmpty, row.name)
            XCTAssertEqual(fileSystem.snapshot.state.configData, Data(row.original.utf8), row.name)
        }
    }

    func testLocalHerdrPanelConfigurationDeclaresWhetherTheConfigExisted() throws {
        // The write declares what `readState` saw, so the live writer's
        // pre-rename revalidation can refuse a swapped destination: absent
        // stays absent, present stays a plain file.
        let absent = MemoryLocalHerdrConfigFileSystem(
            state: ClaudeLocalHerdrConfigState(
                directoryExists: false,
                configData: nil,
                configPermissions: nil
            )
        )
        try ClaudeRemoteEnrollmentService(localHerdrConfigFileSystem: absent)
            .configureLocalHerdrPanel()
        XCTAssertEqual(absent.snapshot.writes.map(\.expectedConfigPresent), [false])

        let present = MemoryLocalHerdrConfigFileSystem(
            state: ClaudeLocalHerdrConfigState(
                directoryExists: true,
                configData: Data("# herdr\n".utf8),
                configPermissions: 0o644
            )
        )
        try ClaudeRemoteEnrollmentService(localHerdrConfigFileSystem: present)
            .configureLocalHerdrPanel()
        XCTAssertEqual(present.snapshot.writes.map(\.expectedConfigPresent), [true])
    }

    // MARK: - Live local herdr config: destination revalidation

    private func temporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "herdr-local-config-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true
        )
        return home
    }

    func testLiveLocalHerdrConfigWriteEnforcesTheDeclaredPresence() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileSystem = LiveClaudeLocalHerdrConfigFileSystem(homeDirectoryURL: home)
        let configURL = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("herdr", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)

        // Absent destination, declared absent: writes.
        try fileSystem.createConfigDirectory(permissions: 0o755)
        try fileSystem.atomicWriteConfig(
            Data("[ui]\n".utf8), permissions: 0o644, expectedConfigPresent: false
        )
        XCTAssertEqual(try Data(contentsOf: configURL), Data("[ui]\n".utf8))

        // Present destination, still declared absent: refuses (a planted file).
        XCTAssertThrowsError(
            try fileSystem.atomicWriteConfig(
                Data("[ui]\n".utf8), permissions: 0o644, expectedConfigPresent: false
            )
        )

        // Declared present but swapped for a symlink: refuses, and the link
        // target is untouched because the rename never ran.
        let victim = home.appendingPathComponent("victim.toml", isDirectory: false)
        try Data("victim".utf8).write(to: victim)
        try FileManager.default.removeItem(at: configURL)
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: victim)
        XCTAssertThrowsError(
            try fileSystem.atomicWriteConfig(
                Data("[ui]\n".utf8), permissions: 0o644, expectedConfigPresent: true
            )
        )
        XCTAssertEqual(try Data(contentsOf: victim), Data("victim".utf8))
    }

    func testLiveLocalHerdrConfigReportsAnUnreadableFileAsUnknownNotAbsent() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fileSystem = LiveClaudeLocalHerdrConfigFileSystem(homeDirectoryURL: home)
        try fileSystem.createConfigDirectory(permissions: 0o755)
        try fileSystem.atomicWriteConfig(
            Data("[ui]\n".utf8), permissions: 0o644, expectedConfigPresent: false
        )
        let configPath = home.appendingPathComponent(".config/herdr/config.toml").path
        // Restore the mode so the temporary tree can be removed.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: configPath
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)], ofItemAtPath: configPath
        )
        XCTAssertThrowsError(try fileSystem.readState(), "an unreadable file is not an absent one")
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService(localHerdrConfigFileSystem: fileSystem)
                .localHerdrPanelStatus(),
            .unknown
        )
    }

    func testLiveLocalHerdrConfigIgnoresANonDirectoryHerdrDev() throws {
        // A file (or symlink, or socket) at the dev path must not divert the
        // write: only an actual directory selects the dev build.
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(
            to: home.appendingPathComponent(".config/herdr-dev", isDirectory: false)
        )
        let fileSystem = LiveClaudeLocalHerdrConfigFileSystem(homeDirectoryURL: home)
        try fileSystem.createConfigDirectory(permissions: 0o755)
        try fileSystem.atomicWriteConfig(
            Data("[ui]\n".utf8), permissions: 0o644, expectedConfigPresent: false
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".config/herdr/config.toml").path
        ))
    }

    // MARK: - SendEnv on an ALREADY-enrolled host

    /// The owner's host was enrolled before `SendEnv LC_LVX_TTY` existed, so
    /// the line has to reach it through the path that REGENERATES the block —
    /// the plugin update — and not only through a fresh enrollment.
    func testRegeneratedSnippetCarriesSendEnvAndReplacesAnOlderBlock() {
        let host = ClaudeRemoteHost(
            id: "h1a2b3c4",
            label: "sandbox",
            sshHostAlias: "sandbox-vpn",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: nil,
            revokedAt: nil
        )
        let snippet = ClaudeRemoteEnrollmentService.sshConfigSnippet(
            host: host, sshHostAlias: "sandbox-vpn", listenerPort: 8473, remoteForwardPort: 28_542
        )
        // An exact LINE, not a substring: `# SendEnv LC_LVX_TTY` contains the
        // substring too, so a `contains` check passes for a commented-out
        // directive — caught by this test's own red run, 2026-09-06.
        XCTAssertTrue(
            snippet.components(separatedBy: "\n")
                .contains { $0.trimmingCharacters(in: .whitespaces) == "SendEnv LC_LVX_TTY" },
            "the block must carry the directive, not a comment about it: \(snippet)"
        )

        // A block written before the line existed — the owner's shape.
        let stale = [
            ClaudeRemoteEnrollmentService.blockBegin(hostID: host.id),
            "Host sandbox-vpn",
            "    RemoteForward 28542 127.0.0.1:8473",
            "    ExitOnForwardFailure no",
            ClaudeRemoteEnrollmentService.blockEnd(hostID: host.id),
        ].joined(separator: "\n")
        let updated = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "Host other\n    User someone\n\n" + stale,
            snippet: snippet,
            hostID: host.id
        )
        XCTAssertTrue(
            updated.components(separatedBy: "\n")
                .contains { $0.trimmingCharacters(in: .whitespaces) == "SendEnv LC_LVX_TTY" },
            "the update must add the directive"
        )
        XCTAssertEqual(
            updated.components(separatedBy: "Host sandbox-vpn").count - 1, 1,
            "replaced, never duplicated — OpenSSH is first-match-wins"
        )
        XCTAssertTrue(updated.contains("Host other"), "other stanzas untouched")
    }

    /// MAJOR 1 (review round 4). The README's hand-copy ssh-config block must
    /// carry exactly the directives `sshConfigSnippet` emits, so the two
    /// cannot drift again: a user hand-writing their config from the README
    /// without the tty-echo line gets a join that silently never fires, and
    /// the app's own currency check then flags their hand-built block as
    /// stale.
    func testTheREADMEManualSSHBlockMatchesTheShippedSnippet() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("integrations/claude-code/README.md"),
            encoding: .utf8
        )
        let readmeLines = readme.components(separatedBy: "\n")
        guard let beginIndex = readmeLines.firstIndex(where: {
            $0.contains("# BEGIN localvoxtral claude context")
        }), let endIndex = readmeLines[beginIndex...].firstIndex(where: {
            $0.contains("# END localvoxtral claude context")
        }) else {
            XCTFail("README manual ssh-config block not found")
            return
        }
        func directives(of blockLines: [String]) -> [String] {
            blockLines.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("Host ") }
        }
        let readmeDirectives = directives(of: Array(readmeLines[beginIndex...endIndex]))
        // The README's example block names these ports; the snippet must be
        // generated for the same pair, or the comparison proves nothing.
        let fixtureHost = ClaudeRemoteHost(
            id: "h1a2b3c4",
            label: "buildhost",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: nil,
            revokedAt: nil
        )
        let snippet = ClaudeRemoteEnrollmentService.sshConfigSnippet(
            host: fixtureHost,
            sshHostAlias: "builder",
            listenerPort: ClaudeRemoteListenerLimits.default.port,
            remoteForwardPort: 28511
        )
        XCTAssertTrue(
            snippet.contains("RemoteForward 28511 127.0.0.1:\(ClaudeRemoteListenerLimits.default.port)"),
            "the README example and this fixture assume these ports: \(snippet)"
        )
        XCTAssertEqual(
            readmeDirectives,
            directives(of: snippet.components(separatedBy: "\n")),
            "the README manual block drifted from sshConfigSnippet"
        )
    }

    // MARK: - One-flow setup probes

    func testEnvironmentProbeExportsARandomValueAndAcceptsOnlyItsExactReturn() throws {
        let invocations = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                invocations.withLock { $0.append(invocation) }
                // The frame with banner noise on both sides, exactly as the
                // merged stdout/stderr capture would deliver it: the verdict
                // must come from the framed line, not the raw bytes.
                return .init(
                    exitCode: 0,
                    message: "Welcome to builder\n"
                        + ClaudeRemoteEnrollmentService.envProbeFramePrefix
                        + (invocation.environment["LC_LVX_TTY"] ?? "")
                        + "\nLast login: today\n"
                )
            },
            environmentProbeValue: { "lvx-probe-fixed-for-test" }
        )

        XCTAssertEqual(
            try service.probeRemoteEnvironment(sshHostAlias: "builder"),
            .crossed
        )
        let invocation = try XCTUnwrap(invocations.withLock { $0.first })
        XCTAssertEqual(invocation.environment["LC_LVX_TTY"], "lvx-probe-fixed-for-test")
        XCTAssertTrue(invocation.argv.contains("ClearAllForwardings=yes"))
        XCTAssertFalse(invocation.argv.joined().contains("lvx-probe-fixed-for-test"))
        XCTAssertFalse(String(decoding: invocation.standardInput, as: UTF8.self)
            .contains("lvx-probe-fixed-for-test"))
    }

    func testEnvironmentProbeIgnoresABannerThatQuotesAWrongValue() throws {
        // A hostile or merely chatty host can print anything around the frame;
        // only the minted value's exact return may count, never a lookalike.
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                invocation.argv.contains("-G")
                    ? .init(exitCode: 0, message: "hostname builder\nsendenv LANG LC_*\n")
                    : .init(
                        exitCode: 0,
                        message: "LVX_TTY:not-the-probe-value"
                    )
            },
            environmentProbeValue: { "lvx-probe-real" }
        )
        XCTAssertEqual(
            try service.probeRemoteEnvironment(sshHostAlias: "builder"),
            .remoteAcceptEnvMissing,
            "a wrong echo is a mismatch, and the local side is sending"
        )
    }

    func testEnvironmentProbeReadsFirstLVXTTYFramedLineIgnoringOtherLVXPrefixLines() throws {
        let service = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                .init(
                    exitCode: 0,
                    message: "LVX_WARNING: authorized access only\n"
                        + "LVX_NODE=worker-42\n"
                        + ClaudeRemoteEnrollmentService.envProbeFramePrefix
                        + (invocation.environment["LC_LVX_TTY"] ?? "")
                        + "\nLVX_TRAILING: ignored\n"
                )
            },
            environmentProbeValue: { "lvx-probe-valid" }
        )

        XCTAssertEqual(
            try service.probeRemoteEnvironment(sshHostAlias: "builder"),
            .crossed,
            "a banner line prefixed with LVX_ must not shadow the LVX_TTY: frame"
        )
    }

    func testEnvironmentProbeDistinguishesMissingSendEnvFromMissingRemoteAcceptEnv() throws {
        let call = Mutex(0)
        let withoutSendEnv = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                let index = call.withLock { value -> Int in
                    defer { value += 1 }
                    return value
                }
                if index == 0 { return .init(exitCode: 0, message: "") }
                XCTAssertEqual(invocation.argv, ["ssh", "-G", "--", "builder"])
                return .init(exitCode: 0, message: "hostname builder\nsendenv LANG\n")
            },
            environmentProbeValue: { "lvx-probe-a" }
        )
        XCTAssertEqual(
            try withoutSendEnv.probeRemoteEnvironment(sshHostAlias: "builder"),
            .localSendEnvMissing
        )

        let withWildcard = ClaudeRemoteEnrollmentService(
            runner: { invocation in
                invocation.argv.contains("-G")
                    ? .init(exitCode: 0, message: "hostname builder\nsendenv LANG LC_*\n")
                    : .init(exitCode: 0, message: "")
            },
            environmentProbeValue: { "lvx-probe-b" }
        )
        XCTAssertEqual(
            try withWildcard.probeRemoteEnvironment(sshHostAlias: "builder"),
            .remoteAcceptEnvMissing
        )
    }

    /// The listing a real `claude plugin list --json` prints (Claude Code
    /// 2.1.x), framed by the listing script, with a banner on each side as a
    /// login shell's merged pipe delivers it.
    private static func framedListing(_ version: String?, _ scope: String) -> String {
        let ours = version.map {
            """
            ,{"id":"\(ClaudeRemoteEnrollmentService.remotePluginReference)","version":"\($0)","scope":"\(scope)","enabled":true,"installPath":"/home/dev/.claude/plugins/cache/localvoxtral/localvoxtral-remote/\($0)","installedAt":"2026-07-27T20:59:23.439Z","lastUpdated":"2026-09-07T13:27:31.000Z"}
            """
        } ?? ""
        return "Welcome to builder\n"
            + ClaudeRemoteEnrollmentService.pluginListFrameBegin + "\n"
            + "[{\"id\":\"frontend-design@claude-plugins-official\",\"version\":\"unknown\",\"scope\":\"project\",\"enabled\":false,\"installPath\":\"/x\",\"installedAt\":\"2026-07-01T15:07:39.195Z\",\"lastUpdated\":\"2026-07-01T15:07:39.195Z\",\"projectPath\":\"/home/dev/work/other\"}"
            + ours + "]\n"
            + ClaudeRemoteEnrollmentService.pluginListFrameEnd + "\nLast login: today\n"
    }

    /// Records the ssh invocations a plugin setup makes, from the
    /// nonisolated runner closure.
    private final class PluginSetupCalls: Sendable {
        private let storage = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
        private let listings = Mutex(0)
        func record(_ invocation: ClaudeRemoteEnrollmentService.Invocation) {
            storage.withLock { $0.append(invocation) }
        }
        /// 1 for the first listing, 2 for the read-back.
        func nextListing() -> Int { listings.withLock { $0 += 1; return $0 } }
        var all: [ClaudeRemoteEnrollmentService.Invocation] { storage.withLock { $0 } }
        var scripts: [String] { all.map { String(decoding: $0.standardInput, as: UTF8.self) } }
    }

    /// Answers the three-call plugin setup: listing, install call, listing.
    private func pluginSetupRunner(
        before: String?,
        after: String?,
        install: ClaudeRemoteEnrollmentService.RunResult = .init(exitCode: 0, message: ""),
        calls: PluginSetupCalls
    ) -> ClaudeRemoteEnrollmentService.Runner {
        let listing = Self.framedListing
        return { invocation in
            calls.record(invocation)
            let stdin = String(decoding: invocation.standardInput, as: UTF8.self)
            if stdin.contains(ClaudeRemoteEnrollmentService.pluginListFrameBegin) {
                let n = calls.nextListing()
                return .init(exitCode: 0, message: listing(n == 1 ? before : after, "user"))
            }
            return install
        }
    }

    /// The scripts one `setupRemotePlugin` run sends, in order: listing,
    /// install call, read-back. `before` is the version the first listing
    /// reports; the read-back reports the shipped one.
    private func pluginSetupScripts(before: String?, token: String?) throws -> [String] {
        let calls = PluginSetupCalls()
        let service = ClaudeRemoteEnrollmentService(
            runner: pluginSetupRunner(
                before: before, after: ClaudeRemoteEnrollmentService.remotePluginVersion, calls: calls
            )
        )
        _ = try service.setupRemotePlugin(sshHostAlias: "builder", token: token, remoteForwardPort: 28_511)
        return calls.scripts
    }

    func testPluginSetupDecodesTheListingAndReportsAnAlreadyCurrentPlugin() throws {
        let calls = PluginSetupCalls()
        let current = ClaudeRemoteEnrollmentService.remotePluginVersion
        let service = ClaudeRemoteEnrollmentService(
            runner: pluginSetupRunner(before: current, after: current, calls: calls)
        )

        XCTAssertEqual(
            try service.setupRemotePlugin(sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511),
            ClaudeRemoteEnrollmentService.PluginSetupOutcome.alreadyCurrent
        )
        XCTAssertEqual(calls.all.count, 3, "listing, install call, listing")
        let scripts = calls.scripts
        XCTAssertTrue(scripts[0].contains("claude plugin list --json"))
        XCTAssertTrue(scripts[1].contains("claude plugin install"))
        XCTAssertFalse(scripts[1].contains("claude plugin update"), "a current plugin is not updated")
        XCTAssertTrue(scripts[2].contains("claude plugin list --json"))
        // Nothing on the host matches text: the decision and the read-back
        // are decoded here from the JSON the CLI prints.
        for script in scripts {
            XCTAssertFalse(script.contains("grep"), "no text matching on the host")
            XCTAssertFalse(script.contains("case \""), "no text matching on the host")
        }
    }

    /// Each row: the version listed before setup, the token setup gets, the
    /// outcome it must report, and what the install call's script must carry.
    /// The read-back always lists the current version.
    func testPluginSetupUpdatesOrInstallsAndReadsTheNewVersionBack() throws {
        let rows: [(name: String, before: String?, token: String?,
                    outcome: ClaudeRemoteEnrollmentService.PluginSetupOutcome, script: [String])] = [
            ("PluginSetupUpdatesAStalePluginAndReadsTheNewVersionBack", "1.4.0", nil, .updated,
             ["claude plugin marketplace update", "claude plugin update"]),
            ("PluginSetupInstallsAnAbsentPluginWhenItHasAToken", nil, "t0k", .installed,
             ["claude plugin marketplace add", "--config 'token=t0k'"]),
        ]
        for row in rows {
            let calls = PluginSetupCalls()
            let service = ClaudeRemoteEnrollmentService(
                runner: pluginSetupRunner(
                    before: row.before,
                    after: ClaudeRemoteEnrollmentService.remotePluginVersion,
                    calls: calls
                )
            )
            XCTAssertEqual(
                try service.setupRemotePlugin(sshHostAlias: "builder", token: row.token, remoteForwardPort: 28_511),
                row.outcome,
                row.name
            )
            let script = calls.scripts[1]
            for expected in row.script {
                XCTAssertTrue(script.contains(expected), "\(row.name): \(expected)")
            }
        }
    }

    func testPluginSetupReadBackNamesTheVersionItFound() throws {
        // The field failure of 2026-09-07: the plugin was current, but the
        // check read the human listing's reference line, which no longer
        // carries the version, and reported a mismatch on every host.
        let calls = PluginSetupCalls()
        let service = ClaudeRemoteEnrollmentService(
            runner: pluginSetupRunner(before: "1.6.0", after: "1.6.0", calls: calls)
        )
        XCTAssertThrowsError(
            try service.setupRemotePlugin(sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511)
        ) { error in
            guard case ClaudeRemoteEnrollmentService.ServiceError.commandFailed(_, _, 43, let message) = error
            else { return XCTFail("expected the read-back diagnosis, got \(error)") }
            XCTAssertEqual(
                message,
                "The plugin reports version 1.6.0 after setup, not "
                    + "\(ClaudeRemoteEnrollmentService.remotePluginVersion)."
            )
        }
    }

    func testPluginListingDecoderPrefersTheUserScopeEntryAndRefusesUnreadableCaptures() throws {
        let reference = ClaudeRemoteEnrollmentService.remotePluginReference
        let twoScopes = ClaudeRemoteEnrollmentService.pluginListFrameBegin + "\n"
            + "[{\"id\":\"\(reference)\",\"version\":\"1.2.0\",\"scope\":\"project\"},"
            + "{\"id\":\"\(reference)\",\"version\":\"1.9.0\",\"scope\":\"user\"}]\n"
            + ClaudeRemoteEnrollmentService.pluginListFrameEnd
        XCTAssertEqual(
            try ClaudeRemoteEnrollmentService.installedRemotePluginVersion(
                inFramedOutput: twoScopes, reference: reference
            ),
            "1.9.0"
        )
        XCTAssertNil(
            try ClaudeRemoteEnrollmentService.installedRemotePluginVersion(
                inFramedOutput: Self.framedListing(nil, "user"), reference: reference
            ),
            "an unrelated plugin is not ours"
        )
        // A version that merely contains ours is not ours.
        XCTAssertEqual(
            try ClaudeRemoteEnrollmentService.installedRemotePluginVersion(
                inFramedOutput: Self.framedListing("11.8.0", "user"), reference: reference
            ),
            "11.8.0"
        )
        XCTAssertThrowsError(
            try ClaudeRemoteEnrollmentService.installedRemotePluginVersion(
                inFramedOutput: "Welcome\n[]\n", reference: reference
            ),
            "no frame is an unreadable host, not an absent plugin"
        )
        XCTAssertThrowsError(
            try ClaudeRemoteEnrollmentService.installedRemotePluginVersion(
                inFramedOutput: ClaudeRemoteEnrollmentService.pluginListFrameBegin + "\nnot json\n"
                    + ClaudeRemoteEnrollmentService.pluginListFrameEnd,
                reference: reference
            ),
            "an undecodable frame is an unreadable host"
        )
    }

    func testPluginSetupRefusesToInstallWithoutAToken() throws {
        // The update path deliberately carries no credential. Installing
        // tokenless would look exactly like a healthy enrollment failing open,
        // so an absent plugin is reported for the remedy (rotate), not
        // silently installed broken.
        let calls = PluginSetupCalls()
        let service = ClaudeRemoteEnrollmentService(
            runner: pluginSetupRunner(before: nil, after: nil, calls: calls)
        )
        XCTAssertThrowsError(
            try service.setupRemotePlugin(sshHostAlias: "builder", token: nil, remoteForwardPort: 28_511)
        ) { error in
            guard case ClaudeRemoteEnrollmentService.ServiceError.commandFailed(_, _, 44, let message) = error
            else { return XCTFail("expected exit 44 with the rotation remedy, got \(error)") }
            XCTAssertTrue(message.contains("Rotate this host's token"))
        }
        XCTAssertEqual(calls.all.count, 1, "nothing is installed without a token")
    }

    func testPluginSetupDistinguishesMissingCLIFromAFailedInstall() throws {
        func failure(listingExit: Int32, installExit: Int32) throws -> ClaudeRemoteEnrollmentService.ServiceError {
            let calls = PluginSetupCalls()
            let service = ClaudeRemoteEnrollmentService(runner: { invocation in
                calls.record(invocation)
                let stdin = String(decoding: invocation.standardInput, as: UTF8.self)
                if stdin.contains(ClaudeRemoteEnrollmentService.pluginListFrameBegin) {
                    _ = calls.nextListing()
                    return listingExit == 0
                        ? .init(exitCode: 0, message: Self.framedListing("1.6.0", "user"))
                        : .init(exitCode: listingExit, message: "untrusted host output")
                }
                return .init(exitCode: installExit, message: "untrusted host output")
            })
            do {
                _ = try service.setupRemotePlugin(sshHostAlias: "builder", token: "test-token", remoteForwardPort: 28_511)
                XCTFail("must fail")
                return .executionNotConfigured
            } catch let error as ClaudeRemoteEnrollmentService.ServiceError {
                return error
            }
        }

        guard case .commandFailed(_, _, 127, let missingCLI) = try failure(listingExit: 127, installExit: 0) else {
            return XCTFail("expected the missing CLI diagnosis")
        }
        XCTAssertEqual(
            missingCLI,
            "Claude CLI was not found on the remote host. "
                + "Install Claude Code there, or put it on the non-interactive SSH PATH."
        )
        guard case .commandFailed(_, _, 1, let installFailure) = try failure(listingExit: 0, installExit: 1) else {
            return XCTFail("expected the install failure diagnosis")
        }
        XCTAssertEqual(installFailure, "The remote plugin setup command failed.")
    }

    func testAHostWithoutClaudeCodeIsAnOutcomeOnlyWhenOurOwnResolverSaysSo() throws {
        // A bare 127 is any "command not found" (the test above still throws
        // on it). The outcome needs our PATH resolver's own sentence as well.
        let scripts = Mutex(0)
        let service = ClaudeRemoteEnrollmentService(runner: { _ in
            scripts.withLock { $0 += 1 }
            return .init(
                exitCode: 127,
                message: "banner\nlocalvoxtral: 'claude' was not found on this host's non-interactive PATH."
            )
        })
        XCTAssertEqual(
            try service.setupRemotePlugin(sshHostAlias: "builder", token: "test-token", remoteForwardPort: 28_511),
            .claudeNotFound
        )
        XCTAssertEqual(scripts.withLock { $0 }, 1, "nothing is attempted after the listing")
    }

    func testHerdrSetupReportsAbsentAndRefusesAnExistingAgentsTable() throws {
        let assertInvocation: @Sendable (ClaudeRemoteEnrollmentService.Invocation) -> Void = {
            invocation in
            XCTAssertEqual(
                invocation.argv,
                [
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                    "builder", "/bin/sh", "-s",
                ]
            )
            XCTAssertEqual(invocation.timeout, ClaudeRemoteEnrollmentService.defaultRemoteSetupTimeout)
            XCTAssertTrue(invocation.environment.isEmpty)
            let script = String(decoding: invocation.standardInput, as: UTF8.self)
            XCTAssertTrue(script.contains("command -v herdr"))
            XCTAssertTrue(script.contains(ClaudeRemoteEnrollmentService.herdrPanelConfigSnippet))
            XCTAssertTrue(script.contains("herdr server reload-config"))
            XCTAssertTrue(script.contains("LVX_HERDR_CONFIGURED"))
        }
        let absent = ClaudeRemoteEnrollmentService(runner: { invocation in
            assertInvocation(invocation)
            return .init(exitCode: 0, message: "LVX_HERDR_ABSENT")
        })
        XCTAssertEqual(try absent.setupRemoteHerdr(sshHostAlias: "builder"), .notFound)

        let customized = ClaudeRemoteEnrollmentService(runner: { invocation in
            assertInvocation(invocation)
            return .init(exitCode: 42, message: "LVX_HERDR_CUSTOMIZED")
        })
        XCTAssertEqual(try customized.setupRemoteHerdr(sshHostAlias: "builder"), .customized)
    }

    func testHerdrSetupRequiresTheConfiguredOutcomeFrame() throws {
        let service = ClaudeRemoteEnrollmentService(runner: { invocation in
            XCTAssertEqual(
                invocation.argv,
                [
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                    "builder", "/bin/sh", "-s",
                ]
            )
            XCTAssertTrue(
                String(decoding: invocation.standardInput, as: UTF8.self)
                    .contains("LVX_HERDR_CONFIGURED")
            )
            return .init(exitCode: 0, message: "")
        })

        XCTAssertThrowsError(try service.setupRemoteHerdr(sshHostAlias: "builder")) { error in
            guard case ClaudeRemoteEnrollmentService.ServiceError
                .runnerFailed(_, let command, let message) = error else {
                return XCTFail("expected an unreported herdr outcome, got \(error)")
            }
            XCTAssertEqual(command, "configure remote herdr")
            XCTAssertEqual(
                message,
                "The host did not report a herdr setup outcome. "
                    + "Check its herdr config, then run setup again."
            )
        }
    }

    func testRemovingTheLocalSSHBlockUsesTheSameTrustedWriter() throws {
        let applied = ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
            to: "Host other\n    User me\n",
            snippet: try plan().sshConfigSnippet,
            hostID: host.id
        )
        let fileSystem = MemorySSHConfigFileSystem(
            state: ClaudeRemoteRemoteConfigStateFixture.state(configText: applied)
        )
        let service = ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem)

        try service.removeSSHConfig(hostID: host.id)

        let written = String(decoding: try XCTUnwrap(fileSystem.snapshot.writes.last?.data), as: UTF8.self)
        XCTAssertFalse(written.contains("Host builder"))
        XCTAssertTrue(written.contains("Host other"))
    }

}
