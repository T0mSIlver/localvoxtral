import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

/// Every invocation a fake runner saw, shareable with the runner closure.
private final class InvocationLog: Sendable {
    private let storage = Mutex<[ClaudeRemoteEnrollmentService.Invocation]>([])
    var all: [ClaudeRemoteEnrollmentService.Invocation] { storage.withLock { $0 } }
    /// Records the call and returns its index.
    @discardableResult
    func record(_ invocation: ClaudeRemoteEnrollmentService.Invocation) -> Int {
        storage.withLock { calls in
            calls.append(invocation)
            return calls.count - 1
        }
    }
}

/// A host whose only ssh is Claude Desktop's (#656): Desktop's master clears
/// every forward, runs its sessions under `~/.claude/remote/srv`, and ships
/// its own CLI in `~/.claude/remote/ccd-cli/<version>`.
///
/// The scripts here RUN, under `/bin/sh`, against a throwaway `$HOME`: the
/// shell is the part that has to be right on the host, and a string match on
/// it would pass a script that does not work.
final class ClaudeRemoteDesktopHostTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-desktop-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Runs `script` the way the host would: `/bin/sh -s`, script on stdin,
    /// this test's `$HOME`, and a PATH with no user directory on it, so the
    /// box's own `claude` can never answer for the fake host.
    private func runOnFakeHost(_ script: Data) throws -> ClaudeRemoteEnrollmentService.RunResult {
        try Self.run(script, home: home.path)
    }

    private static func run(_ script: Data, home: String) throws -> ClaudeRemoteEnrollmentService.RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(script)
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .init(exitCode: process.terminationStatus, message: String(decoding: data, as: UTF8.self))
    }

    private func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(relative, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// A stand-in CLI that prints which file it is.
    private func installFakeCLI(_ relative: String, executable: Bool = true) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\necho \"cli=\(relative) args=$*\"\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path
        )
    }

    // MARK: - Claude Desktop detection

    /// Both branches of the probe in ONE shell: the production script runs
    /// twice against two throwaway homes — one carrying Desktop's
    /// `~/.claude/remote/srv`, one a plain Claude Code home that keeps
    /// `~/.claude` and `~/.claude/remote` — and each row's framed answer is
    /// asserted by name. The service's reading of a framed yes/no is
    /// `testOnlyTheFramedLineDecides`; what it sends to read is
    /// `testTheDesktopProbeClearsForwardingsAndCarriesNoToken`.
    func testTheProbeAnswersYesOnlyForDesktopsDaemonDirectory() throws {
        try makeDirectory(".claude/remote/srv/90fca6e6")
        let desktopHome = home.path
        let plainHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-desktop-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plainHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plainHome) }
        try FileManager.default.createDirectory(
            at: plainHome.appendingPathComponent(".claude/plugins", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: plainHome.appendingPathComponent(".claude/remote", isDirectory: true),
            withIntermediateDirectories: true
        )

        let probe = String(decoding: ClaudeRemoteEnrollmentService.claudeDesktopProbeScript, as: UTF8.self)
        let bothHomes = "HOME='\(desktopHome)'\n\(probe)HOME='\(plainHome.path)'\n\(probe)"
        let result = try runOnFakeHost(Data(bothHomes.utf8))

        XCTAssertEqual(result.exitCode, 0, result.message)
        let answers = result.message.split(separator: "\n").map(String.init)
        XCTAssertEqual(answers.count, 2, result.message)
        XCTAssertEqual(
            answers.first, "LVX_DESKTOP:yes",
            "a home with ~/.claude/remote/srv is Desktop's"
        )
        XCTAssertEqual(
            answers.last, "LVX_DESKTOP:no",
            "a plain Claude Code home is not"
        )
    }

    /// What the service SENDS on the Desktop probe. The runner is scripted:
    /// every assertion below is about the invocation the service built, and
    /// the probe script's behavior under a real shell is the detection test
    /// above.
    func testTheDesktopProbeClearsForwardingsAndCarriesNoToken() throws {
        let log = InvocationLog()
        let scripted = ClaudeRemoteEnrollmentService(runner: { invocation in
            log.record(invocation)
            return .init(exitCode: 0, message: "LVX_DESKTOP:no\n")
        })
        _ = try scripted.detectClaudeDesktop(sshHostAlias: "builder")
        let recorded = log.all
        XCTAssertEqual(
            recorded.map(\.argv),
            [["ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--", "builder", "/bin/sh", "-s"]]
        )
        XCTAssertEqual(
            recorded.first?.standardInput, ClaudeRemoteEnrollmentService.claudeDesktopProbeScript,
            "the service runs the probe the detection test proves under a real shell"
        )
        let script = String(decoding: recorded[0].standardInput, as: UTF8.self)
        XCTAssertFalse(script.lowercased().contains("token"))
        XCTAssertFalse(script.contains("rm "), "the probe only looks")
    }

    /// A banner or MOTD cannot answer for the host, and a host that says
    /// nothing framed is an error, not a "no".
    func testOnlyTheFramedLineDecides() throws {
        func service(_ message: String) -> ClaudeRemoteEnrollmentService {
            ClaudeRemoteEnrollmentService(runner: { _ in .init(exitCode: 0, message: message) })
        }
        XCTAssertTrue(
            try service("Welcome, LVX_DESKTOP:no mid-line is not a frame\nLVX_DESKTOP:yes\n")
                .detectClaudeDesktop(sshHostAlias: "builder"),
            "a frame starts its line"
        )
        XCTAssertFalse(try service("motd\nLVX_DESKTOP:no\nLVX_DESKTOP:yes\n").detectClaudeDesktop(sshHostAlias: "builder"))
        XCTAssertThrowsError(try service("motd only\n").detectClaudeDesktop(sshHostAlias: "builder"))
        XCTAssertThrowsError(try service("LVX_DESKTOP:maybe\n").detectClaudeDesktop(sshHostAlias: "builder"))
        XCTAssertThrowsError(
            try ClaudeRemoteEnrollmentService(runner: { _ in .init(exitCode: 255, message: "LVX_DESKTOP:yes") })
                .detectClaudeDesktop(sshHostAlias: "builder"),
            "ssh failing decides nothing"
        )
        XCTAssertThrowsError(try service("LVX_DESKTOP:yes").detectClaudeDesktop(sshHostAlias: "-oProxyCommand=x"))
    }

    // MARK: - Claude Desktop's CLI

    private func resolveClaude() throws -> ClaudeRemoteEnrollmentService.RunResult {
        try runOnFakeHost(ClaudeRemoteEnrollmentService.remoteScript(command: "claude plugin list"))
    }

    /// The Desktop CLI is the last resort, and among its version-named files
    /// the newest RUNNABLE one wins: versions compare field by field (a
    /// string sort would pick 2.1.9 over 2.1.10), and a partial download, a
    /// temp name or a non-runnable file never counts — here they sit BESIDE
    /// the real files, so the filter must refuse them, not just fall back to
    /// the only runnable one.
    func testTheResolverPicksTheNewestRunnableDesktopCLI() throws {
        try installFakeCLI(".claude/remote/ccd-cli/2.0.300")
        try installFakeCLI(".claude/remote/ccd-cli/2.1.9")
        try installFakeCLI(".claude/remote/ccd-cli/2.1.10")
        try installFakeCLI(".claude/remote/ccd-cli/2.1.10.partial")
        try installFakeCLI(".claude/remote/ccd-cli/2.1.11-tmp")
        try installFakeCLI(".claude/remote/ccd-cli/.2.1.12")
        try installFakeCLI(".claude/remote/ccd-cli/9.9.9", executable: false)

        let result = try resolveClaude()
        XCTAssertEqual(result.exitCode, 0, result.message)
        XCTAssertEqual(
            result.message.trimmingCharacters(in: .whitespacesAndNewlines),
            "cli=.claude/remote/ccd-cli/2.1.10 args=plugin list"
        )
    }

    /// A regular install still wins: the Desktop CLI is the last resort.
    func testAnInstalledClaudeWinsOverDesktopsCLI() throws {
        try installFakeCLI(".local/bin/claude")
        try installFakeCLI(".claude/remote/ccd-cli/2.1.10")
        XCTAssertTrue(try resolveClaude().message.contains("cli=.local/bin/claude "))
    }

    func testAHostWithNoClaudeAnywhereStillFailsWithOurOwnMessage() throws {
        try makeDirectory(".claude/remote/ccd-cli")
        let result = try resolveClaude()
        XCTAssertEqual(result.exitCode, 127)
        XCTAssertTrue(result.message.contains("'claude' was not found"), result.message)
        XCTAssertTrue(result.message.contains("ccd-cli"), "the message names every place it looked")
    }

    // MARK: - The tunnel check (#656)

    private struct ScriptedHost {
        let answers: [String]
        let log = InvocationLog()

        var service: ClaudeRemoteEnrollmentService {
            let answers = answers
            let log = log
            return ClaudeRemoteEnrollmentService(runner: { invocation in
                let index = log.record(invocation)
                return .init(exitCode: 0, message: index < answers.count ? answers[index] : "")
            })
        }

        var argvs: [[String]] { log.all.map(\.argv) }
    }

    private func tunnelCheck(
        _ host: ScriptedHost, listenerIsBound: Bool = true
    ) throws -> ClaudeRemoteEnrollmentService.VerificationCheck {
        try XCTUnwrap(
            host.service.executeVerification(
                sshHostAlias: "builder",
                remoteForwardPort: 28511,
                listenerIsBound: listenerIsBound,
                includesPluginCheck: false
            ).first { $0.kind == .tunnel }
        )
    }

    private let standingProbe = ["ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--", "builder", "/bin/sh", "-s"]
    private let configProbe = ["ssh", "-o", "BatchMode=yes", "--", "builder", "/bin/sh", "-s"]

    /// The bug: the old probe carried the alias's RemoteForward itself, curled
    /// through the forward it had just opened, and passed. On a host reached
    /// only by Claude Desktop, that tunnel exists exactly as long as the check.
    func testATunnelOnlyTheCheckItselfOpenedIsNotAPass() throws {
        let host = ScriptedHost(answers: ["LVX_HTTP:000", "LVX_HTTP:401"])
        let check = try tunnelCheck(host)
        XCTAssertFalse(check.passed)
        XCTAssertEqual(check.summary, "Your SSH config opens the tunnel, but nothing keeps it open.")
        XCTAssertTrue(check.hint?.contains("Keep the tunnel open") ?? false)
        XCTAssertTrue(check.hint?.contains("Claude Desktop") ?? false)
        XCTAssertEqual(host.argvs, [standingProbe, configProbe])
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService.reconciled([check], remoteForwardPort: 28511, listenerIsBound: true),
            [check],
            "a later listener read cannot turn a tunnel that closed into a standing one"
        )
    }

    func testNothingAnsweringEitherWayBlamesTheConfigBlock() throws {
        let host = ScriptedHost(answers: ["LVX_HTTP:000", "LVX_HTTP:000"])
        let check = try tunnelCheck(host)
        XCTAssertFalse(check.passed)
        XCTAssertEqual(check.summary, "The SSH config did not open a tunnel.")
        XCTAssertFalse(
            check.hint?.contains("SSH session") ?? false,
            "opening an SSH session is what the second probe just did"
        )
    }

    /// Answers the first probe settles need no second connection.
    func testOnlySilenceRunsTheConfigProbe() throws {
        for answer in ["LVX_HTTP:200", ClaudeRemoteEnrollmentService.missingCurlSentinel] {
            let host = ScriptedHost(answers: [answer])
            XCTAssertFalse(try tunnelCheck(host).passed)
            XCTAssertEqual(host.argvs, [standingProbe], answer)
        }
    }

    /// A 401 while this Mac's listener is down came from whoever holds the
    /// listener port, whichever probe carried it.
    func testASquatterThroughTheConfigProbeIsStillASquatter() throws {
        let host = ScriptedHost(answers: ["LVX_HTTP:000", "LVX_HTTP:401"])
        let check = try tunnelCheck(host, listenerIsBound: false)
        XCTAssertFalse(check.passed)
        XCTAssertTrue(check.summary.contains("Something else answered"), check.summary)
        XCTAssertFalse(
            ClaudeRemoteEnrollmentService.reconciled([check], remoteForwardPort: 28511, listenerIsBound: true)[0].passed,
            "binding the listener afterwards does not make that tunnel standing"
        )
    }

    /// Both probes run the same read-only script and carry no credential.
    func testNeitherTunnelProbeCarriesACredential() throws {
        let host = ScriptedHost(answers: ["LVX_HTTP:000", "LVX_HTTP:401"])
        _ = try tunnelCheck(host)
        let everything = host.log.all.map {
            $0.argv.joined(separator: " ") + String(decoding: $0.standardInput, as: UTF8.self)
        }
        XCTAssertEqual(everything.count, 2)
        for text in everything {
            XCTAssertTrue(text.contains("http://127.0.0.1:28511/v1/hook/SessionStart"))
            XCTAssertFalse(text.lowercased().contains("authorization"))
            XCTAssertFalse(text.contains("--config"))
        }
    }
}
