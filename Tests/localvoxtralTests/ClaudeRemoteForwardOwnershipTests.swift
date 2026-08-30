import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// The discriminator behind `externallyForwarded`.
///
/// Every case here is about one question: what is allowed to convince this Mac
/// that a port it could not bind is nevertheless its own tunnel. The answer has
/// to be "a nonce we minted, arriving on our own listener", and nothing else —
/// because the alternative reading of a refused bind is a stranger who is
/// receiving the remote plugin's bearer token on every hook.
final class ClaudeRemoteForwardOwnershipTests: XCTestCase {

    // MARK: - The witness

    func testAnArmedNonceIsObservedOnce() {
        let witness = ClaudeRemoteForwardProbeWitness()
        let nonce = ClaudeRemoteForwardProbeWitness.randomNonce()
        witness.arm(nonce)
        XCTAssertTrue(witness.note(headerValue: nonce))
        XCTAssertTrue(witness.consume(nonce))
        // Consumed means disarmed: a replay after the probe finished proves
        // nothing about the topology NOW.
        XCTAssertFalse(witness.note(headerValue: nonce))
        XCTAssertFalse(witness.consume(nonce))
        XCTAssertEqual(witness.armedCount, 0)
    }

    func testNothingButAnArmedNonceMatches() {
        let witness = ClaudeRemoteForwardProbeWitness()
        let nonce = ClaudeRemoteForwardProbeWitness.randomNonce()
        witness.arm(nonce)
        XCTAssertFalse(witness.note(headerValue: nil))
        XCTAssertFalse(witness.note(headerValue: ""))
        XCTAssertFalse(witness.note(headerValue: String(nonce.dropLast())))
        XCTAssertFalse(witness.note(headerValue: nonce + "0"))
        XCTAssertFalse(witness.note(headerValue: nonce.uppercased()))
        XCTAssertFalse(
            witness.consume(nonce), "none of those may count as the probe arriving"
        )
    }

    func testANonceThatWasNeverArmedIsNeverObserved() {
        let witness = ClaudeRemoteForwardProbeWitness()
        let nonce = ClaudeRemoteForwardProbeWitness.randomNonce()
        XCTAssertFalse(witness.note(headerValue: nonce))
        XCTAssertFalse(witness.consume(nonce))
    }

    func testArmedNoncesAreBounded() {
        let witness = ClaudeRemoteForwardProbeWitness()
        let nonces = (0..<(ClaudeRemoteForwardProbeWitness.maximumArmed + 3)).map { _ in
            ClaudeRemoteForwardProbeWitness.randomNonce()
        }
        for nonce in nonces { witness.arm(nonce) }
        XCTAssertEqual(witness.armedCount, ClaudeRemoteForwardProbeWitness.maximumArmed)
        XCTAssertFalse(
            witness.note(headerValue: nonces[0]), "the oldest entries are evicted, not kept"
        )
        XCTAssertTrue(witness.note(headerValue: nonces[nonces.count - 1]))
    }

    func testNoncesAreLongRandomHex() {
        let first = ClaudeRemoteForwardProbeWitness.randomNonce()
        let second = ClaudeRemoteForwardProbeWitness.randomNonce()
        XCTAssertEqual(first.count, 32, "128 bits, hex")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: - The probe

    private final class RunnerSpy: Sendable {
        struct Call: Sendable {
            var argv: [String]
            var standardInput: String
            var timeout: TimeInterval
        }

        private let calls = Mutex<[Call]>([])
        private let body: @Sendable (Call) throws -> ClaudeRemoteEnrollmentService.RunResult

        init(
            body: @escaping @Sendable (Call) throws -> ClaudeRemoteEnrollmentService.RunResult = {
                _ in ClaudeRemoteEnrollmentService.RunResult(exitCode: 0, message: "")
            }
        ) {
            self.body = body
        }

        var recorded: [Call] { calls.withLock { $0 } }

        var runner: ClaudeRemoteEnrollmentService.Runner {
            { invocation in
                let call = Call(
                    argv: invocation.argv,
                    standardInput: String(decoding: invocation.standardInput, as: UTF8.self),
                    timeout: invocation.timeout
                )
                self.calls.withLock { $0.append(call) }
                return try self.body(call)
            }
        }
    }

    /// THE case. A process on the remote host binds the port and answers the
    /// probe perfectly — our exact 401, our headers, whatever it likes, because
    /// all of that is public in this repository. It still cannot deliver the
    /// nonce to a listener bound to 127.0.0.1 on this Mac, and so it is never
    /// adopted as a context channel.
    func testAHostThatAnswersButCannotDeliverTheNonceIsNotOurs() async throws {
        let witness = ClaudeRemoteForwardProbeWitness()
        let spy = RunnerSpy()
        let probe = ClaudeRemoteForwardOwnershipCheck.live(
            witness: witness, runner: spy.runner
        )

        let ownership = await probe("builder", 28511)

        XCTAssertEqual(ownership, .unproved)
        XCTAssertEqual(spy.recorded.count, 1, "the probe did run; its ANSWER is what is ignored")
        XCTAssertEqual(witness.armedCount, 0, "the nonce is disarmed either way")
    }

    /// The forward is real, so the request lands here. The fake runner plays the
    /// tunnel: it takes the nonce out of the script it was handed and delivers
    /// it to the witness, exactly as the listener does on arrival.
    func testANonceThatArrivesOnOurListenerProvesTheForwardIsOurs() async throws {
        let witness = ClaudeRemoteForwardProbeWitness()
        let spy = RunnerSpy(body: { call in
            let header = "\(ClaudeRemoteForwardProbeWitness.headerName): "
            guard let range = call.standardInput.range(of: header) else {
                return ClaudeRemoteEnrollmentService.RunResult(exitCode: 7, message: "")
            }
            let nonce = call.standardInput[range.upperBound...].prefix { $0.isHexDigit }
            witness.note(headerValue: String(nonce))
            return ClaudeRemoteEnrollmentService.RunResult(exitCode: 0, message: "")
        })
        let probe = ClaudeRemoteForwardOwnershipCheck.live(
            witness: witness, runner: spy.runner
        )

        let ownership = await probe("builder", 28511)

        XCTAssertEqual(ownership, .ourListener)
        XCTAssertEqual(witness.armedCount, 0)
    }

    /// The exit status is not the signal, in either direction: a curl that
    /// failed after the request landed must not undo a delivered nonce.
    func testDeliveryWinsOverANonZeroExitStatus() async throws {
        let witness = ClaudeRemoteForwardProbeWitness()
        let spy = RunnerSpy(body: { call in
            let header = "\(ClaudeRemoteForwardProbeWitness.headerName): "
            let range = try XCTUnwrap(call.standardInput.range(of: header))
            let nonce = call.standardInput[range.upperBound...].prefix { $0.isHexDigit }
            witness.note(headerValue: String(nonce))
            throw ClaudeRemoteEnrollmentService.RunnerFailure.timedOut(
                seconds: 10, message: "ssh timed out"
            )
        })
        let probe = ClaudeRemoteForwardOwnershipCheck.live(
            witness: witness, runner: spy.runner
        )

        let ownership = await probe("builder", 28511)
        XCTAssertEqual(ownership, .ourListener)
        XCTAssertEqual(spy.recorded.count, 1)
    }

    func testAFailedProbeIsUnproved() async throws {
        let witness = ClaudeRemoteForwardProbeWitness()
        let spy = RunnerSpy(body: { _ in
            throw ClaudeRemoteEnrollmentService.RunnerFailure.timedOut(
                seconds: 10, message: "ssh timed out"
            )
        })
        let probe = ClaudeRemoteForwardOwnershipCheck.live(
            witness: witness, runner: spy.runner
        )

        let ownership = await probe("builder", 28511)
        XCTAssertEqual(ownership, .unproved)
        XCTAssertEqual(witness.armedCount, 0, "a failed probe leaves nothing armed")
    }

    func testAnInvalidAliasNeverReachesAProcess() async throws {
        let witness = ClaudeRemoteForwardProbeWitness()
        let spy = RunnerSpy()
        let probe = ClaudeRemoteForwardOwnershipCheck.live(
            witness: witness, runner: spy.runner
        )

        let ownership = await probe("-oProxyCommand=touch /tmp/pwned", 28511)
        XCTAssertEqual(ownership, .unproved)
        XCTAssertTrue(spy.recorded.isEmpty)
    }

    /// The nonce is a short-lived secret while it is in flight: an argv is
    /// world-readable on the remote host, so it goes down stdin like the
    /// enrollment token does.
    func testTheNonceTravelsOnStdinAndNeverInArgv() async throws {
        let witness = ClaudeRemoteForwardProbeWitness()
        let spy = RunnerSpy()
        let probe = ClaudeRemoteForwardOwnershipCheck.live(
            witness: witness,
            runner: spy.runner,
            makeNonce: { "0123456789abcdef0123456789abcdef" }
        )

        _ = await probe("builder", 28511)

        let call = try XCTUnwrap(spy.recorded.first)
        XCTAssertFalse(
            call.argv.contains { $0.contains("0123456789abcdef") },
            "argv: \(call.argv)"
        )
        XCTAssertTrue(call.standardInput.contains("0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(call.standardInput.contains("127.0.0.1:28511"))
        XCTAssertFalse(
            call.standardInput.lowercased().contains("authorization"),
            "the probe carries no credential — the refusal is the point"
        )
    }

    /// `ClearAllForwardings=yes` matters here specifically: without it this
    /// connection inherits the alias's own `RemoteForward` and contends for the
    /// very port it is asking about.
    func testTheProbeConnectionCarriesNoForwardsAndCannotPrompt() async throws {
        let witness = ClaudeRemoteForwardProbeWitness()
        let spy = RunnerSpy()
        let probe = ClaudeRemoteForwardOwnershipCheck.live(
            witness: witness, runner: spy.runner
        )

        _ = await probe("builder", 28511)

        let argv = try XCTUnwrap(spy.recorded.first).argv
        XCTAssertEqual(argv.first, "ssh")
        XCTAssertTrue(argv.contains("BatchMode=yes"))
        XCTAssertTrue(argv.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(argv.contains("--"))
        let terminator = try XCTUnwrap(argv.firstIndex(of: "--"))
        XCTAssertEqual(argv[terminator + 1], "builder", "the alias follows the terminator")
    }
}
