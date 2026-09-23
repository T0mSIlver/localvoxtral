import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    /// One row in the enrolled-hosts list. Carries no secret: `ClaudeRemoteHost`
    /// has no token, by construction.
    public struct HostRow: Identifiable, Equatable, Sendable {
        public var id: String
        public var label: String
        /// Nil for hosts enrolled before the alias was persisted. Never
        /// substituted with `label`: they are different fields on the form, so
        /// guessing one from the other can ssh to a machine the user did not
        /// pick.
        public var sshHostAlias: String?
        public var isRevoked: Bool
        public var lastSeenAt: Date?
        /// The whole status, resolved against the model's injected clock when
        /// the row was built.
        ///
        /// Rendered rather than computed in the view for two reasons. A
        /// `RelativeDateTimeFormatter` cached in a `static let` would be
        /// non-Sendable global state (a Swift 6 error), and building one per row
        /// per redraw is worse — but mostly, "when did this host last send
        /// context" is the answer a user needs to tell a silent tunnel from a
        /// working one, and an answer with a test beats an answer with a
        /// formatter.
        public var statusText: String
        /// Whether this host opted into the app-held SSH forward, and what that
        /// forward is doing right now. Both live on the row so the view stays a
        /// renderer: the toggle reads one Bool, the status line reads one
        /// already-rendered sentence.
        public var persistentForwardEnabled: Bool = false
        public var forwardStatusText: String?
        public var forwardIsFailure: Bool = false
        /// A forward can only be offered where we know where to ssh. The label
        /// is not a substitute for an alias (PR #197).
        public var canHoldForward: Bool = false
        /// Last setup outcome for this host during the current app session.
        public var setupStatusText: String?
        /// Whether the highest plugin version this host's authenticated hooks
        /// have reported this app session is OLDER than the one this build
        /// installs (or no version header at all, which means ≤ 1.9.0).
        /// False when nothing has been heard: an update hint with no evidence
        /// is noise, and a host that has never dialed has no plugin fact to
        /// state. The record is monotone, so an old session's headerless hook
        /// cannot re-flag a host whose update a read-back already proved.
        public var pluginNeedsUpdate: Bool = false
        /// Whether the row offers Update Plugin…. Hidden when the run would
        /// change nothing it can check from this Mac: the host reported this
        /// build's plugin (or newer) this app session, its SSH config block is
        /// current, and the shell startup block is in place. A host not heard
        /// from yet, or a file that cannot be read, keeps the button. Hidden
        /// for a revoked host too: the run carries no token, so it cannot
        /// bring the host back (Rotate token does).
        public var offersUpdate: Bool = true
    }

    /// Mistral Vibe on an enrolled host, from what this Mac knows without ssh:
    /// the credential it issued, and the version the host's hooks last
    /// reported. It has no row of its own. The host's one setup run installs
    /// every agent it finds there, and this only decides whether that run is
    /// worth offering.
    public enum VibeHostHooksState: Sendable, Equatable {
        case notSetUp
        case setUp
        case updateAvailable

        static func derive(host: ClaudeRemoteHost, bundledVersion: String?) -> VibeHostHooksState? {
            guard !host.isRevoked,
                  host.sshHostAlias.map(ClaudeRemoteEnrollmentService.isValidHostAlias) == true
            else { return nil }
            guard host.extraCredentialPurposes.contains(.vibe) else { return .notSetUp }
            if let reported = host.reportedVibeHooksVersion, let bundledVersion,
               ClaudeRemotePluginVersionCodec.isVersion(reported, olderThan: bundledVersion) {
                return .updateAvailable
            }
            return .setUp
        }
    }

    /// The one fixed sentence the row's status position shows while
    /// `pluginNeedsUpdate`. Deliberately no version numbers (owner rule: the
    /// row is one short line) — the fact, not the arithmetic.
    public static let pluginUpdateAvailableText = "Update available"

    /// Whether a host's REPORTED plugin version is older than the one this
    /// build installs. The four cases, exactly:
    ///
    /// * never heard from the host (`reported == nil`) → false;
    /// * authenticated hook without a valid version header (`.headerAbsent`)
    ///   → true — that is the ≤ 1.9.0 generation the header was added for;
    /// * reported older than expected → true;
    /// * reported equal or NEWER → false. A newer report means this app is
    ///   behind the host, which is not the host's problem to fix.
    ///
    /// The numeric comparison is `ClaudeRemotePluginVersionCodec`'s — the
    /// same single implementation the registry's monotone record uses, so
    /// "what the registry kept" and "what the row says" can never disagree.
    static func pluginNeedsUpdate(
        reported: ClaudeRemotePluginVersionReport?,
        expected: String
    ) -> Bool {
        switch reported {
        case nil: return false
        case .headerAbsent: return true
        case .version(let version):
            return ClaudeRemotePluginVersionCodec.isVersion(version, olderThan: expected)
        }
    }

    /// Whether a host REPORTED this build's plugin version or a newer one.
    /// Not the negation of `pluginNeedsUpdate`: a host never heard from is
    /// neither outdated (no hint without evidence) nor current.
    static func pluginIsCurrent(
        reported: ClaudeRemotePluginVersionReport?,
        expected: String
    ) -> Bool {
        guard case .version(let version)? = reported else { return false }
        return !ClaudeRemotePluginVersionCodec.isVersion(version, olderThan: expected)
    }

    /// "Last context: 2 min ago", from a clock the caller supplies.
    ///
    /// Coarse on purpose: the question is "is this host still talking to me",
    /// and a to-the-second answer would only invite the user to read precision
    /// into a timestamp that is refreshed when the pane appears.
    ///
    /// `lastSeenAt` is the registry's IN-MEMORY value, persisted only on the
    /// next persisting mutation (see `ClaudeRemoteHostRegistry.noteActivity` —
    /// a disk write per hook event would be steady write amplification for a
    /// dictation nicety). So a host that was active before a relaunch reads
    /// "never" until its next hook event. That is the existing trade, not a
    /// missing write.
    static func hostStatusText(isRevoked: Bool, lastSeenAt: Date?, now: Date) -> String {
        if isRevoked { return "Revoked" }
        guard let lastSeenAt else { return "Last context: never" }
        let elapsed = now.timeIntervalSince(lastSeenAt)
        // A clock that stepped backwards (NTP, a DST correction) must not print
        // a negative age. "Just now" is the honest reading of "not in the past".
        guard elapsed >= 60 else { return "Last context: just now" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "Last context: \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Last context: \(hours) \(hours == 1 ? "hour" : "hours") ago" }
        let days = hours / 24
        return "Last context: \(days) \(days == 1 ? "day" : "days") ago"
    }
}
