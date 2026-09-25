import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    /// A freshly issued credential and its setup plan, held for exactly as long
    /// as the sheet showing it is up.
    ///
    /// This is the only place in the app where a plaintext token lives past the
    /// call that made it. It is `private(set)`, it is cleared by `dismissPlan`,
    /// and nothing writes it anywhere. The registry cannot reissue it — that is
    /// the whole point of storing only hashes. It is not persisted locally;
    /// automated setup carries it only in the confirmed SSH process's stdin.
    /// Rotation is the recovery path.
    public struct EnrollmentPresentation: Identifiable, Equatable, Sendable {
        public var id: String { host.id }
        public var host: ClaudeRemoteHost
        public var token: String
        public var sshHostAlias: String
        public var plan: ClaudeRemoteEnrollmentService.SetupPlan
        /// Rotation reuses this sheet because the user's remote is currently
        /// broken on purpose and needs the same complete setup run.
        public var isRotation: Bool
        /// False when `sshHostAlias` is the sheet's placeholder rather than an
        /// alias the user gave us — a legacy host rotated before the alias was
        /// persisted. Automated execution is withheld because it would hand a
        /// fresh token to whichever machine answered to a guessed name.
        public var canRunRemoteSetup: Bool = true
        /// The port the snippet forwards ON THE HOST — this Mac's allocation.
        /// Carried here rather than re-read at check time so verification can
        /// only ever probe the port the config in front of the user names.
        public var remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort
        /// Sample sheet for screenshots. Every mutating entry point refuses a
        /// preview presentation, so it can neither write ~/.ssh/config, spawn
        /// ssh, nor touch the registry — see `presentPreviewPlan`.
        public var isPreview: Bool = false
    }

    /// The update panel for one enrolled host.
    public struct PluginUpdatePresentation: Identifiable, Equatable, Sendable {
        public var id: String { hostID }
        public var hostID: String
        /// The alias automated execution uses, or nil for a legacy host that
        /// must be re-enrolled before the app can safely address it.
        public var sshHostAlias: String?
        /// This host's regenerated ssh-config block, when the local one did
        /// not match it when the panel opened; nil when it did. The run
        /// regenerates a nil one and checks the file again before writing,
        /// since the block can change while the panel is open.
        ///
        /// The two are ONE migration and the review that caught this was right
        /// to call it a blocker: storing `port=285xx` in the plugin while
        /// `~/.ssh/config` still says `RemoteForward 8473` points every hook on
        /// that host at a port this Mac does not forward, and the result fails
        /// open — silently, which is the whole #215 failure class reintroduced
        /// by the fix for it.
        public var sshConfigSnippet: String?
        public var canRun: Bool { sshHostAlias != nil }
    }

    public enum EnrollmentAction: Sendable, Equatable {
        case setupHost
        /// Per-host, because the pane shows one row per host and the outcome
        /// has to render in the row whose button ran it.
        case updateHost(hostID: String)
        case configureLocalHerdrPanel
    }

    public struct EnrollmentConfirmation: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var action: EnrollmentAction
        public var title: String
        public var confirmButtonTitle: String
    }

    /// Long-form detail. Alerts and the log take this; the pane never renders it
    /// inline (owner rule).
    public struct DetailAlert: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var title: String
        public var detail: String
    }
}
