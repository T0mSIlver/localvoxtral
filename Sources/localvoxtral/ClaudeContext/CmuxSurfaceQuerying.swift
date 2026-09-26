import Foundation

/// What the resolver needs to know about cmux's focused surface.
///
/// `surfaceID` is `CMUX_SURFACE_ID`: minted by cmux and injected into the
/// surface's process environment — and, through its ssh relay, into the
/// environment of a `cmux ssh` shell on another host.
///
/// It is SESSION-SCOPED, not persistent: cmux re-mints surface ids when a
/// workspace is restored (its own `PanelStableSurfaceIdentity` notes that
/// `Panel/id` is "re-minted every time a panel is recreated, including session
/// restore", and the restart-stable id is a different value that is neither
/// exported to the environment nor returned on the socket). Nothing here is
/// durable for that reason: both sides of the match — the session's published
/// env and the socket's answer — come from the same cmux run, and a stale id
/// simply fails to match, because these are UUIDs and a re-minted one cannot
/// collide with an old one. `CMUX_WORKSPACE_ID` is equally volatile and is
/// deliberately never consulted.
struct CmuxFocusedSurface: Sendable, Equatable {
    var surfaceID: String
    /// The surface's controlling tty, when cmux reports one. Optional because a
    /// non-answer must stay distinguishable from a disagreement: the resolver
    /// cross-checks only when both sides know a tty.
    var tty: String?
    /// Whether the workspace HOSTING this surface is a live remote (`cmux ssh`)
    /// workspace, as cmux reports it right now. Nil when cmux would not say.
    ///
    /// This is the only remote-ness signal cmux exposes to a client, and it is
    /// deliberately read fresh per dictation. The surface node itself carries
    /// nothing: a `cmux ssh` surface is an ordinary `type: "terminal"` whose
    /// remoteness lives on the WORKSPACE (`workspace.remote.configure` stores
    /// it; `Workspace.isRemoteWorkspace` is `remoteConfiguration != nil`), so
    /// it takes a second method to see it. Nil is not "local" — it is "cmux did
    /// not answer", which the resolver treats as refusing every remote claim.
    var workspaceIsRemote: Bool?
}

/// One socket answer. Three cases rather than an optional because exactly one
/// failure — "the socket did not let us in" — is the user's to fix, and folding
/// it into a generic nil is how a fixable misconfiguration becomes an
/// unexplained silence.
enum CmuxQueryResult<Value: Sendable>: Sendable {
    case value(Value)
    /// The socket answered and refused us: password mode with no/wrong
    /// password, or the default `cmuxOnly` mode, where cmux checks peer
    /// ancestry and we are by construction not a cmux child.
    case authenticationRequired
    /// No socket, no answer, a malformed answer, a deadline, or an error that
    /// is not about credentials. Includes "cmux is not running", which is the
    /// common case and not an error.
    case unavailable
}

/// Equatable only where the payload is — the internal wire shapes this enum
/// also carries have no business gaining an equality just to be returned.
extension CmuxQueryResult: Equatable where Value: Equatable {}

/// The one short sentence the Settings row shows for the cmux socket. Details —
/// which method, which code — go to the log; the pane gets a sentence (owner
/// rule: never long text in the popover/pane).
enum CmuxSocketStatus: Sendable, Equatable {
    case ok
    case authenticationRequired
    case unavailable

    var message: String? {
        switch self {
        case .ok:
            return nil
        case .authenticationRequired:
            return "cmux socket requires password mode."
        case .unavailable:
            return "cmux socket not reachable."
        }
    }
}

/// Read-only access to cmux's control socket, as the join arm needs it.
///
/// Every call carries the pid the CONNECTED PEER must turn out to be — the
/// running cmux app the join is about. It is a required argument rather than
/// client state because it is a per-dictation fact (the frontmost app), and
/// because a credential must never be sent to a peer nobody named.
protocol CmuxSurfaceQuerying: Sendable {
    /// The surface the user is currently looking at.
    func focusedSurface(expectedPeerPID: pid_t) async -> CmuxQueryResult<CmuxFocusedSurface>
    /// The visible text of EXACTLY `surfaceID`. Raw wire text: the caller owns
    /// sanitization, bounding, and every consent gate.
    func surfaceText(
        surfaceID: String, expectedPeerPID: pid_t
    ) async -> CmuxQueryResult<String>
}
