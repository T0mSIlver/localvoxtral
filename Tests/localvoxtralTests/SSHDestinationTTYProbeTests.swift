import Foundation
import XCTest
@testable import localvoxtral

#if canImport(Darwin)
import Darwin

/// The probe that binds "the surface the user is looking at" to "an ssh
/// CONNECTION to this enrolled host".
///
/// Everything here is the pure half: both live reads are injected, so the whole
/// truth table runs without a real tty, a real ssh, or a real process table.
final class SSHDestinationTTYProbeTests: XCTestCase {
    private let surface: dev_t = 42
    private let otherTerminal: dev_t = 43

    private func probe(
        deviceID: dev_t? = 42,
        processes: [SSHClientProcess]?
    ) -> SSHDestinationTTYProbeResult {
        SSHDestinationTTYProbe.connection(
            onTTYDevicePath: "/dev/ttys003",
            deviceID: { _ in deviceID },
            sshProcesses: { processes }
        )
    }

    /// A well-formed foreground ssh on the surface, unless told otherwise.
    private func ssh(
        _ arguments: [String]?,
        pid: Int32 = 501,
        device: dev_t? = 42,
        foreground: Bool = true,
        executable: String? = "/usr/bin/ssh"
    ) -> SSHClientProcess {
        SSHClientProcess(
            pid: pid,
            ttyDevice: device,
            processGroupID: pid,
            terminalForegroundGroupID: foreground ? pid : pid + 1000,
            executablePath: executable,
            arguments: arguments
        )
    }

    private func connection(_ result: SSHDestinationTTYProbeResult) -> SSHSurfaceConnection? {
        guard case .connection(let value) = result else { return nil }
        return value
    }

    // MARK: - Truth table

    func testNoSSHProcessOnTheDeviceIsAnAbsenceNotAnAbstention() {
        XCTAssertEqual(probe(processes: []), .noSSHClient)
    }

    func testUnreadableDeviceAbstains() {
        XCTAssertEqual(probe(deviceID: nil, processes: [ssh(["ssh", "builder"])]), .undeterminable)
    }

    func testUnreadableProcessTableAbstains() {
        XCTAssertEqual(probe(processes: nil), .undeterminable)
    }

    func testOneForegroundSSHClientReportsItsConnection() throws {
        let value = try XCTUnwrap(connection(probe(processes: [ssh(["ssh", "builder"])])))
        XCTAssertEqual(value.destination, "builder")
        XCTAssertTrue(value.isOnlyConnectionToDestination)
        XCTAssertFalse(value.indicatesHerdr)
    }

    func testUnreadableArgvOfAnSSHProcessAbstains() {
        // Absence of argv is not absence of ssh: this surface IS a remote
        // session, we just cannot say to where.
        XCTAssertEqual(probe(processes: [ssh(nil)]), .undeterminable)
    }

    // MARK: - Executable verification (review finding 2)

    func testAnSSHNamedProcessWithAnotherExecutableAbstains() {
        // `p_comm` is 16 bytes the process chose, and argv[0] is chosen by
        // whoever exec'd it. Neither is evidence of running OpenSSH.
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "builder"], executable: "/tmp/evil/ssh")]),
            .undeterminable
        )
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "builder"], executable: "/Users/dev/bin/ssh")]),
            .undeterminable
        )
    }

    func testUnknownExecutablePathAbstains() {
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "builder"], executable: nil)]), .undeterminable
        )
    }

    func testOnlyTheThreeCanonicalPathsAreTrustedOutright() {
        for path in SSHDestinationTTYProbe.canonicalSSHExecutablePaths {
            XCTAssertTrue(
                SSHDestinationTTYProbe.isTrustedSSHExecutable(path, resolvedPath: { _ in nil }),
                path
            )
        }
        XCTAssertFalse(
            SSHDestinationTTYProbe.isTrustedSSHExecutable(
                "/opt/homebrew/bin/sshpass", resolvedPath: { _ in nil }
            )
        )
    }

    func testAnImpostorInAWritableTreeIsRefused() {
        // The earlier rule trusted any `ssh` basename under `/opt/homebrew/` or
        // `/usr/local/` — both user-writable, so a compiled impostor with a
        // crafted argv passed (review round 3, blocker 2).
        let impostors = [
            "/opt/homebrew/tmp/ssh",
            // A real-looking Cellar path that nothing canonical resolves to.
            "/opt/homebrew/Cellar/openssh/9.9p1/bin/ssh",
            "/usr/local/lib/evil/ssh",
            "/usr/local/bin/../../tmp/ssh",
            "/tmp/ssh",
            "ssh",
        ]
        for path in impostors {
            XCTAssertFalse(
                SSHDestinationTTYProbe.isTrustedSSHExecutable(path, resolvedPath: { _ in nil }),
                "\(path) must be refused"
            )
        }
    }

    func testAnImpostorIsRefusedByTheProbeItself() {
        // The same thing one level up: a crafted argv on the surface tty, from
        // an executable in a writable tree, must not produce a destination.
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "builder"], executable: "/opt/homebrew/tmp/ssh")]),
            .undeterminable
        )
    }

    func testTheHomebrewCellarIsTrustedOnlyWhenItIsWhatBinResolvesTo() {
        // proc_pidpath reports the RESOLVED path, and Homebrew's bin/ssh is a
        // symlink into the Cellar. That path is trusted only while the
        // canonical bin path actually points at it — never because of where it
        // happens to live.
        let cellar = "/opt/homebrew/Cellar/openssh/9.9p1/bin/ssh"
        let resolve: (String) -> String? = { $0 == "/opt/homebrew/bin/ssh" ? cellar : nil }
        XCTAssertTrue(SSHDestinationTTYProbe.isTrustedSSHExecutable(cellar, resolvedPath: resolve))
        // A sibling in the very same Cellar tree is not.
        XCTAssertFalse(
            SSHDestinationTTYProbe.isTrustedSSHExecutable(
                "/opt/homebrew/Cellar/openssh/9.9p1/bin/ssh-impostor", resolvedPath: resolve
            )
        )
        XCTAssertFalse(
            SSHDestinationTTYProbe.isTrustedSSHExecutable(
                "/opt/homebrew/Cellar/evil/1.0/bin/ssh", resolvedPath: resolve
            )
        )
    }

    func testASymlinkedImpostorInTheSameTreeIsRefused() {
        // Review round 4, blocker 1: the first symlink rule accepted ANYTHING a
        // canonical path resolved to, so repointing Homebrew's `ssh` at a
        // same-tree `ssh-impostor` was trusted. The resolved basename must be
        // exactly `ssh`.
        let impostor = "/opt/homebrew/Cellar/openssh/9.9p1/bin/ssh-impostor"
        let resolve: (String) -> String? = { $0 == "/opt/homebrew/bin/ssh" ? impostor : nil }
        XCTAssertFalse(
            SSHDestinationTTYProbe.isTrustedSSHExecutable(impostor, resolvedPath: resolve)
        )
    }

    func testASymlinkPointingOUTSIDETheInstallationTreeIsRefused() {
        // …and the target must stay inside the tree its canonical name lives
        // in, so `/opt/homebrew/bin/ssh` cannot vouch for `/tmp/evil/ssh`.
        let outside = "/tmp/evil/ssh"
        let resolve: (String) -> String? = { $0 == "/opt/homebrew/bin/ssh" ? outside : nil }
        XCTAssertFalse(
            SSHDestinationTTYProbe.isTrustedSSHExecutable(outside, resolvedPath: resolve)
        )
        let elsewhereInUsr = "/usr/lib/evil/ssh"
        let usrResolve: (String) -> String? = {
            $0 == "/usr/local/bin/ssh" ? elsewhereInUsr : nil
        }
        // `/usr/local`'s root is `/usr/local`, so `/usr/lib/...` is outside it
        // even though both live under `/usr`.
        XCTAssertFalse(
            SSHDestinationTTYProbe.isTrustedSSHExecutable(elsewhereInUsr, resolvedPath: usrResolve)
        )
    }

    func testTheInstallationRootIsDerivedFromTheCanonicalPath() {
        XCTAssertEqual(
            SSHDestinationTTYProbe.installationRoot(ofCanonicalPath: "/opt/homebrew/bin/ssh"),
            "/opt/homebrew"
        )
        XCTAssertEqual(
            SSHDestinationTTYProbe.installationRoot(ofCanonicalPath: "/usr/bin/ssh"), "/usr"
        )
        XCTAssertEqual(
            SSHDestinationTTYProbe.installationRoot(ofCanonicalPath: "/usr/local/bin/ssh"),
            "/usr/local"
        )
        // Not a `bin` directory ⇒ no root ⇒ nothing can be vouched for.
        XCTAssertNil(SSHDestinationTTYProbe.installationRoot(ofCanonicalPath: "/opt/ssh"))
    }

    func testTheLiveCanonicalResolutionAcceptsTheSystemSSH() {
        // The live half of the rule, against this machine's actual /usr/bin/ssh.
        XCTAssertTrue(SSHDestinationTTYProbe.isTrustedSSHExecutable("/usr/bin/ssh"))
    }

    // MARK: - Foreground process group (review finding 2)

    func testABackgroundedOrStoppedSSHOnTheSurfaceIsNotTheSurface() {
        // The user suspended ssh and is back at the shell: the terminal shows a
        // local prompt, so the remote arm must not apply at all.
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "builder"], foreground: false)]), .noSSHClient
        )
    }

    func testAnSSHHelperOfAnotherProcessIsNotTheSurface() {
        // `scp`/`rsync` spawn ssh in their own process group; the terminal's
        // foreground group is the scp, not this.
        let helper = SSHClientProcess(
            pid: 900,
            ttyDevice: surface,
            processGroupID: 800,
            terminalForegroundGroupID: 700,
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder"]
        )
        XCTAssertEqual(probe(processes: [helper]), .noSSHClient)
    }

    // MARK: - Machine-wide uniqueness (review blocker 1a)

    func testASecondTerminalToTheSameHostRemovesUniqueness() throws {
        // Codex's scenario: this terminal is a plain shell to `builder`, and
        // another terminal is attached to herdr on `builder`.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "builder"], pid: 501),
                        ssh(["ssh", "builder"], pid: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertEqual(value.destination, "builder")
        XCTAssertFalse(value.isOnlyConnectionToDestination)
    }

    func testASuspendedSSHOnTHISDeviceRemovesUniqueness() throws {
        // Review round 5b, major 2. Repro: `ssh builder herdr`, Ctrl+Z — the
        // client is stopped but its server side is still attached and its pane
        // still focused — then a plain `ssh builder` in the foreground of the
        // SAME terminal. Skipping same-device background processes made that
        // foreground session claim to be the only connection.
        let suspendedHerdrClient = SSHClientProcess(
            pid: 777,
            ttyDevice: surface,
            processGroupID: 777,
            terminalForegroundGroupID: 501, // the plain ssh has the terminal
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder", "herdr", "attach"]
        )
        let value = try XCTUnwrap(
            connection(probe(processes: [ssh(["ssh", "builder"], pid: 501), suspendedHerdrClient]))
        )
        XCTAssertEqual(value.destination, "builder")
        XCTAssertFalse(
            value.isOnlyConnectionToDestination,
            "a suspended ssh to the same host is still a second connection"
        )
    }

    func testASecondForegroundSSHInAnotherPaneOfTheSameDeviceRemovesUniqueness() throws {
        // Same rule, without the suspension: two process groups on one device.
        let sibling = SSHClientProcess(
            pid: 888,
            ttyDevice: surface,
            processGroupID: 888,
            terminalForegroundGroupID: 501,
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder"]
        )
        let value = try XCTUnwrap(
            connection(probe(processes: [ssh(["ssh", "builder"], pid: 501), sibling]))
        )
        XCTAssertFalse(value.isOnlyConnectionToDestination)
    }

    func testAnotherTerminalToADIFFERENTHostLeavesUniquenessIntact() throws {
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "builder"], pid: 501),
                        ssh(["ssh", "elsewhere"], pid: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertTrue(value.isOnlyConnectionToDestination)
    }

    func testAnUnreadableSSHElsewhereRemovesUniqueness() throws {
        // Uniqueness is a claim; a process we cannot read cannot be part of one.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "builder"], pid: 501),
                        ssh(nil, pid: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertFalse(value.isOnlyConnectionToDestination)
    }

    func testOurOwnTTYLessForwardDoesNotRemoveUniqueness() throws {
        // The app's `ssh -N -L … builder` has no controlling terminal, so it is
        // not a surface anyone can dictate into. (It also carries -N, which the
        // parser refuses outright — hence unreadable, hence excluded by the
        // no-terminal rule BEFORE that matters.)
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "builder"], pid: 501),
                        ssh(
                            ["ssh", "-N", "-L", "/tmp/a.sock:/run/h.sock", "--", "builder"],
                            pid: 999,
                            device: nil
                        ),
                    ]
                )
            )
        )
        XCTAssertTrue(value.isOnlyConnectionToDestination)
    }

    func testTwoForegroundSSHClientsOnOneSurfaceAbstainEvenToTheSameHost() {
        // Review round 7: the first version UNIONED the foreground processes —
        // one destination set, `indicatesHerdr` OR-ed across them — so a group
        // holding both `ssh builder` and `ssh builder herdr` reported "unique"
        // AND "is herdr", and the plain, visible connection borrowed the
        // other's herdr signal. There is no way to tell which one the user is
        // looking at, so neither answers.
        XCTAssertEqual(
            probe(
                processes: [
                    ssh(["ssh", "builder"], pid: 501),
                    ssh(["ssh", "builder", "herdr", "attach"], pid: 502),
                ]
            ),
            .undeterminable
        )
    }

    func testAWrapperLaunchingSeveralSSHChildrenInOneGroupAbstains() {
        // The sibling-process shape: a pipeline or wrapper whose children share
        // the foreground process group.
        let first = SSHClientProcess(
            pid: 601,
            ttyDevice: surface,
            processGroupID: 600,
            terminalForegroundGroupID: 600,
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder", "herdr"]
        )
        let second = SSHClientProcess(
            pid: 602,
            ttyDevice: surface,
            processGroupID: 600,
            terminalForegroundGroupID: 600,
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder"]
        )
        XCTAssertEqual(probe(processes: [first, second]), .undeterminable)
    }

    func testTwoForegroundSSHClientsToDifferentHostsOnOneSurfaceAbstain() {
        XCTAssertEqual(
            probe(
                processes: [
                    ssh(["ssh", "builder"], pid: 501),
                    ssh(["ssh", "other"], pid: 502),
                ]
            ),
            .undeterminable
        )
    }

    // MARK: - herdr connection signal (review blocker 1b)

    func testARemoteCommandNamingHerdrBindsTheConnection() throws {
        let value = try XCTUnwrap(
            connection(probe(processes: [ssh(["ssh", "-t", "builder", "herdr", "attach"])]))
        )
        XCTAssertTrue(value.indicatesHerdr)
    }

    func testAnAbsolutePathToHerdrCounts() {
        XCTAssertTrue(SSHDestinationTTYProbe.commandNamesHerdr(["/usr/local/bin/herdr", "attach"]))
    }

    func testOnlyTheFirstCommandTokenCounts() {
        // The forgery the round-3 review found: any token that merely MENTIONED
        // herdr used to set the signal, so `printf herdr; exec claude` claimed
        // to be a herdr connection. A shell wrapper is refused for the same
        // reason it was the exploit — its first token is `sh`, and what it goes
        // on to run is not something an argv can promise.
        XCTAssertFalse(
            SSHDestinationTTYProbe.commandNamesHerdr(["sh", "-lc", "printf herdr; exec claude"])
        )
        XCTAssertFalse(SSHDestinationTTYProbe.commandNamesHerdr(["sh", "-lc", "herdr attach main"]))
        XCTAssertFalse(SSHDestinationTTYProbe.commandNamesHerdr(["echo", "herdr"]))
        XCTAssertFalse(SSHDestinationTTYProbe.commandNamesHerdr(["cat", "herdr.log"]))
        XCTAssertFalse(SSHDestinationTTYProbe.commandNamesHerdr(["/srv/herdrless/run"]))
        XCTAssertFalse(SSHDestinationTTYProbe.commandNamesHerdr([]))
        XCTAssertFalse(SSHDestinationTTYProbe.commandNamesHerdr([""]))
    }

    func testAForgedHerdrMentionDoesNotIndicateHerdr() throws {
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "builder", "sh", "-lc", "printf herdr; exec claude"]),
                    ]
                )
            )
        )
        XCTAssertFalse(value.indicatesHerdr)
    }

    func testAPlainShellConnectionDoesNotIndicateHerdr() throws {
        let value = try XCTUnwrap(connection(probe(processes: [ssh(["ssh", "builder"])])))
        XCTAssertFalse(value.indicatesHerdr)
    }

    // MARK: - argv parsing

    private func destination(_ argv: [String]) -> String? {
        SSHDestinationTTYProbe.parse(arguments: argv)?.destination
    }

    func testPlainDestination() {
        XCTAssertEqual(destination(["ssh", "builder"]), "builder")
    }

    func testUserAtHostKeepsOnlyTheHost() {
        XCTAssertEqual(destination(["ssh", "tom@builder"]), "builder")
    }

    func testDestinationIsLowercasedForComparison() {
        XCTAssertEqual(destination(["ssh", "Builder.Local"]), "builder.local")
    }

    func testAbsolutePathArgumentZeroIsStillSSH() {
        XCTAssertEqual(destination(["/usr/bin/ssh", "builder"]), "builder")
    }

    func testAnotherProgramIsNeverParsed() {
        XCTAssertNil(destination(["scp", "builder:/x", "/tmp"]))
    }

    func testSeparatedAndGluedInertOptionArgumentsAreSkipped() {
        XCTAssertEqual(destination(["ssh", "-p", "2222", "builder"]), "builder")
        XCTAssertEqual(destination(["ssh", "-p2222", "builder"]), "builder")
        XCTAssertEqual(destination(["ssh", "-i", "/keys/id", "builder"]), "builder")
    }

    func testClusteredFlagsAreSkipped() {
        XCTAssertEqual(destination(["ssh", "-tt", "builder"]), "builder")
        XCTAssertEqual(destination(["ssh", "-AC", "builder"]), "builder")
    }

    func testJumpHostOptionDoesNotBecomeTheDestination() {
        XCTAssertEqual(destination(["ssh", "-J", "bastion", "builder"]), "builder")
    }

    func testDoubleDashIntroducesTheDestination() {
        XCTAssertEqual(destination(["ssh", "-t", "--", "builder"]), "builder")
    }

    func testDoubleDashWithNothingAfterItAbstains() {
        XCTAssertNil(destination(["ssh", "--"]))
    }

    func testRemoteCommandIsNotMistakenForTheDestination() {
        // The reason this walks options in order instead of taking the last
        // non-option token: here that would answer `/tmp`.
        XCTAssertEqual(destination(["ssh", "builder", "ls", "/tmp"]), "builder")
    }

    // MARK: - Destination-moving options ABSTAIN (review finding 2)

    func testOptionsThatCanMoveTheDestinationAbstain() {
        // Every one of these reports `builder` while connecting elsewhere, or
        // means this is not an interactive session at all.
        let refused: [[String]] = [
            ["ssh", "-o", "HostName=other.example", "builder"],
            ["ssh", "-oHostName=other.example", "builder"],
            ["ssh", "-o", "ProxyJump=elsewhere", "builder"],
            ["ssh", "-F", "/tmp/alt.conf", "builder"],
            ["ssh", "-O", "check", "builder"],
            ["ssh", "-S", "/tmp/cm.sock", "builder"],
            ["ssh", "-N", "-L", "/tmp/a:/tmp/b", "builder"],
            ["ssh", "-f", "builder", "sleep", "60"],
            ["ssh", "-M", "builder"],
            ["ssh", "-D", "1080", "builder"],
            ["ssh", "-W", "host:22", "builder"],
            ["ssh", "-w", "0:0", "builder"],
            // Clustered with an inert flag, so the walk cannot miss it by only
            // looking at the first letter.
            ["ssh", "-tN", "builder"],
        ]
        for argv in refused {
            XCTAssertNil(destination(argv), "\(argv) must abstain")
        }
    }

    func testUnknownOptionLetterAbstains() {
        XCTAssertNil(destination(["ssh", "-Z", "builder"]))
    }

    func testTrailingOptionWithNoOperandAbstains() {
        XCTAssertNil(destination(["ssh", "-p", "2222"]))
    }

    func testNoOperandAtAllAbstains() {
        XCTAssertNil(destination(["ssh"]))
        XCTAssertNil(destination([]))
    }

    func testURIDestinationIsRefused() {
        XCTAssertNil(destination(["ssh", "ssh://tom@builder:22"]))
    }

    func testDestinationOutsideTheHostnameCharsetIsRefused() {
        XCTAssertNil(destination(["ssh", "builder;rm"]))
        XCTAssertNil(destination(["ssh", "builder/x"]))
        XCTAssertNil(destination(["ssh", "[fe80::1]"]))
    }

    func testEmptyHostPartIsRefused() {
        XCTAssertNil(destination(["ssh", "tom@"]))
        XCTAssertNil(SSHDestinationTTYProbe.normalizedDestination(""))
    }

    func testOverlongDestinationIsRefused() {
        XCTAssertNil(
            SSHDestinationTTYProbe.normalizedDestination(String(repeating: "a", count: 254))
        )
    }

    func testOptionClassification() {
        XCTAssertEqual(SSHDestinationTTYProbe.consumption(ofOptionToken: "-tt"), .selfContained)
        XCTAssertEqual(SSHDestinationTTYProbe.consumption(ofOptionToken: "-p"), .consumesNextArgument)
        XCTAssertEqual(SSHDestinationTTYProbe.consumption(ofOptionToken: "-p22"), .selfContained)
        XCTAssertEqual(SSHDestinationTTYProbe.consumption(ofOptionToken: "-tp"), .consumesNextArgument)
        XCTAssertEqual(SSHDestinationTTYProbe.consumption(ofOptionToken: "-o"), .refused)
        XCTAssertEqual(SSHDestinationTTYProbe.consumption(ofOptionToken: "-tF"), .refused)
        XCTAssertEqual(SSHDestinationTTYProbe.consumption(ofOptionToken: "-Z"), .unrecognized)
    }

    // MARK: - KERN_PROCARGS2 layout

    private func procargs(argc: Int32, execPath: String, arguments: [String]) -> [UInt8] {
        var buffer = [UInt8]()
        withUnsafeBytes(of: argc) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array(execPath.utf8))
        buffer.append(0)
        buffer.append(0) // alignment padding, as the kernel emits
        for argument in arguments {
            buffer.append(contentsOf: Array(argument.utf8))
            buffer.append(0)
        }
        buffer.append(contentsOf: Array("SHELL=/bin/zsh".utf8)) // environment, never read
        buffer.append(0)
        return buffer
    }

    func testProcessArgumentsBufferIsParsedUpToArgcAndStopsBeforeTheEnvironment() {
        let buffer = procargs(
            argc: 3, execPath: "/usr/bin/ssh", arguments: ["ssh", "-t", "builder"]
        )
        XCTAssertEqual(
            SSHDestinationTTYProbe.parseProcessArguments(buffer), ["ssh", "-t", "builder"]
        )
    }

    func testTruncatedProcessArgumentsBufferIsRefused() {
        // argc says three, and the third string runs off the end of the buffer
        // with no terminator — a layout we do not understand, so no answer.
        var buffer = [UInt8]()
        withUnsafeBytes(of: Int32(3)) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/usr/bin/ssh".utf8))
        buffer.append(0)
        buffer.append(0)
        buffer.append(contentsOf: Array("ssh".utf8))
        buffer.append(0)
        buffer.append(contentsOf: Array("-t".utf8))
        buffer.append(0)
        buffer.append(contentsOf: Array("build".utf8))
        XCTAssertNil(SSHDestinationTTYProbe.parseProcessArguments(buffer))
    }

    func testZeroArgumentCountIsRefused() {
        XCTAssertNil(
            SSHDestinationTTYProbe.parseProcessArguments(
                procargs(argc: 0, execPath: "/usr/bin/ssh", arguments: [])
            )
        )
    }

    func testEmptyBufferIsRefused() {
        XCTAssertNil(SSHDestinationTTYProbe.parseProcessArguments([]))
    }

    // MARK: - The live reads answer at all

    func testTheLiveProcessTableScanReturnsThisProcess() throws {
        // Cheap smoke over the machine-wide scan: the sizing/fetch pair and the
        // kinfo_proc decode either work or this test is the first to know.
        let entries = try XCTUnwrap(TTYProcessTable.allProcesses())
        let me = entries.first { $0.pid == getpid() }
        XCTAssertNotNil(me, "the scan must contain the test process itself")
    }

    func testTheLiveExecutablePathOfThisProcessResolves() throws {
        let path = try XCTUnwrap(SSHDestinationTTYProbe.executablePath(pid: getpid()))
        XCTAssertTrue(path.hasPrefix("/"), "got \(path)")
    }

    func testTheLiveArgumentsOfThisProcessResolve() throws {
        let arguments = try XCTUnwrap(SSHDestinationTTYProbe.processArguments(pid: getpid()))
        XCTAssertFalse(arguments.isEmpty)
    }
}
#endif
