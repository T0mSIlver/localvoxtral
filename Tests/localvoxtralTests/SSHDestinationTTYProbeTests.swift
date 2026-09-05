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
        processes: [SSHClientProcess]?,
        sockets: [Int32: [SSHClientSocket]] = [:],
        socketReads: SocketReadRecorder? = nil
    ) -> SSHDestinationTTYProbeResult {
        SSHDestinationTTYProbe.connection(
            onTTYDevicePath: "/dev/ttys003",
            deviceID: { _ in deviceID },
            sshProcesses: { processes },
            readSockets: { pid in
                socketReads?.record(pid)
                return sockets[pid]
            }
        )
    }

    /// Which pids the socket reader was asked about. The answer must be
    /// exactly one — the surface process — and never a machine-wide sweep.
    final class SocketReadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int32] = []
        func record(_ pid: Int32) {
            lock.lock()
            defer { lock.unlock() }
            seen.append(pid)
        }

        var pids: [Int32] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
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
        XCTAssertEqual(probe(deviceID: nil, processes: [ssh(["ssh", "builder"])]),
            .undeterminable(.deviceUnreadable)
        )
    }

    func testUnreadableProcessTableAbstains() {
        XCTAssertEqual(probe(processes: nil), .undeterminable(.tableUnreadable))
    }

    func testOneForegroundSSHClientReportsItsConnection() throws {
        let value = try XCTUnwrap(connection(probe(processes: [ssh(["ssh", "builder"])])))
        XCTAssertEqual(value.destination, "builder")
        XCTAssertFalse(value.hasCompetingHerdrClient)
        XCTAssertEqual(value.herdr, .notHerdr)
    }

    func testUnreadableArgvOfAnSSHProcessAbstains() {
        // Absence of argv is not absence of ssh: this surface IS a remote
        // session, we just cannot say to where.
        XCTAssertEqual(probe(processes: [ssh(nil)]), .undeterminable(.unreadableArguments))
    }

    // MARK: - Executable verification (review finding 2)

    func testAnSSHNamedProcessWithAnotherExecutableAbstains() {
        // `p_comm` is 16 bytes the process chose, and argv[0] is chosen by
        // whoever exec'd it. Neither is evidence of running OpenSSH.
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "builder"], executable: "/tmp/evil/ssh")]),
            .undeterminable(.untrustedExecutable)
        )
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "builder"], executable: "/Users/dev/bin/ssh")]),
            .undeterminable(.untrustedExecutable)
        )
    }

    func testUnknownExecutablePathAbstains() {
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "builder"], executable: nil)]),
            .undeterminable(.untrustedExecutable)
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
            .undeterminable(.untrustedExecutable)
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

    // MARK: - Competing herdr views (narrowed from machine-wide uniqueness, 2026-08-06)

    func testGhosttyShellIntegrationOptionsDoNotRefuseTheSurfaceProbe() throws {
        // Exact argv shape injected by Ghostty's `ghostty +ssh` shell
        // integration wrapper before the user's destination and command.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh([
                            "ssh",
                            "-o", "SetEnv=TERM=xterm-ghostty",
                            "-o", "SendEnv=COLORTERM",
                            "-o", "SendEnv=TERM_PROGRAM",
                            "-o", "SendEnv=TERM_PROGRAM_VERSION",
                            "builder", "herdr",
                        ]),
                    ]
                )
            )
        )
        XCTAssertEqual(value.destination, "builder")
        XCTAssertEqual(value.herdr, .plainClient(sessionSelector: nil))
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testGhosttyWrappedHerdrInAnotherTabDoesNotCompete() throws {
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(
                            [
                                "ssh",
                                "-o", "SetEnv=TERM=xterm-ghostty",
                                "-o", "SendEnv=COLORTERM",
                                "-o", "SendEnv=TERM_PROGRAM",
                                "-o", "SendEnv=TERM_PROGRAM_VERSION",
                                "builder", "herdr",
                            ],
                            pid: 777,
                            device: otherTerminal
                        ),
                    ]
                )
            )
        )
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testAPlainShellToTheSameHostDoesNotCompete() throws {
        // THE field workflow the blanket uniqueness rule refused: one terminal
        // attached to herdr, another keeping a plain shell to the same host
        // for builds. The plain shell is on another tty, so it cannot be the
        // surface being dictated into, and it runs no herdr — nothing about it
        // changes what this surface displays.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(["ssh", "builder"], pid: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertEqual(value.destination, "builder")
        XCTAssertFalse(value.hasCompetingHerdrClient)
        XCTAssertEqual(value.herdr, .plainClient(sessionSelector: nil))
    }

    func testASecondWholeViewClientOfTheSameServerDoesNotCompete() throws {
        // herdr focus is server-global and multi-client attach is a mirror
        // (verified in herdr source: handle_pane_current resolves the app's
        // active pane; tests/multi_client.rs broadcasts frames to all
        // clients), so two whole-view clients of one server display the SAME
        // focused pane and joining is correct for both.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(["ssh", "builder", "herdr"], pid: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testAHerdrClientOfAnotherSessionSelectorCompetes() throws {
        // Named sessions are separate servers with separate sockets. A client
        // of `--session scratch` displays a different herdr than the default
        // one the candidates named — the one shape that could put a different
        // herdr view on another terminal, so it must still block.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(
                            ["ssh", "builder", "herdr", "--session", "scratch"],
                            pid: 777,
                            device: otherTerminal
                        ),
                    ]
                )
            )
        )
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testMatchingSessionSelectorsDoNotCompete() throws {
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr", "--session", "scratch"], pid: 501),
                        ssh(
                            ["ssh", "builder", "herdr", "--session=scratch"],
                            pid: 777,
                            device: otherTerminal
                        ),
                    ]
                )
            )
        )
        XCTAssertEqual(value.herdr, .plainClient(sessionSelector: "scratch"))
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testASinglePaneHerdrAttachElsewhereCompetes() throws {
        // `herdr terminal attach <id>` renders one pane, not the server's
        // focused view — from here it is indistinguishable from a different
        // herdr view, so it blocks.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(
                            ["ssh", "builder", "herdr", "terminal", "attach", "w1:p3"],
                            pid: 777,
                            device: otherTerminal
                        ),
                    ]
                )
            )
        )
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testARefusedArgvElsewhereCompetesOnlyWhenItMentionsHerdr() throws {
        // An `-o` neighbor cannot have its destination parsed, but an argv
        // with no `herdr` substring anywhere cannot have run herdr as its
        // remote command. One-sided on purpose: it can over-block, never
        // under-block.
        let harmless = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(
                            ["ssh", "-o", "Compression=yes", "builder"],
                            pid: 777,
                            device: otherTerminal
                        ),
                    ]
                )
            )
        )
        XCTAssertFalse(harmless.hasCompetingHerdrClient)

        let suspicious = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(
                            ["ssh", "-o", "Compression=yes", "builder", "herdr"],
                            pid: 777,
                            device: otherTerminal
                        ),
                    ]
                )
            )
        )
        XCTAssertTrue(suspicious.hasCompetingHerdrClient)
    }

    func testAnUntrustedExecutableElsewhereCompetes() throws {
        // A tty-holding "ssh" that is not OpenSSH could be anything, including
        // a herdr client by other means. Unreadable means unruled-out.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(
                            ["ssh", "builder"],
                            pid: 777,
                            device: otherTerminal,
                            executable: "/tmp/evil/ssh"
                        ),
                    ]
                )
            )
        )
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testASuspendedHerdrVerbOnTHISDeviceStillCompetes() throws {
        // Review round 5b, major 2, transposed: `ssh builder herdr attach`,
        // Ctrl+Z — the client is stopped but its server side is still attached
        // — then a plain `ssh builder` in the foreground of the SAME terminal.
        // `herdr attach` is not a shape the classifier knows, so it is a
        // possible different herdr view and still blocks; suspended
        // connections still count.
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
        XCTAssertTrue(
            value.hasCompetingHerdrClient,
            "a suspended possible herdr client to the same host still competes"
        )
    }

    func testAHerdrSiblingPaneOnTheSameDeviceCompetesWhenItsViewMayDiffer() throws {
        // Two process groups on one device (a terminal with split panes):
        // the sibling attaches a different named session, so it is a different
        // herdr view and blocks.
        let sibling = SSHClientProcess(
            pid: 888,
            ttyDevice: surface,
            processGroupID: 888,
            terminalForegroundGroupID: 501,
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder", "herdr", "--session", "scratch"]
        )
        let value = try XCTUnwrap(
            connection(probe(processes: [ssh(["ssh", "-t", "builder", "herdr"], pid: 501), sibling]))
        )
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testASuspendedBareHerdrClientOfTheSameServerDoesNotCompete() throws {
        // The narrowed rule's headline change on the round-5b SHAPE: a
        // suspended bare `ssh host herdr` next to a foreground bare
        // `ssh host herdr` is a second whole-view client of the SAME server —
        // a mirror — so it no longer blocks. (The VERB shape still does:
        // testASuspendedHerdrVerbOnTHISDeviceStillCompetes.)
        let suspendedMirror = SSHClientProcess(
            pid: 777,
            ttyDevice: surface,
            processGroupID: 777,
            terminalForegroundGroupID: 501, // the foreground client has the terminal
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder", "herdr"]
        )
        let value = try XCTUnwrap(
            connection(
                probe(processes: [ssh(["ssh", "-t", "builder", "herdr"], pid: 501), suspendedMirror])
            )
        )
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testAPlainShellSurfaceReportsCompetitionAgainstAHerdrNeighbor() throws {
        // Boundary pin, not a behavior anyone relies on: a `.notHerdr` surface
        // has no selector to compare, so a herdr neighbor reads as competing.
        // Harmless — the resolver refuses a `.notHerdr` surface before the
        // competition flag matters — but pinned so a refactor that flips it
        // ("a plain shell never competes with anything") is a deliberate
        // decision, not an accident.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "builder"], pid: 501),
                        ssh(["ssh", "builder", "herdr"], pid: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertEqual(value.herdr, .notHerdr)
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testAHerdrClientToADIFFERENTHostDoesNotCompete() throws {
        // Its herdr, if any, is another host's server — the candidates are
        // namespaced by the enrolled host and cannot name it.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "builder", "herdr"], pid: 501),
                        ssh(["ssh", "elsewhere", "herdr"], pid: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testAnUnreadableSSHElsewhereCompetes() throws {
        // A process we cannot read cannot be ruled out as a herdr client.
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
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testCrossUIDUnreadableSSHCompetesBeforeTheScanBoundaryAndIsThenIgnored() throws {
        // Historical behavior without the owner boundary: an unreadable ssh
        // from root or another user poisons the decision unconditionally.
        let unfiltered = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "builder", "herdr"], pid: 501),
                        ssh(nil, pid: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertTrue(unfiltered.hasCompetingHerdrClient)

        let processes = SSHDestinationTTYProbe.sshProcesses(
            from: [
                TTYProcessTable.Entry(
                    pid: 501,
                    effectiveUserID: 501,
                    name: "ssh",
                    ttyDevice: surface,
                    processGroupID: 501,
                    terminalForegroundGroupID: 501
                ),
                TTYProcessTable.Entry(
                    pid: 777,
                    effectiveUserID: 0,
                    name: "ssh",
                    ttyDevice: otherTerminal,
                    processGroupID: 777,
                    terminalForegroundGroupID: 777
                ),
            ],
            effectiveUserID: 501,
            readExecutablePath: { pid in
                if pid == 777 { XCTFail("cross-uid metadata must not be read") }
                return pid == 501 ? "/usr/bin/ssh" : nil
            },
            readArguments: { pid in
                if pid == 777 { XCTFail("cross-uid argv must not be read") }
                return pid == 501 ? ["ssh", "builder", "herdr"] : nil
            }
        )
        let filtered = try XCTUnwrap(connection(probe(processes: processes)))
        XCTAssertFalse(filtered.hasCompetingHerdrClient)
    }

    func testACrossUIDForegroundSSHOnTheSurfaceStillAbstains() {
        // `sudo ssh host` in THIS terminal's foreground: another user's
        // process IS the surface. It must abstain exactly as any unreadable
        // ssh does — reclassifying it as "no ssh here" would hand the surface
        // to the title-marker arm while a remote session may be on screen.
        // Its metadata must still never be read.
        let processes = SSHDestinationTTYProbe.sshProcesses(
            from: [
                TTYProcessTable.Entry(
                    pid: 777,
                    effectiveUserID: 0,
                    name: "ssh",
                    ttyDevice: surface,
                    processGroupID: 777,
                    terminalForegroundGroupID: 777
                )
            ],
            effectiveUserID: 501,
            readExecutablePath: { _ in
                XCTFail("cross-uid metadata must not be read")
                return nil
            },
            readArguments: { _ in
                XCTFail("cross-uid argv must not be read")
                return nil
            }
        )
        XCTAssertEqual(
            probe(processes: processes), .undeterminable(.untrustedExecutable)
        )
    }

    func testSameUIDUnreadableSSHStillCompetesAfterTheScanBoundary() throws {
        let processes = SSHDestinationTTYProbe.sshProcesses(
            from: [
                TTYProcessTable.Entry(
                    pid: 501,
                    effectiveUserID: 501,
                    name: "ssh",
                    ttyDevice: surface,
                    processGroupID: 501,
                    terminalForegroundGroupID: 501
                ),
                TTYProcessTable.Entry(
                    pid: 777,
                    effectiveUserID: 501,
                    name: "ssh",
                    ttyDevice: otherTerminal,
                    processGroupID: 777,
                    terminalForegroundGroupID: 777
                ),
            ],
            effectiveUserID: 501,
            readExecutablePath: { $0 == 501 ? "/usr/bin/ssh" : nil },
            readArguments: { $0 == 501 ? ["ssh", "builder", "herdr"] : nil }
        )
        let value = try XCTUnwrap(connection(probe(processes: processes)))
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testOurOwnTTYLessForwardDoesNotCompete() throws {
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
        XCTAssertFalse(value.hasCompetingHerdrClient)
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
            .undeterminable(.multipleForegroundClients)
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
        XCTAssertEqual(probe(processes: [first, second]), .undeterminable(.multipleForegroundClients))
    }

    func testTwoForegroundSSHClientsToDifferentHostsOnOneSurfaceAbstain() {
        XCTAssertEqual(
            probe(
                processes: [
                    ssh(["ssh", "builder"], pid: 501),
                    ssh(["ssh", "other"], pid: 502),
                ]
            ),
            .undeterminable(.multipleForegroundClients)
        )
    }

    func testARefusedOptionOnTheSurfaceClientReportsItsOwnCause() {
        // The categories exist because three field dictations were diagnosed
        // blind (2026-08-06): every branch collapsed into one word.
        XCTAssertEqual(
            probe(processes: [ssh(["ssh", "-o", "HostName=other", "builder"])]),
            .undeterminable(.refusedArguments)
        )
    }

    // MARK: - ProxyJump machinery (field abstention, 2026-08-06)

    /// The field shape verbatim: `Host sandbox-vpn` with `ProxyJump dell1`
    /// makes OpenSSH spawn `ssh -W [ip]:22 dell1` as a direct child on the
    /// SAME tty and in the SAME foreground process group. That child is the
    /// connection's transport, not a second connection — kernel ppid says so —
    /// and it must neither break the exactly-one surface rule nor the
    /// machine-wide uniqueness claim.
    private func proxyChild(
        pid: Int32,
        parent: Int32,
        device: dev_t? = 42,
        foregroundGroup: Int32? = nil
    ) -> SSHClientProcess {
        SSHClientProcess(
            pid: pid,
            parentPID: parent,
            ttyDevice: device,
            processGroupID: parent,
            terminalForegroundGroupID: foregroundGroup ?? parent,
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "-W", "[192.168.1.98]:22", "dell1"]
        )
    }

    func testAProxyJumpChildIsMachineryNotASecondSurfaceClient() throws {
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "-t", "sandbox-vpn", "herdr"], pid: 68369),
                        proxyChild(pid: 68370, parent: 68369),
                    ]
                )
            )
        )
        XCTAssertEqual(value.destination, "sandbox-vpn")
        XCTAssertEqual(value.herdr, .plainClient(sessionSelector: nil))
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testAMultiHopProxyChainIsEntirelyMachinery() throws {
        // `ProxyJump a,b` nests: the -W child spawns its own -W child.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "sandbox-vpn", "herdr"], pid: 501),
                        proxyChild(pid: 502, parent: 501),
                        // One device has ONE foreground pgid; what this test
                        // pins is parent-chain demotion, not foreground
                        // semantics, so the grandchild reports the same one.
                        proxyChild(pid: 503, parent: 502, foregroundGroup: 501),
                    ]
                )
            )
        )
        XCTAssertEqual(value.destination, "sandbox-vpn")
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testAnotherTerminalsProxyChildDoesNotCompete() throws {
        // A second terminal to a DIFFERENT host over its own jump: its root is
        // parsed (destination `elsewhere`, no match) and its unreadable -W
        // child is that root's machinery, not an unreadable connection.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "sandbox-vpn", "herdr"], pid: 501),
                        ssh(["ssh", "elsewhere"], pid: 777, device: otherTerminal),
                        proxyChild(pid: 778, parent: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertFalse(value.hasCompetingHerdrClient)
    }

    func testACompetingRootStillCompetesDespiteItsOwnProxyChild() throws {
        // The machinery rule must not swallow the root it serves: the other
        // terminal's root attaches a different named session, and its -W
        // child changes nothing about that.
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "sandbox-vpn", "herdr"], pid: 501),
                        ssh(
                            ["ssh", "sandbox-vpn", "herdr", "--session", "scratch"],
                            pid: 777,
                            device: otherTerminal
                        ),
                        proxyChild(pid: 778, parent: 777, device: otherTerminal),
                    ]
                )
            )
        )
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testAnOrphanedUnreadableSSHElsewhereStillCompetes() throws {
        // A tty-holding ssh whose parent is NOT an ssh (launchd after a
        // reparent, a shell-mediated ProxyCommand) is still a root, and an
        // unreadable root still cannot be ruled out — the paranoia is
        // unchanged.
        let orphan = SSHClientProcess(
            pid: 777,
            parentPID: 1, // reparented to launchd — a REAL orphan's e_ppid
            ttyDevice: otherTerminal,
            processGroupID: 777,
            terminalForegroundGroupID: 777,
            executablePath: "/usr/bin/ssh",
            arguments: nil
        )
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "sandbox-vpn", "herdr"], pid: 501),
                        orphan,
                    ]
                )
            )
        )
        XCTAssertTrue(value.hasCompetingHerdrClient)
    }

    func testSiblingForegroundClientsAreNotMachineryAndStillAbstain() {
        // The round-7 review case must survive the machinery rule: a wrapper
        // launching two ssh SIBLINGS in one foreground group has no ssh
        // parent on either, so both are connections and neither answers.
        let first = SSHClientProcess(
            pid: 601,
            parentPID: 600, // a shell, not in the ssh scan
            ttyDevice: surface,
            processGroupID: 600,
            terminalForegroundGroupID: 600,
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder", "herdr"]
        )
        let second = SSHClientProcess(
            pid: 602,
            parentPID: 600,
            ttyDevice: surface,
            processGroupID: 600,
            terminalForegroundGroupID: 600,
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh", "builder"]
        )
        XCTAssertEqual(
            probe(processes: [first, second]),
            .undeterminable(.multipleForegroundClients)
        )
    }

    // MARK: - herdr connection signal (review blocker 1b)

    func testABareHerdrRemoteCommandBindsTheConnectionAsAWholeViewClient() throws {
        let value = try XCTUnwrap(
            connection(probe(processes: [ssh(["ssh", "-t", "builder", "herdr"])]))
        )
        XCTAssertEqual(value.herdr, .plainClient(sessionSelector: nil))
    }

    func testAHerdrSubcommandOnTheSurfaceIsClassifiedAsOther() throws {
        // `herdr terminal attach <id>` renders exactly ONE pane while the join
        // reads the server's GLOBAL focus — a mis-join the boolean signal
        // allowed (memo 2026-08-06). The classification refuses every shape
        // that is not the whole-view client.
        let attach = try XCTUnwrap(
            connection(
                probe(processes: [ssh(["ssh", "builder", "herdr", "terminal", "attach", "w1:p3"])])
            )
        )
        XCTAssertEqual(attach.herdr, .otherHerdrSubcommand)

        let unknownVerb = try XCTUnwrap(
            connection(probe(processes: [ssh(["ssh", "-t", "builder", "herdr", "attach"])]))
        )
        XCTAssertEqual(unknownVerb.herdr, .otherHerdrSubcommand)
    }

    func testASessionSelectorOnTheSurfaceIsCarried() throws {
        let value = try XCTUnwrap(
            connection(
                probe(processes: [ssh(["ssh", "-t", "builder", "herdr", "--session", "scratch"])])
            )
        )
        XCTAssertEqual(value.herdr, .plainClient(sessionSelector: "scratch"))
    }

    func testHerdrCommandClassification() {
        typealias Probe = SSHDestinationTTYProbe
        XCTAssertEqual(Probe.classifyHerdrCommand([]), .notHerdr)
        XCTAssertEqual(Probe.classifyHerdrCommand(["ls"]), .notHerdr)
        XCTAssertEqual(Probe.classifyHerdrCommand(["herdr"]), .plainClient(sessionSelector: nil))
        XCTAssertEqual(
            Probe.classifyHerdrCommand(["/usr/local/bin/herdr"]),
            .plainClient(sessionSelector: nil)
        )
        XCTAssertEqual(
            Probe.classifyHerdrCommand(["herdr", "--session", "scratch"]),
            .plainClient(sessionSelector: "scratch")
        )
        XCTAssertEqual(
            Probe.classifyHerdrCommand(["herdr", "--session=scratch"]),
            .plainClient(sessionSelector: "scratch")
        )
        // A selector we cannot compare byte-identically, and every verb —
        // known or unknown — refuses.
        XCTAssertEqual(Probe.classifyHerdrCommand(["herdr", "--session"]), .otherHerdrSubcommand)
        // Repeated --session is refused, not resolved: which occurrence herdr
        // honors is herdr's business, and silently picking one lets the
        // classifier agree with itself while disagreeing with herdr.
        XCTAssertEqual(
            Probe.classifyHerdrCommand(["herdr", "--session", "a", "--session", "b"]),
            .otherHerdrSubcommand
        )
        XCTAssertEqual(Probe.classifyHerdrCommand(["herdr", "--session="]), .otherHerdrSubcommand)
        XCTAssertEqual(Probe.classifyHerdrCommand(["herdr", "server"]), .otherHerdrSubcommand)
        XCTAssertEqual(
            Probe.classifyHerdrCommand(["herdr", "session", "attach", "x"]), .otherHerdrSubcommand
        )
        XCTAssertEqual(
            Probe.classifyHerdrCommand(["herdr", "terminal", "session", "observe", "t1"]),
            .otherHerdrSubcommand
        )
    }

    func testMentionsHerdrIsSubstringBased() {
        // For refused-argv neighbors only: `sh -lc 'exec herdr'` arrives as
        // one token, and this test must only ever err toward blocking.
        XCTAssertTrue(SSHDestinationTTYProbe.mentionsHerdr(["ssh", "-o", "X", "b", "herdr"]))
        XCTAssertTrue(
            SSHDestinationTTYProbe.mentionsHerdr(["ssh", "-o", "X", "b", "sh", "-lc", "exec herdr"])
        )
        XCTAssertFalse(SSHDestinationTTYProbe.mentionsHerdr(["ssh", "-o", "Compression=yes", "b"]))
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
        XCTAssertEqual(value.herdr, .notHerdr)
    }

    func testAPlainShellConnectionDoesNotIndicateHerdr() throws {
        let value = try XCTUnwrap(connection(probe(processes: [ssh(["ssh", "builder"])])))
        XCTAssertEqual(value.herdr, .notHerdr)
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

    func testDestinationInertOOptionsAreSkippedInEveryArgvShape() {
        XCTAssertEqual(destination(["ssh", "-o", "SetEnv=TERM=xterm-ghostty", "builder"]), "builder")
        XCTAssertEqual(destination(["ssh", "-oSeNdEnV=COLORTERM", "builder"]), "builder")
        XCTAssertEqual(destination(["ssh", "-to", "SendEnv=TERM_PROGRAM", "builder"]), "builder")
        XCTAssertEqual(destination(["ssh", "-toSetEnv=TERM=xterm-ghostty", "builder"]), "builder")
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
            ["ssh", "-o", "Compression=yes", "builder"],
            ["ssh", "-oSetEnvironment=TERM=xterm-ghostty", "builder"],
            ["ssh", "-to", "HostName=other.example", "builder"],
            ["ssh", "-toCompression=yes", "builder"],
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
        XCTAssertEqual(
            me?.parentProcessID, getppid(),
            "the parent pid must be plumbed — the machinery rule depends on it"
        )
        XCTAssertEqual(
            me?.effectiveUserID, geteuid(),
            "the effective uid must come from the kernel process-table entry"
        )
    }

    func testTheLiveExecutablePathOfThisProcessResolves() throws {
        let path = try XCTUnwrap(SSHDestinationTTYProbe.executablePath(pid: getpid()))
        XCTAssertTrue(path.hasPrefix("/"), "got \(path)")
    }

    func testTheLiveArgumentsOfThisProcessResolve() throws {
        let arguments = try XCTUnwrap(SSHDestinationTTYProbe.processArguments(pid: getpid()))
        XCTAssertFalse(arguments.isEmpty)
    }

    // MARK: - Sockets and jump hosts (the plain-ssh arm's inputs)

    func testTheSurfaceConnectionCarriesTheSocketsOfTheSurfaceProcessOnly() throws {
        let recorder = SocketReadRecorder()
        let socket = SSHClientSocket(
            localPort: 51_960, peerPort: 22, peerAddress: "192.168.1.9"
        )
        let value = try XCTUnwrap(
            connection(
                probe(
                    processes: [
                        ssh(["ssh", "sandbox"], pid: 501),
                        // Another terminal's connection. Its sockets are not
                        // this surface's and must never be read.
                        ssh(["ssh", "sandbox"], pid: 777, device: otherTerminal),
                    ],
                    sockets: [
                        501: [socket],
                        777: [SSHClientSocket(
                            localPort: 40_000, peerPort: 22, peerAddress: "192.168.1.9"
                        )],
                    ],
                    socketReads: recorder
                )
            )
        )
        XCTAssertEqual(value.sockets, [socket])
        XCTAssertEqual(recorder.pids, [501], "only the surface process may be read")
    }

    func testAnUnreadableSocketTableStaysNilRatherThanBecomingAnEmptyList() throws {
        // The whole reason the field is optional: nil is "could not read", and
        // the arm that consumes it abstains on nil while an empty list is a
        // positive claim about the process.
        let value = try XCTUnwrap(
            connection(probe(processes: [ssh(["ssh", "sandbox"], pid: 501)], sockets: [:]))
        )
        XCTAssertNil(value.sockets)
    }

    func testTheProbeDefaultsToNoSocketReadAtAll() throws {
        // The seam default must not reach the kernel: a caller that has no
        // business with sockets, and a test that forgets to inject, both get
        // "unreadable".
        let processes = [ssh(["ssh", "sandbox"], pid: 501)]
        let value = try XCTUnwrap(
            connection(
                SSHDestinationTTYProbe.connection(
                    onTTYDevicePath: "/dev/ttys003",
                    deviceID: { _ in 42 },
                    sshProcesses: { processes }
                )
            )
        )
        XCTAssertNil(value.sockets)
    }

    func testAJumpHostIsRecordedRatherThanRefused() throws {
        // `-J` still parses — the herdr arm has always accepted it and never
        // looks at a socket. Only the plain-ssh arm, which compares ports
        // across the connection, has to refuse it.
        for argv in [
            ["ssh", "-J", "bastion", "sandbox"],
            ["ssh", "-Jbastion", "sandbox"],
            ["ssh", "-tJ", "bastion", "sandbox"],
            ["ssh", "-4J", "bastion", "sandbox"],
        ] {
            let value = try XCTUnwrap(connection(probe(processes: [ssh(argv)])), "\(argv)")
            XCTAssertEqual(value.destination, "sandbox", "\(argv)")
            XCTAssertTrue(value.usesProxyJump, "\(argv)")
        }
    }

    func testAnOrdinaryConnectionDoesNotClaimAJumpHost() throws {
        for argv in [
            ["ssh", "sandbox"],
            ["ssh", "-t", "sandbox"],
            // A `J` inside another option's glued ARGUMENT is not an option
            // letter: the walk stops at the first argument-taking letter.
            ["ssh", "-i/tmp/J", "sandbox"],
            ["ssh", "-p22", "sandbox"],
        ] {
            let value = try XCTUnwrap(connection(probe(processes: [ssh(argv)])), "\(argv)")
            XCTAssertFalse(value.usesProxyJump, "\(argv)")
        }
    }

    func testProxyJumpDetectionWalksAnOptionClusterTheSameWayConsumptionDoes() {
        XCTAssertTrue(SSHDestinationTTYProbe.namesProxyJump(optionToken: "-J"))
        XCTAssertTrue(SSHDestinationTTYProbe.namesProxyJump(optionToken: "-Jbastion"))
        XCTAssertTrue(SSHDestinationTTYProbe.namesProxyJump(optionToken: "-tJ"))
        XCTAssertFalse(SSHDestinationTTYProbe.namesProxyJump(optionToken: "-t"))
        XCTAssertFalse(SSHDestinationTTYProbe.namesProxyJump(optionToken: "-pJ"))
        XCTAssertFalse(SSHDestinationTTYProbe.namesProxyJump(optionToken: "-"))
    }

}
#endif
