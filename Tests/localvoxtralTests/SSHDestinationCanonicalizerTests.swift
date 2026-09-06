import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

#if canImport(Darwin)

private final class CanonicalizerTestClock: Sendable {
    private let value: Mutex<Date>

    init(_ value: Date) { self.value = Mutex(value) }
    var now: @Sendable () -> Date { { [self] in value.withLock { $0 } } }
    func advance(_ interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

private final class CanonicalizerRecordingRunner: @unchecked Sendable {
    struct Call: Equatable {
        let executableURL: URL
        let invocation: ClaudeRemoteEnrollmentService.Invocation
    }

    let calls = Mutex<[Call]>([])
    private let outputs: [String: String]

    init(outputs: [String: String]) { self.outputs = outputs }

    var run: SSHDestinationCanonicalizer.ProcessRunner {
        { [self] executableURL, invocation in
            calls.withLock { $0.append(Call(executableURL: executableURL, invocation: invocation)) }
            guard let operand = invocation.argv.last, let output = outputs[operand] else {
                return ClaudeRemoteEnrollmentService.RunResult(exitCode: 1, message: "")
            }
            return ClaudeRemoteEnrollmentService.RunResult(exitCode: 0, message: output)
        }
    }
}

final class SSHDestinationCanonicalizerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func host(alias: String) -> ClaudeRemoteHost {
        ClaudeRemoteHost(
            id: "h1a2b3c4",
            label: "sandbox",
            sshHostAlias: alias,
            createdAt: epoch,
            lastSeenAt: nil,
            revokedAt: nil
        )
    }

    private func output(hostname: String, user: String? = "dev", port: Int = 22) -> String {
        [
            "host ignored",
            user.map { "user \($0)" },
            "hostname \(hostname)",
            "port \(port)",
            "compression no",
        ].compactMap { $0 }.joined(separator: "\n")
    }

    func testParserReadsEffectiveHostnameUserAndPort() {
        XCTAssertEqual(
            SSHDestinationCanonicalizer.parse(
                "host sandbox\nuser deploy\nhostname Build.Example.COM\nport 2202\n"
            ),
            SSHDestinationCanonicalizer.Identity(
                hostname: "build.example.com", port: 2202, user: "deploy"
            )
        )
        XCTAssertNil(SSHDestinationCanonicalizer.parse("hostname host.example\nport nope\n"))
        XCTAssertNil(SSHDestinationCanonicalizer.parse("user dev\nport 22\n"))
    }

    func testRefusedOperandNeverReachesProcessRunner() async {
        let runner = CanonicalizerRecordingRunner(outputs: [:])
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let matches = await canonicalizer.matchingHosts(
            destination: "bad;touch-pwned",
            enrolledHosts: [host(alias: "sandbox-vpn")]
        )

        XCTAssertTrue(matches.isEmpty)
        XCTAssertTrue(runner.calls.withLock { $0.isEmpty })
    }

    func testAnAliasWithItsOwnUserStillMatchesAnIPOperand() async {
        // The field shape this fallback exists for: `ssh 192.168.1.167 herdr`
        // against an enrollment whose config says `Host sandbox-vpn` +
        // `HostName 192.168.1.167` + `User builder`. Real `ssh -G` ALWAYS
        // prints a `user` line — the operand side gets the local default
        // ("dev"), the alias side gets the configured one ("builder") — so a
        // user comparison would falsely reject exactly this case.
        let runner = CanonicalizerRecordingRunner(outputs: [
            "address": output(hostname: "BOX.EXAMPLE", user: "dev"),
            "sandbox-vpn": output(hostname: "box.example", user: "builder"),
        ])
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let matches = await canonicalizer.matchingHosts(
            destination: "address",
            enrolledHosts: [host(alias: "sandbox-vpn")]
        )

        XCTAssertEqual(matches.map(\.sshHostAlias), ["sandbox-vpn"])
    }

    func testTwoEnrollmentsToOneBoxUnderDifferentUsersBothMatch() async {
        // Different remote accounts on one (hostname, port) are
        // indistinguishable from here — the operand's `user@` was stripped
        // upstream. Both enrollments must be reported so the join's existing
        // multiple-match rule abstains, rather than this type guessing.
        let runner = CanonicalizerRecordingRunner(outputs: [
            "address": output(hostname: "box.example", user: "dev"),
            "alias-alice": output(hostname: "box.example", user: "alice"),
            "alias-bob": output(hostname: "box.example", user: "bob"),
        ])
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let matches = await canonicalizer.matchingHosts(
            destination: "address",
            enrolledHosts: [host(alias: "alias-alice"), host(alias: "alias-bob")]
        )

        XCTAssertEqual(matches.count, 2)
    }

    func testOneUnresolvableEnrolledAliasRejectsAllCanonicalMatches() async {
        let config = output(hostname: "box.example")
        let runner = CanonicalizerRecordingRunner(outputs: [
            "address": config,
            "working-alias": config,
        ])
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let matches = await canonicalizer.matchingHosts(
            destination: "address",
            enrolledHosts: [host(alias: "working-alias"), host(alias: "broken-alias")]
        )

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(runner.calls.withLock { $0.count }, 3)
    }

    func testCacheUsesInjectedClockAndExpiresAtTTL() async {
        let clock = CanonicalizerTestClock(epoch)
        let config = output(hostname: "192.168.1.167")
        let runner = CanonicalizerRecordingRunner(outputs: [
            "192.168.1.167": config,
            "sandbox-vpn": config,
        ])
        let canonicalizer = SSHDestinationCanonicalizer(
            ttl: 300,
            now: clock.now,
            runner: runner.run
        )
        let hosts = [host(alias: "sandbox-vpn")]

        _ = await canonicalizer.matchingHosts(
            destination: "192.168.1.167", enrolledHosts: hosts
        )
        _ = await canonicalizer.matchingHosts(
            destination: "192.168.1.167", enrolledHosts: hosts
        )
        XCTAssertEqual(runner.calls.withLock { $0.count }, 2)

        clock.advance(301)
        _ = await canonicalizer.matchingHosts(
            destination: "192.168.1.167", enrolledHosts: hosts
        )
        XCTAssertEqual(runner.calls.withLock { $0.count }, 4)
    }
    // MARK: - ProxyJump, as a shape

    /// `ssh -G` is the only place the app can learn that a destination is
    /// routed through a jump host: `ProxyJump` lives in `~/.ssh/config` and is
    /// invisible in the ssh client's argv. Getting this wrong costs an
    /// abstention that blames the wrong thing — which is what the field saw
    /// (2026-09-06).
    func testProxyJumpIsParsedAsAShapeAndNeverAsAHostName() {
        let cases: [(String, SSHProxyJumpShape)] = [
            ("", .none),
            ("none", .none),
            ("None", .none),
            ("dell1", .singleHop),
            ("user@dell1:2222", .singleHop),
            ("  dell1  ", .singleHop),
            ("a,b", .chain),
            ("a,b,c", .chain),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(
                SSHProxyJumpShape(configuredValue: value), expected, "proxyjump \(value)"
            )
        }
    }

    func testTheParserCarriesTheProxyJumpShapeOffRealSSHGOutput() throws {
        // Verbatim `ssh -G` lines: the key is lowercase and the value is the
        // rest of the line, exactly as OpenSSH prints it (measured against
        // OpenSSH 9.x, 2026-09-06: `ssh -G -o ProxyJump=dell1 host` prints
        // `proxyjump dell1`; an unset ProxyJump prints NO line at all).
        let direct = try XCTUnwrap(SSHDestinationCanonicalizer.parse("""
        hostname 192.168.1.98
        port 22
        user dev
        """))
        XCTAssertEqual(direct.proxyJump, .none, "no line means no jump host")

        let jumped = try XCTUnwrap(SSHDestinationCanonicalizer.parse("""
        hostname 192.168.1.98
        port 22
        user dev
        proxyjump dell1
        """))
        XCTAssertEqual(jumped.proxyJump, .singleHop)

        let chained = try XCTUnwrap(SSHDestinationCanonicalizer.parse("""
        hostname 192.168.1.98
        port 22
        proxyjump a,b
        """))
        XCTAssertEqual(chained.proxyJump, .chain)

        // And it changes NOTHING about identity matching, which is what the
        // enrolled-host fallback compares.
        XCTAssertTrue(direct.matches(jumped))
    }

}

#endif
