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
        // The two plugins are structurally different — HTTP hooks and a token
        // versus a command shim and peer credentials. Installing the local one
        // on a remote host would fail open forever and look like a tunnel bug.
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
        // survive a login shell that skips rc files.
        XCTAssertTrue(
            joined.contains("EXPECTED while another live session"),
            "the forward-failure line needs its interpretation next to it"
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
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes",
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
                    remoteCommands: ClaudeRemoteEnrollmentService.remoteCommands(token: token),
                    verifyCommands: [], uninstallCommands: [], notes: []
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
                    remoteCommands: ClaudeRemoteEnrollmentService.remoteCommands(token: token),
                    verifyCommands: [], uninstallCommands: [], notes: []
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
                    uninstallCommands: [], notes: []
                ),
                sshHostAlias: "a b",
                token: token
            )
        )
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
