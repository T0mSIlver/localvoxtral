import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore

#if canImport(Darwin) || canImport(Glibc)

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

    // MARK: - ssh:// URI destinations (herdr machine targets)

    func testSSHURIDestinationShapeTable() {
        let accepted = [
            "ssh://build.example",
            "ssh://build.example:2222",
            // Ports compare numerically: `ssh -G` parses `:00022` as 22.
            "ssh://build.example:00022",
            "ssh://dev@build.example",
            "ssh://dev@build.example:2222",
            "ssh://build.example:22",
            // A username may contain an `@`; the split is on the last one.
            "ssh://dev@box@build.example",
            // herdr's own catalog test fixtures include IPv6 literals.
            "ssh://dev@[::1]:2222",
            "ssh://[2001:db8::1]",
        ]
        for operand in accepted {
            XCTAssertTrue(
                SSHDestinationCanonicalizer.isSSHURIDestination(operand),
                "\(operand) should be accepted"
            )
        }

        let refused = [
            "",
            "build.example",
            "dev@build.example",
            // A password in the userinfo is herdr's own refusal.
            "ssh://dev:secret@build.example",
            "ssh://@build.example",
            // herdr's `--remote` rule, mirrored: never start with `-`.
            "ssh://-oProxyCommand=x@build.example",
            // Whitespace and control characters cannot occur in a username
            // ssh would honor, but they CAN shape what `ssh -G` evaluates.
            "ssh://a b@build.example",
            "ssh://a\tb@build.example",
            "ssh://a\n@build.example",
            "ssh://a\u{7}@build.example",
            // `/ ? #` would start a path, query, or fragment — none of which
            // is a destination.
            "ssh://a/b@build.example",
            "ssh://a?b@build.example",
            "ssh://a#b@build.example",
            // No path, query, or fragment is a destination.
            "ssh://build.example/workspace",
            "ssh://build.example?x=1",
            "ssh://build.example#frag",
            // A second colon is not a port.
            "ssh://build.example:22:22",
            "ssh://build.example:nope",
            "ssh://build.example:0",
            // Only the ssh scheme; anything else keeps the blanket refusal.
            "http://build.example",
            "ssh6://build.example",
            "ssh:///no-host",
            "ssh://[::1",
        ]
        for operand in refused {
            XCTAssertFalse(
                SSHDestinationCanonicalizer.isSSHURIDestination(operand),
                "\(operand) should be refused"
            )
        }
    }

    func testAHerdrURITargetCanonicalizesAgainstEnrolledAliases() async {
        // The exact target herdr's own catalog tests store: an `ssh://` URI
        // with user and port. `ssh -G` parses URIs natively (verified on
        // OpenSSH 10.0: hostname and port come back decoded), so the URI
        // operand reaches the runner verbatim and matches on the decoded
        // (hostname, port) alone.
        let runner = CanonicalizerRecordingRunner(outputs: [
            "ssh://dev@build.example:2222": output(hostname: "build.example", port: 2222),
            "buildbox": output(hostname: "build.example", port: 2222),
        ])
        let canonicalizer = SSHDestinationCanonicalizer(
            now: { [epoch] in epoch },
            runner: runner.run
        )

        let matches = await canonicalizer.matchingHosts(
            destination: "ssh://dev@build.example:2222",
            enrolledHosts: [host(alias: "buildbox")]
        )

        XCTAssertEqual(matches.map(\.sshHostAlias), ["buildbox"])
        XCTAssertEqual(
            Set(runner.calls.withLock { $0.map(\.invocation.argv) }),
            [
                ["ssh", "-G", "--", "ssh://dev@build.example:2222"],
                ["ssh", "-G", "--", "buildbox"],
            ]
        )
    }
}

#endif
