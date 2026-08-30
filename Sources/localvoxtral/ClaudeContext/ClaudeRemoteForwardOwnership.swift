import Foundation
import Synchronization

/// Who holds the remote listen port when OpenSSH refuses this Mac's bind.
///
/// The refusal itself cannot tell the two apart, and they want opposite things
/// from the user (field report, 2026-08-29):
///
/// * a stranger — another Mac's forward, a leftover tunnel, an unrelated
///   service — is a real failure the user has to go and clear;
/// * **our own `RemoteForward`, already established by an ordinary ssh session
///   that read the enrollment block out of `~/.ssh/config`**, is the desired
///   end state reached by another route. It is what happens to everybody who
///   actually ssh's to the host they enrolled, and the app was telling them to
///   close the session providing the working tunnel.
public enum ClaudeRemoteForwardOwnership: Sendable, Equatable {
    /// A nonce this process minted seconds ago came back in on this Mac's own
    /// listener, through the port in question. Nothing else can produce that.
    case ourListener
    /// Everything else, including every way the check could not be run.
    /// The only safe default: see `ClaudeRemoteForwardProbeWitness`.
    case unproved
}

/// Nonces minted for an in-flight ownership probe, and which of them the
/// listener has SEEN arrive.
///
/// **This is the whole trust argument, so it is worth being explicit about what
/// is and is not evidence.**
///
/// The obvious probe — curl the port from the remote host and read the status
/// code — is not evidence of anything. Our 401 (and the 411 an empty POST gets)
/// is public: the listener's source, its response shape and its paths are all in
/// this repository, so any process on the remote host can bind the port and
/// reproduce those bytes exactly. Worse, it is not even a correct *diagnosis*:
/// a SECOND Mac enrolled against the same host answers a genuine, honest 401 of
/// its own, and that is precisely the contention `ClaudeRemoteForwardPort`
/// exists to make visible.
///
/// So the probe does not read the answer at all. It sends a fresh random nonce
/// TO the port and then asks THIS process whether its own loopback listener saw
/// that nonce. That inverts the question into one only the real topology can
/// answer:
///
/// * if the port is held by our own `RemoteForward`, the request travels the
///   tunnel and lands here — match;
/// * if a stranger holds the port, it receives the nonce and can do nothing
///   with it. The listener binds `127.0.0.1` on this Mac and the only route to
///   it from that host is a forward — which, by hypothesis, the stranger is the
///   reason we do not have. It cannot deliver the nonce, so it cannot be
///   adopted;
/// * if another Mac holds the port, the nonce lands on THAT Mac's listener,
///   which has never heard of it. No match here, which is the right answer.
///
/// Everything else — no `curl` on the host, ssh refused, a timeout, no probe
/// wired in at all — produces `.unproved`, which keeps the old
/// `portUnavailable` behaviour. Fail closed is the default, not a branch.
public final class ClaudeRemoteForwardProbeWitness: Sendable {
    /// The header the probe rides in. Named like the env enrichment headers so
    /// it is recognisably ours in a capture, and deliberately NOT a new URL
    /// path: the listener authenticates on the head before it judges a path, and
    /// this must not become the second thing that is judged earlier.
    public static let headerName = "x-lvx-forward-probe"

    /// A hard ceiling on armed nonces. Arm/disarm are paired by the one caller,
    /// so this can only ever be reached by a bug — and a bug that leaks entries
    /// should leak a bounded number of dead strings, not grow a set forever.
    static let maximumArmed = 8

    private struct State {
        /// Armed nonces in arming order, each with whether it has been seen.
        var entries: [(nonce: String, observed: Bool)] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// 128 bits of CSPRNG as lowercase hex.
    ///
    /// Hex rather than base64url because this value is interpolated into a
    /// generated `sh` script and an HTTP header value; `[0-9a-f]` needs quoting
    /// in neither, and the header parser's charset rules cannot be tripped by it.
    public static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Start watching for `nonce`. Paired with exactly one `consume`.
    public func arm(_ nonce: String) {
        state.withLock { state in
            state.entries.removeAll { $0.nonce == nonce }
            state.entries.append((nonce: nonce, observed: false))
            while state.entries.count > Self.maximumArmed { state.entries.removeFirst() }
        }
    }

    /// Stop watching for `nonce`, and report whether it ever arrived.
    public func consume(_ nonce: String) -> Bool {
        state.withLock { state in
            guard let index = state.entries.firstIndex(where: { $0.nonce == nonce }) else {
                return false
            }
            return state.entries.remove(at: index).observed
        }
    }

    /// Listener side: mark an armed nonce as seen.
    ///
    /// - Returns: true only when `headerValue` is exactly an armed nonce. A
    ///   header that is absent, empty, or anything we did not mint is not
    ///   distinguishable from the other by anything the caller then does — the
    ///   response bytes are identical either way, by construction at the call
    ///   site.
    @discardableResult
    public func note(headerValue: String?) -> Bool {
        guard let headerValue, !headerValue.isEmpty else { return false }
        return state.withLock { state in
            // Constant-time against every armed entry, and no early exit on the
            // first match: a loop that breaks tells a caller how many nonces are
            // armed and roughly where theirs sits.
            var matched = false
            for index in state.entries.indices
            where ClaudeRemoteTokenDigest.constantTimeEquals(
                state.entries[index].nonce, headerValue
            ) {
                state.entries[index].observed = true
                matched = true
            }
            return matched
        }
    }

    /// Test seam: is this nonce still armed?
    var armedCount: Int { state.withLock { $0.entries.count } }
}

/// Asks a host whether the refused port forwards to THIS Mac.
///
/// - Parameters:
///   - sshHostAlias: the enrolled alias, already validated by the caller.
///   - remoteForwardPort: the port the bind was refused for.
public typealias ClaudeRemoteForwardOwnershipProbe = @Sendable (
    _ sshHostAlias: String, _ remoteForwardPort: UInt16
) async -> ClaudeRemoteForwardOwnership

/// Internal, not public, for one concrete reason: its default runner is the
/// enrollment service's live `Process` runner, which is internal — and a public
/// entry point whose default argument reaches for an internal declaration does
/// not compile. Nothing outside this module builds one.
enum ClaudeRemoteForwardOwnershipCheck {
    /// Bounded on purpose and short: this runs inside a supervise loop that the
    /// user is watching a status line for, and a wedged ssh must not park it.
    static let defaultTimeout: TimeInterval = 10

    /// The remote half of the probe.
    ///
    /// It is a `curl` on the REMOTE host because that is where the port is
    /// bound — nothing on this Mac can reach it. No token is sent, and none
    /// would be accepted: the request is expected to be refused, and the
    /// refusal is not what is being read.
    ///
    /// Sent over stdin rather than argv so the nonce never appears in a remote
    /// process listing, the same rule the enrollment scripts follow for the
    /// token.
    ///
    /// The first line discards both streams on purpose. Whatever holds that
    /// port gets to write a response, and none of it is evidence — so none of
    /// it is carried back into this process to be captured, capped, or logged.
    static func script(nonce: String, remoteForwardPort: UInt16) -> String {
        """
        exec >/dev/null 2>&1
        command -v curl >/dev/null 2>&1 || exit 3
        curl -s -o /dev/null --max-time 5 -X POST \
          -H 'Content-Type: application/json' \
          -H '\(ClaudeRemoteForwardProbeWitness.headerName): \(nonce)' \
          -d '{}' \
          'http://127.0.0.1:\(remoteForwardPort)/v1/hook/SessionStart'
        """
    }

    /// `ClearAllForwardings=yes` HERE, unlike the supervised herdr `-L`
    /// (`docs/agent/invariants.md`): this connection carries no forward of its
    /// own and must not inherit the alias's `RemoteForward`, which would have it
    /// contend for the very port it is asking about and print the warning that
    /// started this whole diagnosis. `--` for the `-V` lesson (PR #197).
    static func argv(sshHostAlias: String) -> [String] {
        [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=5",
            "--", sshHostAlias, "/bin/sh", "-s",
        ]
    }

    static func live(
        witness: ClaudeRemoteForwardProbeWitness,
        runner: @escaping ClaudeRemoteEnrollmentService.Runner =
            ClaudeRemoteEnrollmentService.processRunner(),
        makeNonce: @escaping @Sendable () -> String = {
            ClaudeRemoteForwardProbeWitness.randomNonce()
        },
        timeout: TimeInterval = defaultTimeout
    ) -> ClaudeRemoteForwardOwnershipProbe {
        { sshHostAlias, remoteForwardPort in
            // Re-validated rather than assumed: this is the only place in the
            // forward path that hands an alias to a NEW process, and `--`
            // covers option injection but not a caller mistake.
            guard ClaudeRemoteEnrollmentService.isValidHostAlias(sshHostAlias) else {
                return .unproved
            }
            let nonce = makeNonce()
            witness.arm(nonce)
            // `Process` + its semaphore waits are blocking, and every caller of
            // this probe is on the main actor.
            let ran = await Task.detached(priority: .utility) { () -> Bool in
                let invocation = ClaudeRemoteEnrollmentService.Invocation(
                    argv: argv(sshHostAlias: sshHostAlias),
                    standardInput: Data(
                        script(nonce: nonce, remoteForwardPort: remoteForwardPort).utf8
                    ),
                    timeout: timeout
                )
                return (try? runner(invocation)) != nil
            }.value
            // The exit status is NOT the answer and is not consulted for one:
            // curl exits 0 against a stranger that answered, and non-zero
            // against our own listener if the connection is torn down after the
            // request lands. Only the witness decides.
            let observed = witness.consume(nonce)
            Log.claudeContext.info(
                "Claude remote forward ownership probe on port \(remoteForwardPort, privacy: .public) ran=\(String(ran), privacy: .public) ourListener=\(String(observed), privacy: .public)"
            )
            return observed ? .ourListener : .unproved
        }
    }
}
