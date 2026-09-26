import ClaudeContextWire
import Foundation
import Synchronization

/// Why the remote listener turned a connection away, in the only shapes that
/// have different fixes.
///
/// Field report, 2026-07-26: the app's unified log carried an hours-long stream
/// of one line — "Rejected unauthenticated connection to the remote listener" —
/// once every few minutes. The cause was long-running remote sessions still on
/// the pre-1.1.0 plugin, whose http hooks sent `Authorization: Bearer ` with an
/// empty credential. That line could not tell that apart from a token that had
/// been rotated out, and the app's UI said nothing at all: remote dictation
/// simply had no context. Diagnosing it took a dispatched log-collection
/// workflow. The cases below each name their own remedy instead.
///
/// The fourth case, `.absentAuthorization`, is the same lesson applied to the
/// opposite error. `.emptyCredential` used to cover a connection that sent no
/// `Authorization` header at all, so every unauthenticated probe of this
/// endpoint — including the enrollment verify step, which posts without a
/// credential deliberately and treats the 401 as its success signal — wrote a
/// line telling the reader to update a plugin that was already current. A
/// remedy that fires on healthy setups is a remedy nobody trusts the next time
/// it fires on a broken one, and this is the subsystem where reading the log
/// months later IS the diagnostic route.
public enum ClaudeRemoteRejectionCategory: String, Sendable, Equatable, CaseIterable {
    /// No `Authorization` header at all: nothing on the connection attempted to
    /// authenticate. NOT a plugin fault, and naming one would be a lie — see
    /// `ClaudeRemoteAuthorizationShape.absent` for why no plugin generation can
    /// produce this shape.
    case absentAuthorization
    /// An `Authorization` header arrived carrying no credential — the pre-1.1.0
    /// plugin's exact signature, and the only shape that earns the
    /// update-the-plugin remedy.
    case emptyCredential
    /// A credential arrived and matched no enrolled host.
    case unknownToken
    /// The `Authorization` header was not a bearer credential we would read.
    case malformedAuthorization

    /// One line, and never any token material — not the header, not the
    /// credential, not its length. What the user needs is which fix to apply,
    /// and that is decided by the SHAPE alone.
    public var logLine: String {
        switch self {
        case .absentAuthorization:
            return "Rejected remote connection: no Authorization header — an unauthenticated probe or "
                + "setup check; every plugin generation sends the header, so no host is at fault"
        case .emptyCredential:
            return "Rejected remote connection: empty bearer credential — a pre-1.1.0 plugin or "
                + "misconfigured hook; update the plugin on the host"
        case .unknownToken:
            return "Rejected remote connection: no enrolled host matches — rotated token or revoked host; "
                + "re-run enrollment install with the current token"
        case .malformedAuthorization:
            return "Rejected remote connection: malformed Authorization header"
        }
    }

    /// Whether this rejection describes something the user may need to fix.
    ///
    /// Only `.absentAuthorization` is routine: the app's own verify probe and
    /// the documented `curl` check both produce it by design, and the 401 is
    /// their success signal. It is still logged, once per connection, saying
    /// exactly what arrived — it is simply not an error, and a log full of
    /// errors that are not errors is how the real one gets scrolled past.
    public var isFault: Bool { self != .absentAuthorization }

    /// The category a head's authorization shape implies, given whether the
    /// credential it carried authenticated.
    ///
    /// Pure, so the mapping is assertable without binding a port — and so the
    /// listener has exactly one place where a shape becomes a diagnosis.
    public static func category(
        for shape: ClaudeRemoteAuthorizationShape,
        authenticated: Bool
    ) -> ClaudeRemoteRejectionCategory? {
        switch shape {
        case .absent: return .absentAuthorization
        case .empty: return .emptyCredential
        case .malformed: return .malformedAuthorization
        case .bearer: return authenticated ? nil : .unknownToken
        }
    }
}

/// How many connections have been rejected since launch, by category.
///
/// In memory and never persisted: this answers "is something wrong RIGHT NOW",
/// which a count that survived a relaunch would answer wrongly. It is owned by
/// the listener coordinator rather than by a listener, so a rebind (enrolling a
/// host, revoking one) does not reset the evidence the user has not read yet.
///
/// `Mutex` + `Sendable`, per repo convention: the listener's connection threads
/// record while the main actor reads for Settings.
public final class ClaudeRemoteRejectionTally: Sendable {
    public struct Snapshot: Sendable, Equatable {
        /// Counted, but deliberately outside `isEmpty` — see there.
        public var absentAuthorization: Int
        public var emptyCredential: Int
        public var unknownToken: Int
        public var malformedAuthorization: Int

        public init(
            absentAuthorization: Int = 0,
            emptyCredential: Int = 0,
            unknownToken: Int = 0,
            malformedAuthorization: Int = 0
        ) {
            self.absentAuthorization = absentAuthorization
            self.emptyCredential = emptyCredential
            self.unknownToken = unknownToken
            self.malformedAuthorization = malformedAuthorization
        }

        /// True when nothing counted here describes a fault a host could have.
        ///
        /// `absentAuthorization` is excluded on purpose. It is what the app's own
        /// verify probe and the documented `curl` check look like from this side,
        /// and the hint it would raise is a sentence about a HOST's plugin or
        /// token — copy that cannot be true of a caller which is not a host's
        /// hook. Counting it would paint a fault on a healthy pane every time the
        /// user checked their setup: the same phantom the log used to write,
        /// moved into the UI. It stays in the snapshot because a stream of
        /// anonymous dials is still worth being able to read.
        public var isEmpty: Bool {
            emptyCredential == 0 && unknownToken == 0 && malformedAuthorization == 0
        }
    }

    private let counts = Mutex(Snapshot())

    public init() {}

    public func record(_ category: ClaudeRemoteRejectionCategory) {
        counts.withLock { counts in
            switch category {
            case .absentAuthorization: counts.absentAuthorization += 1
            case .emptyCredential: counts.emptyCredential += 1
            case .unknownToken: counts.unknownToken += 1
            case .malformedAuthorization: counts.malformedAuthorization += 1
            }
        }
    }

    public func snapshot() -> Snapshot { counts.withLock { $0 } }
}
