import ClaudeContextWire
import Foundation
import Synchronization

/// Why the remote listener turned a connection away, in the only three shapes
/// that have different fixes.
///
/// Field report, 2026-07-26: the app's unified log carried an hours-long stream
/// of one line — "Rejected unauthenticated connection to the remote listener" —
/// once every few minutes. The cause was long-running remote sessions still on
/// the pre-1.1.0 plugin, whose http hooks sent `Authorization: Bearer ` with an
/// empty credential. That line could not tell that apart from a token that had
/// been rotated out, and the app's UI said nothing at all: remote dictation
/// simply had no context. Diagnosing it took a dispatched log-collection
/// workflow. The three cases below each name their own remedy instead.
public enum ClaudeRemoteRejectionCategory: String, Sendable, Equatable, CaseIterable {
    /// No bearer credential at all — the pre-1.1.0 plugin's exact signature.
    case missingToken
    /// A credential arrived and matched no enrolled host.
    case unknownToken
    /// The `Authorization` header was not a bearer credential we would read.
    case malformedAuthorization

    /// One line, and never any token material — not the header, not the
    /// credential, not its length. What the user needs is which of three fixes
    /// to apply, and that is decided by the SHAPE alone.
    public var logLine: String {
        switch self {
        case .missingToken:
            return "Rejected remote connection: no bearer token — a pre-1.1.0 plugin or misconfigured hook; "
                + "update the plugin on the host"
        case .unknownToken:
            return "Rejected remote connection: no enrolled host matches — rotated token or revoked host; "
                + "re-run enrollment install with the current token"
        case .malformedAuthorization:
            return "Rejected remote connection: malformed Authorization header"
        }
    }

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
        case .missing: return .missingToken
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
        public var missingToken: Int
        public var unknownToken: Int
        public var malformedAuthorization: Int

        public init(missingToken: Int = 0, unknownToken: Int = 0, malformedAuthorization: Int = 0) {
            self.missingToken = missingToken
            self.unknownToken = unknownToken
            self.malformedAuthorization = malformedAuthorization
        }

        public var isEmpty: Bool {
            missingToken == 0 && unknownToken == 0 && malformedAuthorization == 0
        }
    }

    private let counts = Mutex(Snapshot())

    public init() {}

    public func record(_ category: ClaudeRemoteRejectionCategory) {
        counts.withLock { counts in
            switch category {
            case .missingToken: counts.missingToken += 1
            case .unknownToken: counts.unknownToken += 1
            case .malformedAuthorization: counts.malformedAuthorization += 1
            }
        }
    }

    public func snapshot() -> Snapshot { counts.withLock { $0 } }
}
