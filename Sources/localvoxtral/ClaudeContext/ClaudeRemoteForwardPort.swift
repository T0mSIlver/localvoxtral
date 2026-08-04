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

    /// Inclusive allocation range: 2000 ports, 28473–30472.
    ///
    /// Chosen to sit below every default ephemeral range the remote host might
    /// pick from (Linux 32768–60999, macOS/BSD 49152–65535), so a forward bind
    /// cannot lose a race with an outbound socket on the host, and high enough
    /// to be unprivileged and unregistered.
    ///
    /// The width is a review decision (2026-08-04). An earlier 100-slot range
    /// read as "plenty for one person's Macs" and is not: birthday collision at
    /// 100 slots is ~1% for two Macs and ~37% for ten, and the failure it
    /// produces — two Macs contending for one remote bind — is precisely the
    /// one this type exists to make unreachable. 2000 slots takes those to
    /// ~0.05% and ~2.2%, at the cost of one more digit in a pasted command.
    public static let rangeLowerBound: UInt16 = 28473
    public static let rangeUpperBound: UInt16 = 30472

    static var portCount: UInt16 { rangeUpperBound - rangeLowerBound + 1 }

    /// Ports the shim will accept from plugin config. Anything outside falls
    /// back to `legacyPort` on the remote side, so keep the two rules identical.
    public static let acceptableRange: ClosedRange<UInt16> = 1024...65535

    /// Domain-separated so the identity can never be reused as, or confused
    /// with, any other derivation; versioned so a future range change is a
    /// deliberate new function rather than a silent reshuffle of everyone's
    /// ports.
    /// v2 since the range widened. Bumping it deliberately re-derives every
    /// identity onto a new port rather than leaving old installs clustered in
    /// the first 100 slots — which is safe exactly once, and this is that once:
    /// nothing has shipped, so no `~/.ssh/config` block and no remote plugin
    /// config exists in the world carrying a v1 port.
    private static let derivationDomain = "localvoxtral.claude.remote-forward.v2:"

    /// Stable port for one install identity. Pure: same identity, same port,
    /// forever, on every machine — which is what makes the plan reproducible
    /// after a relaunch.
    public static func port(forInstallIdentity identity: String) -> UInt16 {
        var hasher = SHA256()
        hasher.update(data: Data(derivationDomain.utf8))
        hasher.update(data: Data(identity.utf8))
        let digest = Array(hasher.finalize())
        // 32 bits folded into the range: 16 would be only ~32 whole
        // multiples of a 2000-slot range, which skews the low slots by ~3%.
        // Not a security property, but a needless bias in the one number that
        // exists to spread Macs apart.
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16
            | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return rangeLowerBound + UInt16(value % UInt32(portCount))
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

/// Where the per-install identity lives.
///
/// A seam, because the two properties that matter cannot be tested through
/// `UserDefaults`: that two racing first launches converge on ONE identity, and
/// that the value survives things `UserDefaults` does not.
public protocol ClaudeRemoteForwardIdentityStore: Sendable {
    /// The persisted identity, or nil if there is none yet.
    func read() throws -> String?
    /// Persist `candidate` ONLY if nothing is stored yet, and return whatever
    /// is stored afterwards — the candidate if this caller won, the existing
    /// value if another one did. Must be atomic against a concurrent claim.
    func claim(_ candidate: String) throws -> String
}

/// The identity as a 0600 file next to the enrollment state.
///
/// Not `UserDefaults`, for two reasons the review named and both of which end
/// in the same silent failure — a Mac whose derived port stops matching the
/// `~/.ssh/config` block and remote plugin config it already handed out:
///
/// 1. **Racing first launches.** Read-then-write in the defaults domain is not
///    atomic, so two processes starting together can each generate an identity
///    and last-writer-wins; the enrollment that already happened under the
///    loser's port is then wrong forever. `link(2)` is the fix: it fails with
///    EEXIST rather than overwriting, so every racer converges on whichever
///    file appeared first.
/// 2. **A preferences reset.** `defaults delete com.localvoxtral.app`, a
///    migration assistant, a restored backup — the host registry in
///    Application Support survives all of those, and an identity that does not
///    would silently move every enrolled host's port while the enrollments
///    themselves look perfectly healthy. Same directory, same fate.
public struct ClaudeRemoteForwardIdentityFileStore: ClaudeRemoteForwardIdentityStore {
    private let fileURL: URL

    public init(fileURL: URL = ClaudeRemoteForwardIdentityFileStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Beside `claude-remote-hosts.json`, deliberately.
    public static func defaultFileURL() -> URL {
        ClaudeRemoteHostRegistry.defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("claude-remote-forward-identity")
    }

    public func read() throws -> String? {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func claim(_ candidate: String) throws -> String {
        if let existing = try read() { return existing }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Write a private temp file, then LINK it into place. `link` refuses to
        // replace an existing name, which is what makes the winner of a race
        // the one everybody reads — a plain write or a rename would let the
        // second racer clobber the first and hand the two Macs the same port
        // this whole type exists to keep apart.
        let temporary = directory.appendingPathComponent(
            ".claude-remote-forward-identity.\(UUID().uuidString)"
        )
        try Data("\(candidate)\n".utf8).write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporary.path
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.linkItem(at: temporary, to: fileURL)
        } catch {
            // Someone else got there first (or we cannot link at all): whatever
            // is on disk wins. Never overwrite.
            if let existing = try read() { return existing }
            throw error
        }
        return try read() ?? candidate
    }
}

/// Resolves the per-install identity the port is derived from, and — exactly
/// once per install — creates it.
///
/// The `UserDefaults` instance is still injected, but only as the MIGRATION
/// source: an install that already stored an identity there (this feature's own
/// first iteration) must keep its port, not silently move to a new one.
public struct ClaudeRemoteForwardPortAllocator {
    /// Where the identity used to live. Read on first use, never written.
    public static let identityDefaultsKey = "settings.claude_remote_forward_identity"

    private let store: any ClaudeRemoteForwardIdentityStore
    private let legacyDefaults: UserDefaults?
    private let makeIdentity: @Sendable () -> String

    public init(
        store: any ClaudeRemoteForwardIdentityStore = ClaudeRemoteForwardIdentityFileStore(),
        legacyDefaults: UserDefaults? = .standard,
        makeIdentity: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.legacyDefaults = legacyDefaults
        self.makeIdentity = makeIdentity
    }

    /// The persisted identity, creating one on first use.
    ///
    /// An empty or whitespace-only stored value is treated as absent: a
    /// half-written file must not pin every install that suffered it to one
    /// shared port — the exact failure this feature removes.
    public func installIdentity() -> String {
        if let stored = (try? store.read()) ?? nil,
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let candidate = migratedIdentity() ?? makeIdentity()
        guard let claimed = try? store.claim(candidate) else {
            // The file could not be written at all (read-only home, sandbox
            // denial). Returning the candidate keeps THIS launch coherent; the
            // next one derives again and logs the same failure. Loud, not
            // silent: a port that moves between launches is exactly what the
            // verify step reports as contention.
            Log.claudeContext.error(
                "Claude remote forward identity could not be persisted; the allocated port may not survive a relaunch"
            )
            return candidate
        }
        Log.claudeContext.info(
            "Claude remote forward identity resolved; allocated port \(ClaudeRemoteForwardPort.port(forInstallIdentity: claimed), privacy: .public)"
        )
        return claimed
    }

    /// The value this feature's first iteration wrote to `UserDefaults`.
    private func migratedIdentity() -> String? {
        guard let stored = legacyDefaults?.string(forKey: Self.identityDefaultsKey) else {
            return nil
        }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        Log.claudeContext.info("Claude remote forward identity migrated out of UserDefaults")
        return trimmed
    }

    /// This Mac's remote listen port. Stable across launches.
    public func allocatedPort() -> UInt16 {
        ClaudeRemoteForwardPort.port(forInstallIdentity: installIdentity())
    }
}
