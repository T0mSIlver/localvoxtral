import ClaudeContextWire
import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

/// A stand-in for an ssh host, reached through the PRODUCTION runner
/// (`ClaudeRemoteEnrollmentService.processRunner`) with a fake `ssh` that
/// ignores its arguments and runs `/bin/sh -s` against a temporary `$HOME`. So
/// these tests execute the real scripts AND the runner's real stdin and output
/// limits. (A first version ran the scripts directly and hid that the runner's
/// standard budget refuses this flow outright — Codex review, 2026-09-20.)
private final class FakeHost: @unchecked Sendable {
    let home: URL
    private let lock = NSLock()
    private var _invocations: [ClaudeRemoteEnrollmentService.Invocation] = []
    /// Run before the Nth script (1-based), to play an editor on the host.
    var beforeScript: [Int: @Sendable () -> Void] = [:]
    /// Scripts that never reach the host: the connection died first.
    var droppedScripts: Set<Int> = []

    init(vibeInstalled: Bool = true) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-host-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if vibeInstalled {
            let vibe = bin.appendingPathComponent("vibe")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: vibe)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vibe.path)
        }
        let ssh = "#!/bin/sh\nHOME='\(home.path)' PATH=/usr/bin:/bin exec /bin/sh -s\n"
        try Data(ssh.utf8).write(to: fakeSSH)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
    }

    private var fakeSSH: URL { home.appendingPathComponent("fake-ssh") }

    deinit { try? FileManager.default.removeItem(at: home) }

    var invocations: [ClaudeRemoteEnrollmentService.Invocation] { lock.withLock { _invocations } }

    var runner: ClaudeRemoteEnrollmentService.Runner {
        let production = ClaudeRemoteEnrollmentService.processRunner(sshExecutableURL: fakeSSH)
        return { [self] invocation in
            let index = lock.withLock { () -> Int in
                _invocations.append(invocation)
                return _invocations.count
            }
            beforeScript[index]?()
            if droppedScripts.contains(index) { return .init(exitCode: 255, message: "") }
            return try production(invocation)
        }
    }

    func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }

    func text(_ relative: String) -> String? {
        try? String(contentsOfFile: path(relative), encoding: .utf8)
    }

    func mode(_ relative: String) -> UInt16? {
        (try? FileManager.default.attributesOfItem(atPath: path(relative))[.posixPermissions] as? NSNumber)?
            .uint16Value
    }

    func write(_ text: String, to relative: String, mode: UInt16 = 0o644) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

final class VibeRemoteHooksSetupTests: XCTestCase {
    private static let token = "dGVzdC10b2tlbi0xMjM0NTY3ODkwYWJjZGVmZ2hpamtsbW4"
    private static let userHooks = """
    [[hooks]]
    name = "deny-rm-rf"
    type = "pre_tool"
    match = "bash"
    command = "python guard.py"

    """

    private func shippedFiles() throws -> VibeRemoteHooksFiles {
        try XCTUnwrap(VibeRemoteHooksFiles.bundled())
    }

    private func service(_ host: FakeHost) -> ClaudeRemoteEnrollmentService {
        ClaudeRemoteEnrollmentService(runner: host.runner)
    }

    private func setUp(_ host: FakeHost, files: VibeRemoteHooksFiles? = nil) throws
        -> ClaudeRemoteEnrollmentService.VibeHooksOutcome {
        try service(host).setUpRemoteVibeHooks(
            sshHostAlias: "builder", token: Self.token, remoteForwardPort: 18_473,
            files: try files ?? shippedFiles()
        )
    }

    private func failure(_ body: () throws -> Void) -> (exitCode: Int32, message: String)? {
        do {
            try body()
            return nil
        } catch ClaudeRemoteEnrollmentService.ServiceError.commandFailed(_, _, let exitCode, let message) {
            return (exitCode, message)
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    // MARK: - Install

    func testSetupWritesThePrivateFilesAndAppendsTheBlock() throws {
        let host = try FakeHost()
        try host.write(Self.userHooks, to: ".vibe/hooks.toml")
        let files = try shippedFiles()

        XCTAssertEqual(try setUp(host), .installed)

        XCTAssertEqual(host.text(".vibe/localvoxtral/remote/post.sh"), files.postScript)
        XCTAssertEqual(host.text(".vibe/localvoxtral/remote/compact.py"), files.compactScript)
        XCTAssertEqual(host.text(".vibe/localvoxtral/remote/token"), Self.token + "\n")
        XCTAssertEqual(host.text(".vibe/localvoxtral/remote/port"), "18473\n")
        XCTAssertEqual(host.mode(".vibe/localvoxtral/remote/token"), 0o600)
        XCTAssertEqual(host.mode(".vibe/localvoxtral/remote"), 0o700)
        XCTAssertEqual(host.text(".vibe/hooks.toml"), Self.userHooks + "\n" + files.hooksBlock)
        XCTAssertEqual(host.mode(".vibe/hooks.toml"), 0o644, "an existing hooks.toml keeps its mode")
    }

    func testTheTokenIsInNoArgvAndEveryRunIsABatchModeShOverStdin() throws {
        let host = try FakeHost()
        _ = try setUp(host)
        XCTAssertEqual(host.invocations.count, 4, "probe, stage, read back, activate")
        for invocation in host.invocations {
            XCTAssertEqual(invocation.argv, [
                "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--", "builder", "/bin/sh", "-s",
            ])
            XCTAssertFalse(invocation.argv.joined().contains(Self.token))
        }
        let carriers = host.invocations.filter {
            String(decoding: $0.standardInput, as: UTF8.self).contains(Self.token)
        }
        XCTAssertEqual(carriers.count, 1, "only the activation carries it, on stdin")
        XCTAssertEqual(carriers.first, host.invocations.last, "and it is the last thing written")
    }

    func testTheRunNeedsTheLargerRunnerBudgetAndAsksForItByName() throws {
        let host = try FakeHost()
        _ = try setUp(host)
        let stage = host.invocations[1]
        XCTAssertGreaterThan(
            stage.standardInput.count, ClaudeRemoteEnrollmentService.Invocation.Budget.standard.standardInputBytes,
            "the scripts alone exceed the preload budget every other enrollment script fits in"
        )
        XCTAssertEqual(stage.budget, ClaudeRemoteEnrollmentService.vibeRunnerBudget)

        // And the standard budget really does refuse it, in the real runner.
        var standard = stage
        standard.budget = .standard
        XCTAssertThrowsError(try host.runner(standard))
    }

    func testALargeHooksTomlSurvivesTheRoundTripThroughTheRunner() throws {
        // Far past the 2,000 characters a standard run hands back, and past
        // the pipe buffer on the way out.
        let host = try FakeHost()
        var large = Self.userHooks
        for index in 0..<900 {
            large += "\n[[hooks]]\nname = \"user-\(index)\"\ntype = \"post_agent\"\ncommand = \"true # \(String(repeating: "x", count: 60))\"\n"
        }
        XCTAssertGreaterThan(large.utf8.count, 100 * 1024)
        try host.write(large, to: ".vibe/hooks.toml")
        XCTAssertEqual(try setUp(host), .installed)
        XCTAssertEqual(host.text(".vibe/hooks.toml"), large + "\n" + (try shippedFiles().hooksBlock))
    }

    func testAHooksTomlPastTheCapIsRefusedByTheHostNotTruncatedByTheMac() throws {
        let host = try FakeHost()
        try host.write(String(repeating: "# filler line\n", count: 20_000), to: ".vibe/hooks.toml")
        let failure = try XCTUnwrap(failure { _ = try self.setUp(host) })
        XCTAssertEqual(failure.exitCode, 46)
        XCTAssertTrue(failure.message.contains("too large"))
        XCTAssertNil(host.text(".vibe/localvoxtral/remote/post.sh"))
    }

    func testAHostWithoutHooksTomlGetsOneAt0600() throws {
        let host = try FakeHost()
        _ = try setUp(host)
        XCTAssertEqual(host.text(".vibe/hooks.toml"), try shippedFiles().hooksBlock)
        XCTAssertEqual(host.mode(".vibe/hooks.toml"), 0o600)
    }

    func testASecondRunIsAnUpdateAndLeavesTheFileByteIdentical() throws {
        let host = try FakeHost()
        try host.write(Self.userHooks, to: ".vibe/hooks.toml")
        _ = try setUp(host)
        let before = host.text(".vibe/hooks.toml")
        XCTAssertEqual(try setUp(host), .updated)
        XCTAssertEqual(host.text(".vibe/hooks.toml"), before)
    }

    func testTheInstalledShimDialsWithTheTokenAndPortThatWereWritten() throws {
        // No directory override: the shim must find compact.py, token and port
        // where setup put them, from $HOME alone.
        let host = try FakeHost()
        _ = try setUp(host)
        let stub = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          case "$1" in --header) case "$2" in @*) cp "${2#@}" "$HOME/captured-header" ;; esac ;; esac
          last="$1"; shift
        done
        echo "$last" >"$HOME/captured-url"
        printf 200
        """
        try host.write(stub, to: "stub/curl", mode: 0o755)
        try host.write(
            #"{"session_id":"s1","transcript_path":null,"cwd":"/srv","parent_session_id":null,"hook_event_name":"post_agent"}"#,
            to: "payload.json"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [host.path(".vibe/localvoxtral/remote/post.sh")]
        process.environment = ["HOME": host.home.path, "PATH": "\(host.path("stub")):/usr/bin:/bin"]
        process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: host.path("payload.json")))
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(host.text("captured-url"), "http://127.0.0.1:18473/v1/hook/Stop\n")
        XCTAssertTrue(try XCTUnwrap(host.text("captured-header")).contains("Authorization: Bearer \(Self.token)\n"))
    }

    // MARK: - Refusals

    func testNoVibeOnTheHostSaysSoAndWritesNothing() throws {
        let host = try FakeHost(vibeInstalled: false)
        let failure = try XCTUnwrap(failure { _ = try self.setUp(host) })
        XCTAssertEqual(failure.exitCode, 127)
        XCTAssertTrue(failure.message.hasPrefix("Vibe was not found on the remote host."))
        XCTAssertNil(host.text(".vibe/localvoxtral/remote/token"))
        XCTAssertEqual(host.invocations.count, 1)
    }

    func testAConflictingHooksTomlIsRefusedBeforeAnythingIsWritten() throws {
        let host = try FakeHost()
        let conflicting = "[[hooks]]\nname = \"localvoxtral-remote-turn\"\ntype = \"post_agent\"\n"
        try host.write(conflicting, to: ".vibe/hooks.toml")
        let failure = try XCTUnwrap(failure { _ = try self.setUp(host) })
        XCTAssertEqual(failure.exitCode, 48)
        XCTAssertEqual(host.text(".vibe/hooks.toml"), conflicting)
        XCTAssertNil(host.text(".vibe/localvoxtral/remote/token"))
    }

    func testAnEditOnTheHostBetweenProbeAndWriteIsNotOverwritten() throws {
        let host = try FakeHost()
        try host.write(Self.userHooks, to: ".vibe/hooks.toml")
        let edited = Self.userHooks + "# saved just now\n"
        host.beforeScript[2] = { try? host.write(edited, to: ".vibe/hooks.toml") }

        let failure = try XCTUnwrap(failure { _ = try self.setUp(host) })
        XCTAssertEqual(failure.exitCode, 45)
        XCTAssertEqual(host.text(".vibe/hooks.toml"), edited)
        XCTAssertNil(host.text(".vibe/localvoxtral/remote/post.sh"), "the guard runs before any write")
        XCTAssertNil(host.text(".vibe/localvoxtral/remote/token"))
    }

    func testASymlinkedVibeDirectoryIsRefused() throws {
        let host = try FakeHost()
        let real = host.home.appendingPathComponent("dotfiles-vibe")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: host.home.appendingPathComponent(".vibe"), withDestinationURL: real
        )
        let failure = try XCTUnwrap(failure { _ = try self.setUp(host) })
        XCTAssertEqual(failure.exitCode, 46)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.path), [])
    }

    func testAHostThatReportsTheWrongVersionGetsAFixedSentence() throws {
        let host = try FakeHost()
        // After staging, the host's post.sh claims another version.
        host.beforeScript[3] = {
            let path = host.path(".vibe/localvoxtral/remote/post.sh")
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? text.replacingOccurrences(of: "Hooks-Version: 1.0.0", with: "Hooks-Version: 6.6.6")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        let failure = try XCTUnwrap(failure { _ = try self.setUp(host) })
        XCTAssertEqual(failure.exitCode, 43)
        XCTAssertFalse(failure.message.contains("6.6.6"), "nothing the host said goes into the sentence")
        XCTAssertNil(host.text(".vibe/localvoxtral/remote/token"), "a run that fails verification activates nothing")
    }

    func testNothingTheHostPrintsReachesAnError() throws {
        // A host that answers the probe with garbage, token echoed back.
        let noisy: ClaudeRemoteEnrollmentService.Runner = { _ in
            .init(exitCode: 3, message: "SECRET-BANNER \(Self.token)")
        }
        let service = ClaudeRemoteEnrollmentService(runner: noisy)
        let failure = try XCTUnwrap(failure {
            _ = try service.setUpRemoteVibeHooks(
                sshHostAlias: "builder", token: Self.token, remoteForwardPort: 18_473,
                files: try self.shippedFiles()
            )
        })
        XCTAssertFalse(failure.message.contains("SECRET"))
        XCTAssertFalse(failure.message.contains(Self.token))
    }

    func testAnInvalidAliasNeverReachesSsh() throws {
        let host = try FakeHost()
        XCTAssertThrowsError(try service(host).setUpRemoteVibeHooks(
            sshHostAlias: "-oProxyCommand=evil", token: Self.token, remoteForwardPort: 18_473,
            files: try shippedFiles()
        ))
        XCTAssertEqual(host.invocations.count, 0)
    }

    // MARK: - Remove

    func testRemoveRestoresTheUsersHooksTomlAndDeletesTheToken() throws {
        let host = try FakeHost()
        try host.write(Self.userHooks, to: ".vibe/hooks.toml")
        _ = try setUp(host)

        XCTAssertEqual(try service(host).removeRemoteVibeHooks(sshHostAlias: "builder"), .removed)
        XCTAssertEqual(host.text(".vibe/hooks.toml"), Self.userHooks)
        XCTAssertEqual(host.mode(".vibe/hooks.toml"), 0o644)
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.path(".vibe/localvoxtral/remote")))
    }

    func testRemoveDeletesAHooksTomlThatHeldOnlyOurBlockAndKeepsTheLocalBlock() throws {
        let host = try FakeHost()
        _ = try setUp(host)
        _ = try service(host).removeRemoteVibeHooks(sshHostAlias: "builder")
        XCTAssertNil(host.text(".vibe/hooks.toml"))

        // One machine can be a Mac with the local hooks AND an enrolled host.
        let local = try XCTUnwrap(
            ClaudePluginAssets.vibeFileURL(named: ClaudePluginAssets.vibeHooksBlockFileName)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        )
        try host.write(local, to: ".vibe/hooks.toml")
        _ = try setUp(host)
        _ = try service(host).removeRemoteVibeHooks(sshHostAlias: "builder")
        XCTAssertEqual(host.text(".vibe/hooks.toml"), local)
    }

    // MARK: - Pure parts

    func testTheShippedFilesCarryOneVersionAndTheRemoteBlock() throws {
        let files = try shippedFiles()
        XCTAssertEqual(files.version, "1.0.0")
        XCTAssertNotNil(VibeHooksBlockEditor.remote.snippet(fromBundled: files.hooksBlock))
        let names = files.hooksBlock.split(separator: "\n").filter { $0.hasPrefix("name = ") }
            .map { String($0.dropFirst("name = \"".count).dropLast()) }
        XCTAssertEqual(Set(names), VibeHooksBlockEditor.remote.hookNames)
    }

    func testTheProbeParserReadsOnlyFramedKnownKeys() {
        let output = """
        Welcome to builder! version=9.9.9
        LVX_VIBE_PROBE_BEGIN
        vibe=found
        version=1.0.0
        version-ish=2.0.0
        checksum=123:45
        hooks=\(Data("a = 1\n".utf8).base64EncodedString())

        LVX_VIBE_PROBE_END
        hooks=ignored
        """
        let probe = ClaudeRemoteEnrollmentService.vibeProbe(inFramedOutput: output)
        XCTAssertEqual(probe?.vibeFound, true)
        XCTAssertEqual(probe?.installedVersion, "1.0.0")
        XCTAssertEqual(probe?.hooksChecksum, "123:45")
        XCTAssertEqual(probe?.hooksText, "a = 1\n")
        XCTAssertNil(ClaudeRemoteEnrollmentService.vibeProbe(inFramedOutput: "no frame"))
        XCTAssertNil(ClaudeRemoteEnrollmentService.vibeProbe(
            inFramedOutput: "LVX_VIBE_PROBE_BEGIN\nchecksum=1; rm -rf /\nLVX_VIBE_PROBE_END"
        ), "a checksum is spliced into a script, so its alphabet is enforced")
    }

    func testAHeredocDelimiterNeverEqualsALineOfTheContent() {
        let content = "a\nLVX_EOF_HOOKS\nLVX_EOF_HOOKS_X\nb"
        let delimiter = ClaudeRemoteEnrollmentService.heredocDelimiter(for: content, seed: "HOOKS")
        XCTAssertFalse(content.split(separator: "\n").map(String.init).contains(delimiter))
    }
}

// MARK: - Extra credentials

/// The host store, in memory, shared between registries to play a relaunch.
private final class InMemoryHostStoreIO: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<Data?>(nil)

    func read(from url: URL) throws -> Data? { contents.withLock { $0 } }
    func write(_ data: Data, to url: URL) throws { contents.withLock { $0 = data } }
}

final class ClaudeRemoteExtraCredentialTests: XCTestCase {
    private func makeRegistry(io: InMemoryHostStoreIO = InMemoryHostStoreIO()) throws -> ClaudeRemoteHostRegistry {
        try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-extra-credential-test/hosts.json"), io: io
        )
    }

    func testAnExtraCredentialAuthenticatesAsTheSameHostBesideTheFirst() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "builder", sshHostAlias: "builder")
        let vibeToken = try registry.issueCredential(hostID: enrollment.host.id, purpose: .vibe)

        XCTAssertNotEqual(vibeToken, enrollment.token)
        XCTAssertEqual(registry.authenticate(token: vibeToken)?.id, enrollment.host.id)
        XCTAssertEqual(registry.authenticate(token: enrollment.token)?.id, enrollment.host.id)
        XCTAssertEqual(registry.host(id: enrollment.host.id)?.extraCredentialPurposes, [.vibe])
    }

    func testAPreparedCredentialIsWorthlessUntilCommitted() throws {
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "builder").host
        let old = try registry.issueCredential(hostID: host.id, purpose: .vibe)

        let pending = try registry.prepareCredential(hostID: host.id, purpose: .vibe)
        XCTAssertNil(registry.authenticate(token: pending.token))
        XCTAssertNotNil(registry.authenticate(token: old), "a failed ssh run must not cost the working token")

        try registry.commitCredential(pending, hostID: host.id)
        try registry.retireOtherCredentials(hostID: host.id, keeping: pending)
        XCTAssertNotNil(registry.authenticate(token: pending.token))
        XCTAssertNil(registry.authenticate(token: old), "one credential per purpose once the run is over")
    }

    func testRotateAndRevokeKillTheExtraCredentialToo() throws {
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "builder").host
        let first = try registry.issueCredential(hostID: host.id, purpose: .vibe)
        _ = try registry.rotateToken(hostID: host.id)
        XCTAssertNil(registry.authenticate(token: first))
        XCTAssertEqual(registry.host(id: host.id)?.extraCredentialPurposes, [])

        let second = try registry.issueCredential(hostID: host.id, purpose: .vibe)
        try registry.revoke(hostID: host.id)
        XCTAssertNil(registry.authenticate(token: second))
        XCTAssertThrowsError(try registry.issueCredential(hostID: host.id, purpose: .vibe)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHostRegistry.StoreError, .hostRevoked(host.id))
        }
    }

    func testRemoveCredentialLeavesTheHostsOwnTokenWorking() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "builder")
        let vibeToken = try registry.issueCredential(hostID: enrollment.host.id, purpose: .vibe)
        try registry.removeCredential(hostID: enrollment.host.id, purpose: .vibe)
        XCTAssertNil(registry.authenticate(token: vibeToken))
        XCTAssertNotNil(registry.authenticate(token: enrollment.token))
    }

    func testTheCredentialSurvivesARelaunchAndAnOlderFileStillLoads() throws {
        let io = InMemoryHostStoreIO()
        let first = try makeRegistry(io: io)
        let enrollment = try first.enroll(label: "builder")
        let vibeToken = try first.issueCredential(hostID: enrollment.host.id, purpose: .vibe)

        let relaunched = try makeRegistry(io: io)
        XCTAssertEqual(relaunched.authenticate(token: vibeToken)?.id, enrollment.host.id)

        // A file written before this key existed.
        try relaunched.removeCredential(hostID: enrollment.host.id, purpose: .vibe)
        let older = try makeRegistry(io: io)
        XCTAssertEqual(older.host(id: enrollment.host.id)?.extraCredentialPurposes, [])
        XCTAssertNotNil(older.authenticate(token: enrollment.token))
    }

    func testARotationDuringSetupCannotBeUndoneByTheCommit() throws {
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "builder").host
        let pending = try registry.prepareCredential(hostID: host.id, purpose: .vibe)
        _ = try registry.rotateToken(hostID: host.id) // the user suspects a leak, mid-run
        XCTAssertThrowsError(try registry.commitCredential(pending, hostID: host.id)) { error in
            XCTAssertEqual(error as? ClaudeRemoteHostRegistry.StoreError, .hostCredentialChanged(host.id))
        }
        XCTAssertNil(registry.authenticate(token: pending.token))
    }

    func testOldAndNewOverlapUntilTheOldIsRetiredAndNeverMoreThanTwo() throws {
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "builder").host
        let first = try registry.issueCredential(hostID: host.id, purpose: .vibe)

        let second = try registry.prepareCredential(hostID: host.id, purpose: .vibe)
        try registry.commitCredential(second, hostID: host.id)
        XCTAssertNotNil(registry.authenticate(token: first), "the host may still hold the old token file")
        XCTAssertNotNil(registry.authenticate(token: second.token))

        let third = try registry.prepareCredential(hostID: host.id, purpose: .vibe)
        try registry.commitCredential(third, hostID: host.id)
        XCTAssertNil(registry.authenticate(token: first), "one previous credential is kept, not a history")
        XCTAssertNotNil(registry.authenticate(token: second.token))

        try registry.retireOtherCredentials(hostID: host.id, keeping: third)
        XCTAssertNil(registry.authenticate(token: second.token))
        XCTAssertNotNil(registry.authenticate(token: third.token))
    }

    func testTheVibeHooksVersionIsHighestWinsAndNeverTouchesThePluginReport() throws {
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "builder").host
        registry.noteVibeHooksVersion(hostID: host.id, "1.2.0")
        registry.noteVibeHooksVersion(hostID: host.id, "1.0.0")
        registry.noteVibeHooksVersion(hostID: host.id, "not-a-version")
        XCTAssertEqual(registry.host(id: host.id)?.reportedVibeHooksVersion, "1.2.0")
        XCTAssertNil(registry.host(id: host.id)?.reportedPluginVersion)
    }
}

// MARK: - The row

final class VibeHostHooksStateTests: XCTestCase {
    private func host(
        alias: String? = "builder", revoked: Bool = false,
        purposes: Set<ClaudeRemoteCredentialPurpose> = [], reported: String? = nil
    ) -> ClaudeRemoteHost {
        ClaudeRemoteHost(
            id: "h1", label: "builder", sshHostAlias: alias, createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: nil, revokedAt: revoked ? Date(timeIntervalSince1970: 2) : nil,
            extraCredentialPurposes: purposes, reportedVibeHooksVersion: reported
        )
    }

    private typealias State = ClaudeIntegrationSettingsModel.VibeHostHooksState

    func testTheRowFollowsTheCredentialAndTheReportedVersion() {
        XCTAssertEqual(State.derive(host: host(), bundledVersion: "1.0.0"), .notSetUp)
        XCTAssertEqual(State.derive(host: host(purposes: [.vibe]), bundledVersion: "1.0.0"), .setUp)
        XCTAssertEqual(
            State.derive(host: host(purposes: [.vibe], reported: "1.0.0"), bundledVersion: "1.1.0"),
            .updateAvailable
        )
        XCTAssertEqual(
            State.derive(host: host(purposes: [.vibe], reported: "1.1.0"), bundledVersion: "1.1.0"), .setUp
        )
    }

    func testNoRowWithoutAnAliasOrForARevokedHost() {
        XCTAssertNil(State.derive(host: host(alias: nil), bundledVersion: "1.0.0"))
        XCTAssertNil(State.derive(host: host(alias: "-oProxyCommand=x"), bundledVersion: "1.0.0"))
        XCTAssertNil(State.derive(host: host(revoked: true, purposes: [.vibe]), bundledVersion: "1.0.0"))
    }

    func testButtonsAreNamedForWhatTheyDoAndHiddenWhenTheyWouldDoNothing() {
        XCTAssertEqual(State.notSetUp.setupButtonTitle, "Set up…")
        XCTAssertEqual(State.updateAvailable.setupButtonTitle, "Update…")
        XCTAssertNil(State.setUp.setupButtonTitle)
        XCTAssertFalse(State.notSetUp.offersRemove)
        XCTAssertTrue(State.setUp.offersRemove)
    }
}

// MARK: - The flow, through the model

private struct NoPluginService: ClaudePluginInstalling {
    func installPlugin() throws {}
    func updatePlugin() throws {}
    func updateInstalledPlugin() throws {}
    func uninstallPlugin() throws {}
}

@MainActor
final class VibeHostFlowTests: XCTestCase {
    private func makeModel(registry: ClaudeRemoteHostRegistry, host: FakeHost) throws
        -> ClaudeIntegrationSettingsModel {
        let files = try XCTUnwrap(VibeRemoteHooksFiles.bundled())
        return ClaudeIntegrationSettingsModel(
            registry: registry,
            listener: nil,
            pluginService: { NoPluginService() },
            enrollmentService: ClaudeRemoteEnrollmentService(runner: host.runner),
            performAsync: { body in
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            },
            remoteForwardPort: 18_473,
            vibeRemoteFiles: { files }
        )
    }

    private func enrolled() throws -> (ClaudeRemoteHostRegistry, String) {
        let registry = try ClaudeRemoteHostRegistry(
            fileURL: URL(fileURLWithPath: "/tmp/lvx-vibe-flow-test/hosts.json"), io: InMemoryHostStoreIO()
        )
        return (registry, try registry.enroll(label: "builder", sshHostAlias: "builder").host.id)
    }

    private func hostToken(_ host: FakeHost) -> String? {
        host.text(".vibe/localvoxtral/remote/token")?.trimmingCharacters(in: .newlines)
    }

    func testSetUpEndsWithOneCredentialTheHostHolds() async throws {
        let (registry, hostID) = try enrolled()
        let host = try FakeHost()
        let model = try makeModel(registry: registry, host: host)

        model.requestVibeHooksSetup(hostID: hostID)
        XCTAssertEqual(model.vibeHostSetupRequest?.sshHostAlias, "builder")
        XCTAssertNil(hostToken(host), "nothing is written before the sheet is confirmed")
        await model.confirmVibeHooksSetup()

        XCTAssertNil(model.alert)
        XCTAssertEqual(registry.authenticate(token: try XCTUnwrap(hostToken(host)))?.id, hostID)
        XCTAssertEqual(model.hosts.first?.vibeHooks, .setUp)
    }

    func testAnUpdateWhoseLastStepDiesLeavesTheHostAuthenticated() async throws {
        let (registry, hostID) = try enrolled()
        let host = try FakeHost()
        let model = try makeModel(registry: registry, host: host)
        model.requestVibeHooksSetup(hostID: hostID)
        await model.confirmVibeHooksSetup()
        let working = try XCTUnwrap(hostToken(host))

        // The update's activation script (the 4th of that run, 8th overall)
        // never reaches the host.
        host.droppedScripts = [8]
        model.requestVibeHooksSetup(hostID: hostID)
        await model.confirmVibeHooksSetup()

        XCTAssertNotNil(model.alert)
        XCTAssertEqual(hostToken(host), working, "the token file was not replaced")
        XCTAssertEqual(registry.authenticate(token: working)?.id, hostID, "and it still authenticates")
    }

    func testRotatingTheHostDuringSetupActivatesNothing() async throws {
        let (registry, hostID) = try enrolled()
        let host = try FakeHost()
        host.beforeScript[2] = { _ = try? registry.rotateToken(hostID: hostID) }
        let model = try makeModel(registry: registry, host: host)
        model.requestVibeHooksSetup(hostID: hostID)
        await model.confirmVibeHooksSetup()

        XCTAssertNotNil(model.alert)
        XCTAssertNil(hostToken(host), "the token is the last thing written, and the commit before it refused")
        XCTAssertEqual(registry.host(id: hostID)?.extraCredentialPurposes, [])
    }

    func testRemoveWithdrawsTheCredentialEvenWhenTheHostCannotBeReached() async throws {
        let (registry, hostID) = try enrolled()
        let host = try FakeHost()
        let model = try makeModel(registry: registry, host: host)
        model.requestVibeHooksSetup(hostID: hostID)
        await model.confirmVibeHooksSetup()
        let token = try XCTUnwrap(hostToken(host))

        host.droppedScripts = [5, 6] // every script of the removal
        await model.removeVibeHooks(hostID: hostID)

        XCTAssertNil(registry.authenticate(token: token), "a host that is down cannot keep its authorization")
        XCTAssertEqual(model.alert?.title, "The Vibe hook files are still on the host")
        XCTAssertEqual(model.hosts.first?.vibeHooks, .notSetUp)
        XCTAssertEqual(model.hosts.first?.vibeHooksResult, "Withdrawn. Host files remain.")
    }

    func testAStaleResultDoesNotOutliveARotation() async throws {
        let (registry, hostID) = try enrolled()
        let host = try FakeHost()
        let model = try makeModel(registry: registry, host: host)
        model.requestVibeHooksSetup(hostID: hostID)
        await model.confirmVibeHooksSetup()
        XCTAssertEqual(model.hosts.first?.vibeHooksResult, "Set up.")

        await model.rotate(hostID: hostID)
        model.refreshHosts()
        XCTAssertEqual(model.hosts.first?.vibeHooks, .notSetUp)
        XCTAssertNil(model.hosts.first?.vibeHooksResult)
    }
}
