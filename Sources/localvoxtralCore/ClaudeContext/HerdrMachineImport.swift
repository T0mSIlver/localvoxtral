import ClaudeContextWire
import Foundation

/// What herdr's saved-machine catalog means for the Remote hosts group's
/// import list. `absent` and `unreadable` are kept apart for the same reason
/// `HerdrMachineCatalogReading` keeps them apart: no catalog is a user who
/// saved no machines (render nothing at all), while a catalog that cannot be
/// read is a fact worth one inline sentence.
public enum HerdrMachineImportSection: Sendable, Equatable {
    case absent
    case unreadable
    case candidates([HerdrMachineImportCandidate])
}

/// One saved herdr machine, offered as an enrollment source.
public struct HerdrMachineImportCandidate: Identifiable, Sendable, Equatable {
    public var profile: HerdrMachineProfile
    public var status: HerdrMachineImportStatus
    public var id: String { profile.id }

    package init(profile: HerdrMachineProfile, status: HerdrMachineImportStatus) {
        self.profile = profile
        self.status = status
    }
}

/// What the pane can do with one saved machine.
public enum HerdrMachineImportStatus: Sendable, Equatable {
    /// An enrolled, non-revoked host whose `sshHostAlias` equals the
    /// profile's target EXACTLY. Exact match only — Settings does not
    /// canonicalize with `ssh -G`; the join arm does that at join time, not
    /// the pane. A revoked host never counts: its credential is withdrawn,
    /// and the machine is importable again.
    case enrolled(hostID: String)
    /// Not enrolled, and the target is a plain ssh config alias or hostname
    /// the enrollment form accepts as-is.
    case importable
    /// Not enrolled, and the target is a `user@host` or `ssh://` form the
    /// enrollment flow cannot take — it needs a `Host` alias for the
    /// ssh-config block it writes. The row says so in one sentence.
    case needsAlias
    /// `enabled == false` in herdr: rendered dimmed, no action.
    case disabled

    /// The row's one short sentence, when it has one. Nil for every status
    /// whose dot and the enrolled-host list above already say everything.
    public var sentence: String? {
        switch self {
        case .enrolled, .importable, .disabled:
            return nil
        case .needsAlias:
            return "Add an SSH config alias for it first."
        }
    }
}
