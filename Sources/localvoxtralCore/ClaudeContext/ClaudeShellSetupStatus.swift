import ClaudeContextWire
import Foundation

/// What the pane can say about the plain-ssh join's one setup step.
///
/// Two facts, deliberately separate, because they fail for different reasons
/// and only the user can fix the first: is the export in the rc file, and has
/// a session actually arrived carrying it. A block written five seconds ago
/// proves nothing until a NEW ssh session starts, and saying so is the whole
/// value of the second half.
public struct ClaudeShellSetupStatus: Sendable, Equatable {
    public enum RCState: Sendable, Equatable {
        /// The login shell is not one this app writes for.
        case unsupportedShell
        case notApplied
        /// This build's block is in the rc file.
        case applied
        /// A block is there, but not this build's text: an older app wrote
        /// it, or it was edited by hand.
        case outdated
        /// The rc file could not be read, or is a symlink we will not write
        /// through.
        case unknown
    }

    public enum CrossingState: Sendable, Equatable {
        /// No enrolled host has a live session at all — nothing to say yet.
        case noSessions
        /// Live sessions, none carrying the value: the usual "you have not
        /// opened a new window yet".
        case notSeen
        case seen
    }

    public var rc: RCState
    /// The rc file or its directory is a symlink. Every write refuses (an
    /// atomic write would replace the link), so the row offers no button
    /// that writes, only the manual steps.
    public var isSymlinked: Bool
    public var crossing: CrossingState
    /// The rc file this app would write, relative to `$HOME` — shown so the
    /// user knows what they are being asked to let us edit.
    public var relativeRCPath: String?

    public init(
        rc: RCState = .unknown,
        isSymlinked: Bool = false,
        crossing: CrossingState = .noSessions,
        relativeRCPath: String? = nil
    ) {
        self.rc = rc
        self.isSymlinked = isSymlinked
        self.crossing = crossing
        self.relativeRCPath = relativeRCPath
    }

    /// One short sentence, per the pane's copy rule. Never restates the label,
    /// never a path or a host.
    public var rcSentence: String {
        if offersManualSteps { return "Your shell startup file is a symlink; edit it by hand." }
        switch rc {
        case .unsupportedShell: return "Your login shell is not one this can set up."
        case .notApplied: return "Not set up."
        case .applied: return "Set up."
        case .outdated: return "Update available."
        case .unknown: return "Could not read your shell startup file."
        }
    }

    /// The row's setup button, or nil when this build's block is already in
    /// the rc file: writing it again changes nothing.
    public var setupButtonTitle: String? {
        if isSymlinked { return nil }
        switch rc {
        case .unsupportedShell, .notApplied, .unknown: return "Set up…"
        case .outdated: return "Update…"
        case .applied: return nil
        }
    }

    /// Remove is offered only for a clean block the writer will take out.
    public var offersRemove: Bool { !isSymlinked && (rc == .applied || rc == .outdated) }

    /// A symlinked rc file not known to hold this build's block: the one
    /// case the row points at the manual steps instead of a button. The
    /// app never reads through the link, so its content is usually unknown.
    public var offersManualSteps: Bool { isSymlinked && rc != .applied }

    public var crossingSentence: String {
        switch crossing {
        case .noSessions: return "No remote session has reported in yet."
        case .notSeen: return "Open a new terminal window for it to take effect."
        case .seen: return "A remote session is reporting its terminal."
        }
    }
}
