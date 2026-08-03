import CryptoKit
import Foundation

/// Which port on the REMOTE host this Mac's `RemoteForward` binds.
///
/// Not a preference and not a negotiation — a deterministic function of one
/// persisted per-install identity, because the two ends that must agree on it
/// (the ssh-config block on this Mac and the plugin's `port` option on the
/// remote host) are configured minutes apart, by hand, from a plan the user
/// copies. Anything the app cannot recompute identically on the next launch
/// would drift between those two halves and fail open — i.e. look like nothing
/// at all.
///
/// Why per-Mac at all (issue #215): two ssh connections that request the same
/// remote listen port do not both get it. The FIRST one wins and keeps
/// winning; the second stays connected with only a stderr warning (our block
/// sets `ExitOnForwardFailure no` deliberately, so a dictation nicety never
/// costs the user their shell) and every hook event on that host — including
/// its `Authorization: Bearer` header — is delivered to the first Mac's
/// listener, which 401s it. The shim treats a 401 as a completed exchange, so
/// nothing anywhere reports a problem. Two Macs on distinct ports cannot enter
/// that state.
///
/// What this does NOT fix, stated plainly: one remote host runs one Claude Code
/// install with ONE plugin config, so its `port` option names exactly one Mac.
/// Two Macs enrolled against the same host still means only the
/// most-recently-installed config receives events; the other's tunnel binds
/// fine and simply sees no traffic. That is a visible, honest single-tenancy —
/// not a silent cross-delivery of another Mac's credentials.
public enum ClaudeRemoteForwardPort {
    /// The legacy shared port, still the fallback everywhere: an install that
    /// predates the `port` plugin option, an ssh block written before this
    /// change, and the Mac-side listener itself all stay on it. Migration is
    /// therefore never forced — an untouched enrollment keeps working.
    public static let legacyPort: UInt16 = 8473

    /// Inclusive allocation range: 100 ports starting one "8473" above 28000.
    ///
    /// Chosen to sit below every default ephemeral range the remote host might
    /// pick from (Linux 32768–60999, macOS/BSD 49152–65535), so a forward bind
    /// cannot lose a race with an outbound socket on the host, and high enough
    /// to be unprivileged and unregistered. 100 is deliberately small: it keeps
    /// the number human-readable in a pasted command, and the birthday
    /// collision it admits between two of one person's Macs is loud (the
    /// generated verify step greps for it) rather than silent.
    public static let rangeLowerBound: UInt16 = 28473
    public static let rangeUpperBound: UInt16 = 28572

    static var portCount: UInt16 { rangeUpperBound - rangeLowerBound + 1 }

    /// Ports the shim will accept from plugin config. Anything outside falls
    /// back to `legacyPort` on the remote side, so keep the two rules identical.
    public static let acceptableRange: ClosedRange<UInt16> = 1024...65535

    /// Domain-separated so the identity can never be reused as, or confused
    /// with, any other derivation; versioned so a future range change is a
    /// deliberate new function rather than a silent reshuffle of everyone's
    /// ports.
    private static let derivationDomain = "localvoxtral.claude.remote-forward.v1:"

    /// Stable port for one install identity. Pure: same identity, same port,
    /// forever, on every machine — which is what makes the plan reproducible
    /// after a relaunch.
    public static func port(forInstallIdentity identity: String) -> UInt16 {
        var hasher = SHA256()
        hasher.update(data: Data(derivationDomain.utf8))
        hasher.update(data: Data(identity.utf8))
        let digest = Array(hasher.finalize())
        let value = UInt16(digest[0]) << 8 | UInt16(digest[1])
        return rangeLowerBound + (value % portCount)
    }

    public static func isAcceptable(_ port: UInt16) -> Bool {
        acceptableRange.contains(port)
    }

    /// What OpenSSH prints — on stderr, at `-v` and above — when the remote
    /// refuses the bind because something already holds the port. It is the
    /// ONLY signal that this Mac is now silently receiving nothing, so both the
    /// generated verify step and the supervised forward watch for this exact
    /// substring. Stable across OpenSSH releases (verified on 10.0p2, 2026-08-03).
    public static let forwardFailureSignature = "remote port forwarding failed"

    /// One short sentence that names the fix rather than the symptom. Shared so
    /// the pasted verify command and any in-app status say the same thing.
    ///
    /// Apostrophe-free on purpose: it is embedded in single-quoted shell.
    public static func contentionMessage(port: UInt16, host: String) -> String {
        "Another machine or stale connection holds port \(port) on \(host)."
    }
}

/// Reads — and, exactly once, writes — the per-install identity the port is
/// derived from.
///
/// `UserDefaults`-backed rather than a file: the identity must outlive the
/// Claude host registry (deleting that file loses every token and forces
/// re-enrollment anyway, but deleting it must not silently move an enrolled
/// host's port), and it must be readable before any Claude subsystem exists.
/// The defaults instance and the generator are injected so tests never touch
/// the real domain and never depend on a random value.
/// Deliberately NOT `Sendable`: it holds a `UserDefaults`, which is not, and
/// pretending otherwise would only move the compiler's objection into a
/// `@unchecked` annotation nobody can check. Nothing needs to send one — the
/// port is read once per launch on the main actor and passed around as a
/// `UInt16`, which is as Sendable as values get. `ClaudeRemoteForwardPort`
/// itself is pure and reachable from anywhere.
public struct ClaudeRemoteForwardPortAllocator {
    /// Lives in the `settings.` domain because it is persisted user state, not
    /// a debug toggle — but it is deliberately not shown in any pane: there is
    /// nothing to decide here, and a user-editable identity is a user-editable
    /// port with no matching remote config.
    public static let identityDefaultsKey = "settings.claude_remote_forward_identity"

    private let defaults: UserDefaults
    private let makeIdentity: @Sendable () -> String

    public init(
        defaults: UserDefaults = .standard,
        makeIdentity: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.defaults = defaults
        self.makeIdentity = makeIdentity
    }

    /// The persisted identity, generating and storing one on first use.
    ///
    /// An empty or whitespace-only stored value is treated as absent: a
    /// half-written default must not pin every install that suffered it to the
    /// same port.
    public func installIdentity() -> String {
        if let stored = defaults.string(forKey: Self.identityDefaultsKey),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return stored
        }
        let generated = makeIdentity()
        defaults.set(generated, forKey: Self.identityDefaultsKey)
        Log.claudeContext.info(
            "Claude remote forward identity generated; allocated port \(ClaudeRemoteForwardPort.port(forInstallIdentity: generated), privacy: .public)"
        )
        return generated
    }

    /// This Mac's remote listen port. Stable across launches.
    public func allocatedPort() -> UInt16 {
        ClaudeRemoteForwardPort.port(forInstallIdentity: installIdentity())
    }
}
