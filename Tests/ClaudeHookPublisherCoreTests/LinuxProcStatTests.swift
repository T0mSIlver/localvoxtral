@testable import ClaudeHookPublisherCore
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The Linux process-table reader. Parsing runs everywhere; the live `/proc`
/// reads run on Linux only.
final class LinuxProcStatTests: XCTestCase {
    // A shell on /dev/pts/3: tty_nr 34819 is major 136, minor 3.
    private let bashLine = "4242 (bash) S 4100 4242 4242 34819 4300 4194304 1200 0 0 0 3 1 0 0 20 0 1 0 987654 9000000 1200 18446744073709551615 0 0 0 0 0 0 65536 3686404 1266761467 0 0 0 17 2 0 0 0 0 0"

    func testParsesTheFieldsTheDarwinPathReadsFromKinfoProc() {
        XCTAssertEqual(
            LinuxProcStat.parse(bashLine),
            LinuxProcStat(pid: 4242, parent: 4100, session: 4242, ttyNumber: 34819, startTicks: 987654)
        )
    }

    func testACommandNameWithSpacesAndParenthesesDoesNotShiftTheFields() {
        let line = bashLine.replacingOccurrences(of: "(bash)", with: "(a) b (c))")
        XCTAssertEqual(LinuxProcStat.parse(line)?.parent, 4100)
        XCTAssertEqual(LinuxProcStat.parse(line)?.startTicks, 987654)
    }

    func testTruncatedOrGarbageLinesAreRefused() {
        XCTAssertNil(LinuxProcStat.parse(""))
        XCTAssertNil(LinuxProcStat.parse("4242 (bash) S 4100 4242"))
        XCTAssertNil(LinuxProcStat.parse("x (bash) S 4100 4242 4242 34819"))
    }

    func testPseudoTerminalNumbersDecodeToTheirPtsPath() {
        XCTAssertEqual(LinuxProcStat.ptsPath(ttyNumber: 34819), "/dev/pts/3")
        XCTAssertEqual(LinuxProcStat.ptsPath(ttyNumber: 136 << 8), "/dev/pts/0")
        // Minor 300: the low byte in bits 0-7, the rest from bit 20 up.
        XCTAssertEqual(LinuxProcStat.ptsPath(ttyNumber: (136 << 8) | 44 | (1 << 20)), "/dev/pts/300")
    }

    func testAPtsIndexWithBit19SetDecodesFromTheSignedValueProcPrints() {
        // pts 524288: minor bit 19 lands in bit 31 of tty_nr, which /proc
        // prints as a negative Int32.
        XCTAssertEqual(LinuxProcStat.ptsPath(ttyNumber: -2_147_448_832), "/dev/pts/524288")
    }

    func testNoTerminalOrANonPtyTerminalNamesNoDevice() {
        XCTAssertNil(LinuxProcStat.ptsPath(ttyNumber: 0))
        XCTAssertNil(LinuxProcStat.ptsPath(ttyNumber: (4 << 8) | 1)) // /dev/tty1, a virtual console
    }

    func testStartTimeIsMicrosecondsSinceTheEpoch() {
        let procStat = "cpu  1 2 3\nintr 5\nbtime 1758600000\nprocesses 42\n"
        XCTAssertEqual(LinuxProcStat.bootTimeSeconds(procStat: procStat), 1_758_600_000)
        XCTAssertNil(LinuxProcStat.bootTimeSeconds(procStat: "cpu 1\n"))
        XCTAssertEqual(
            LinuxProcStat.startMicros(startTicks: 250, bootTimeSeconds: 1_758_600_000, ticksPerSecond: 100),
            1_758_600_002_500_000
        )
        XCTAssertNil(LinuxProcStat.startMicros(startTicks: 250, bootTimeSeconds: 1_758_600_000, ticksPerSecond: 0))
    }

    func testProcessTableLookupRefusesInvalidPIDs() {
        XCTAssertNil(ClaudeHookPublisher.ttyDevicePath(forProcess: 0))
        XCTAssertNil(ClaudeHookPublisher.processFacts(forProcess: 0))
    }

    #if os(Linux)
    func testOwnEntryAgreesWithTheSyscalls() throws {
        let stat = try XCTUnwrap(LinuxProcStat.read(pid: getpid()))
        XCTAssertEqual(stat.parent, getppid())
        XCTAssertEqual(stat.session, getsid(0))

        let facts = try XCTUnwrap(ClaudeHookPublisher.processFacts(forProcess: getpid()))
        XCTAssertEqual(facts.parent, getppid())
        XCTAssertEqual(facts.session, getsid(0))
        XCTAssertNotNil(facts.startMicros)
        // A Vibe session's id is built from this value: two reads must agree.
        XCTAssertEqual(ClaudeHookPublisher.processFacts(forProcess: getpid())?.startMicros, facts.startMicros)
    }

    func testControllingTTYAgreesWithItsOwnProcessTableEntry() {
        // Same invariant as the Mac suite: a pty-attached shell, piped output
        // and a terminal-less runner each give one answer on both sides.
        XCTAssertEqual(
            ClaudeHookPublisher.controllingTTY(claudePID: getpid()),
            ClaudeHookPublisher.ttyDevicePath(forProcess: getpid())
        )
    }
    #endif
}
