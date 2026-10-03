import Foundation
import XCTest
import localvoxtralCore

/// `LOCALVOXTRAL_SSH_CONFIG` reaches every ssh the app starts and the file
/// enrollment edits, and changes nothing when unset (#1029). The app target's
/// herdr forward spawner has its own case in `ClaudeRemoteHerdrForwardTests`.
final class SSHConfigOverrideTests: XCTestCase {
    private var directory: URL!
    private var overridePath: String { directory.appendingPathComponent("ssh_config").path }
    private var overridden: [String: String] { [SSHConfigOverride.environmentKey: overridePath] }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvx-ssh-config-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A stand-in ssh that prints each argument on its own stderr line and
    /// appends them to `arguments.log`.
    private func fakeSSH() throws -> URL {
        let url = directory.appendingPathComponent("ssh")
        let log = directory.appendingPathComponent("arguments.log").path
        try Data("""
        #!/bin/sh
        for argument in "$@"; do printf '%s\\n' "$argument" >&2; printf '%s\\n' "$argument" >> '\(log)'; done
        """.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func loggedArguments() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("arguments.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func testUnsetOrEmptyLeavesTheArgvAndTheConfigPathAlone() {
        let argv = ["ssh", "-o", "BatchMode=yes", "--", "builder", "/bin/sh", "-s"]
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        for environment in [[:], [SSHConfigOverride.environmentKey: ""]] {
            XCTAssertNil(SSHConfigOverride.path(environment: environment))
            XCTAssertEqual(SSHConfigOverride.argv(argv, environment: environment), argv)
            XCTAssertEqual(
                SSHConfigOverride.configFileURL(homeDirectoryURL: home, environment: environment).path,
                "/Users/someone/.ssh/config"
            )
        }
    }

    func testSetPutsTheFileRightAfterTheProgramBeforeEveryOption() {
        XCTAssertEqual(
            SSHConfigOverride.argv(["ssh", "-G", "--", "builder"], environment: overridden),
            ["ssh", "-F", overridePath, "-G", "--", "builder"]
        )
        XCTAssertEqual(SSHConfigOverride.argv([], environment: overridden), [])
    }

    /// Every enrollment, verification, Vibe and ownership-probe ssh goes
    /// through this runner.
    func testEnrollmentRunnerPassesTheFileOnlyWhenSet() throws {
        let invocation = ClaudeRemoteEnrollmentService.Invocation(
            argv: ClaudeRemoteForwardOwnershipCheck.argv(sshHostAlias: "builder"),
            standardInput: Data(),
            timeout: 10
        )
        let environment = overridden
        let runOverridden = ClaudeRemoteEnrollmentService.processRunner(
            sshExecutableURL: try fakeSSH(), environment: { environment }
        )
        XCTAssertTrue(try runOverridden(invocation).succeeded)
        XCTAssertEqual(try loggedArguments(), ["-F", overridePath] + invocation.argv.dropFirst())

        try FileManager.default.removeItem(at: directory.appendingPathComponent("arguments.log"))
        let runPlain = ClaudeRemoteEnrollmentService.processRunner(
            sshExecutableURL: try fakeSSH(), environment: { [:] }
        )
        XCTAssertTrue(try runPlain(invocation).succeeded)
        XCTAssertEqual(try loggedArguments(), Array(invocation.argv.dropFirst()))
    }

    /// The supervised `ssh -N -R` of a persistent Claude forward.
    func testForwardProcessPassesTheFile() async throws {
        let process = try ClaudeRemoteForwardLiveProcess(
            argv: ["ssh", "-N", "--", "builder"],
            sshExecutableURL: try fakeSSH(),
            environment: overridden
        )
        var lines: [String] = []
        for await line in process.standardErrorLines { lines.append(line) }
        _ = await process.waitUntilExit()
        XCTAssertEqual(lines, ["-F", overridePath, "-N", "--", "builder"])
    }

    /// `ssh -G` against the real client: two aliases only the override file
    /// defines resolve to one host, which they cannot through the default chain.
    func testCanonicalizerResolvesThroughTheFile() async throws {
        try Data("""
        Host lvx-override-a lvx-override-b
          HostName 192.0.2.7
          Port 2201
        """.utf8).write(to: URL(fileURLWithPath: overridePath))
        let enrolled = ClaudeRemoteHost(
            id: "h1", label: "b", sshHostAlias: "lvx-override-b", createdAt: Date(timeIntervalSince1970: 0)
        )
        let environment = overridden
        let overriddenMatches = await SSHDestinationCanonicalizer.live(environment: { environment })
            .matchingHosts(destination: "lvx-override-a", enrolledHosts: [enrolled])
        XCTAssertEqual(overriddenMatches, [enrolled])

        let plainMatches = await SSHDestinationCanonicalizer.live(environment: { [:] })
            .matchingHosts(destination: "lvx-override-a", enrolledHosts: [enrolled])
        XCTAssertEqual(plainMatches, [])
    }

    /// Enrollment's host block lands in the override file; the home's `.ssh`
    /// is never created.
    func testEnrollmentWritesTheFileInsteadOfTheHomeConfig() throws {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fileSystem = LiveClaudeRemoteSSHConfigFileSystem(homeDirectoryURL: home, environment: overridden)
        let block = Data("Host builder\n  RemoteForward 8473 127.0.0.1:8473\n".utf8)

        try fileSystem.withExclusiveAccess {
            try fileSystem.atomicWriteConfig(block, permissions: 0o600, replacing: nil)
        }

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: overridePath)), block)
        XCTAssertEqual(try fileSystem.readState().configData, block)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".ssh").path))
    }
}
