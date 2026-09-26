import ClaudeContextWire
#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation


/// One dictation's answer to "which Claude Code session is the user talking
/// to?", resolved ONCE and then shared by everything that needs it.
///
/// Resolving once is a correctness requirement, not an optimization. The three
/// consumers — raw screen attachment, hook state (the prior prompt), and
/// repository context — must describe the SAME session, or the prompt tells the
/// model that the user was working in one repo while showing it another one's
/// screen. Three independent resolutions cannot promise that: the user can
/// switch tabs mid-sentence, and each read would then answer honestly about a
/// different moment. So the surface is read at START, from the pane the user
/// was looking at when they began speaking, and that answer is what every
/// consumer gets.
package enum ClaudeSessionJoinMechanism: Sendable, Equatable {
    case ttyDevice
    case herdrPane
    /// The focused browser tab's `claude.ai/code/session_…` URL matched a live
    /// session's Remote Control bridge session id. No screen is ever read for
    /// this mechanism — see `TerminalScreenClaudeJoinAuthorizer`.
    case browserTab
    /// The web view holding keyboard focus in Claude Desktop is a Code-tab
    /// session page whose `local_…` id matched a live session's
    /// `CLAUDE_CODE_HOST_SESSION_ID`. No screen is ever read for this
    /// mechanism either — see `TerminalScreenClaudeJoinAuthorizer`.
    case desktopSession
    /// A cmux surface, matched by the surface id cmux injected into the
    /// session's environment. Local surfaces and `cmux ssh` remote shells both
    /// arrive here — see `ClaudeSessionJoinResolver.resolveViaCmux`.
    case cmuxSurface
    /// A Claude Code session inside a herdr running on an ENROLLED REMOTE host,
    /// reached over an app-managed `ssh -L` to that herdr's socket.
    case remoteHerdrPane
    /// A Claude Code session inside a herdr on a remote machine a LOCAL herdr
    /// 0.9 client is FEDERATING — the machine named by herdr's own selection
    /// state (`HerdrMachineFederationReader`), reached over the same
    /// app-managed `ssh -L` as `.remoteHerdrPane` and confirmed by the same
    /// panel nonce. See `ClaudeSessionJoinResolver.resolveViaFederatedHerdr`.
    case federatedHerdrPane
    /// A Claude Code session in a PLAIN `ssh host` shell on an enrolled remote
    /// host — no herdr, no cmux, no Remote Control. Bound by the TCP connection
    /// itself: the surface's ssh process's established socket and the session's
    /// reported `$SSH_CONNECTION` name the same connection, ports included.
    case remoteSSHConnection
    /// The same shape, bound by the LOCAL TTY instead: the user's own shell
    /// exports `$LC_LVX_TTY`, ssh carries it into the session, and it must
    /// equal the tty the app reads off the focused terminal. Unlike
    /// `.remoteSSHConnection` this survives ProxyJump and ControlMaster,
    /// because ssh carries environment per session CHANNEL rather than per
    /// connection.
    case remoteLocalTTY
}

/// The herdr pane a herdr join resolved to. Captured at resolution so the
/// pane-text fetch can only ever be keyed by the pane the join is ABOUT —
/// there is no other place a pane id enters that path.
///
/// `socketPath` is always a LOCAL socket this user owns: herdr's own socket for
/// a `.herdrPane` join, and the local end of our `ssh -L` for a
/// `.remoteHerdrPane` or `.federatedHerdrPane` one. The remote host's own
/// socket path never appears here; it exists only as an argv token inside the
/// forward.
package struct ClaudeHerdrPaneBinding: Sendable, Equatable {
    package let paneID: String
    package let socketPath: String

    package init(paneID: String, socketPath: String) {
        self.paneID = paneID
        self.socketPath = socketPath
    }
}

/// The Remote Control bridge session id a `.browserTab` join resolved on.
/// Captured at resolution so commit-time liveness can ask whether the SAME
/// binding still holds, rather than re-reading a tab the user may have changed.
package struct ClaudeBrowserTabBinding: Sendable, Equatable {
    package let bridgeSessionID: String
}

/// The Claude Desktop session id a `.desktopSession` join resolved on. Same
/// role as `ClaudeBrowserTabBinding`: commit-time liveness re-resolves THIS id
/// instead of reading the desktop window a second time.
package struct ClaudeDesktopSessionBinding: Sendable, Equatable {
    package let desktopSessionID: String
}

/// The cmux surface a `.cmuxSurface` join resolved to. Same role as
/// `ClaudeHerdrPaneBinding`: captured at resolution so the surface-text fetch
/// can only ever be keyed by the surface the join is ABOUT.
package struct ClaudeCmuxSurfaceBinding: Sendable, Equatable {
    package let surfaceID: String

    package init(surfaceID: String) {
        self.surfaceID = surfaceID
    }
}

package struct ClaudeSessionJoin: Sendable, Equatable {
    /// The pane the join was resolved for. Consumers re-check this rather than
    /// assuming the join is about whatever target they happen to hold.
    package let target: TerminalScreenTarget
    /// The session as the registry described it at start. Its `sessionID` is
    /// the handle commit-time liveness re-checks (`isStillLive`).
    package let snapshot: ClaudeSessionSnapshot
    /// The identity of the WINDOW that was focused when the join resolved.
    /// `target` cannot
    /// tell two windows of one Ghostty process apart, and the screen capture is
    /// a SEPARATE read that can land on a different window if focus moves
    /// between the two — so authorization compares windows, not just targets
    /// (review F2). Nil means unknown, which never authorizes.
    package let windowID: CGWindowID?
    /// Positive evidence that selected this session. In particular, a herdr
    /// pane join is useful for session/repository context but can never license
    /// a composite raw TUI capture.
    package let mechanism: ClaudeSessionJoinMechanism
    /// Non-nil exactly for herdr joins: the pane whose clean, per-pane text
    /// (`pane.read`) may stand in for the composite screen capture.
    package let herdrPane: ClaudeHerdrPaneBinding?
    /// Non-nil exactly for `.browserTab` joins: the bridge session id the tab
    /// URL and the session's hooks agreed on. Commit-time liveness re-checks it
    /// (`isStillLive`), which is how a Remote Control disconnect ages the join
    /// out on the session's own next hook rather than on a timer of ours.
    package let browserTab: ClaudeBrowserTabBinding?
    /// Non-nil exactly for `.desktopSession` joins: the desktop session id the
    /// focused web view and the session's hooks agreed on. Commit-time
    /// liveness re-checks it the way it re-checks a browser tab's.
    package let desktopSession: ClaudeDesktopSessionBinding?
    /// Non-nil exactly for `.cmuxSurface` joins: the surface whose clean,
    /// per-surface text (`surface.read_text`) is the ONLY screen route cmux has.
    package let cmuxSurface: ClaudeCmuxSurfaceBinding?
    /// Non-nil exactly for `.remoteHerdrPane` and `.federatedHerdrPane` joins:
    /// the `ssh -L` this join runs over.
    ///
    /// Carried ON THE JOIN because its lifetime IS the join's: the stop-side
    /// `pane.read` has to reach the same herdr the start-side one did, and the
    /// join is the one object every consumer of that answer already holds.
    /// Closing it is the holder's job (`close()` is idempotent, and the handle
    /// closes itself on deinit as a backstop).
    package let remoteHerdrForward: ClaudeRemoteHerdrForwardHandle?
    /// The agents-panel token lease for a panel-authorized remote join. The
    /// view model starts it after taking ownership and stops it on every exit.
    package let remoteHerdrIndicator: HerdrPanelMicIndicator?

    package init(
        target: TerminalScreenTarget,
        snapshot: ClaudeSessionSnapshot,
        windowID: CGWindowID?,
        mechanism: ClaudeSessionJoinMechanism,
        herdrPane: ClaudeHerdrPaneBinding? = nil,
        browserTab: ClaudeBrowserTabBinding? = nil,
        desktopSession: ClaudeDesktopSessionBinding? = nil,
        cmuxSurface: ClaudeCmuxSurfaceBinding? = nil,
        remoteHerdrForward: ClaudeRemoteHerdrForwardHandle? = nil,
        remoteHerdrIndicator: HerdrPanelMicIndicator? = nil
    ) {
        self.target = target
        self.snapshot = snapshot
        self.windowID = windowID
        self.mechanism = mechanism
        self.herdrPane = herdrPane
        self.browserTab = browserTab
        self.desktopSession = desktopSession
        self.cmuxSurface = cmuxSurface
        self.remoteHerdrForward = remoteHerdrForward
        self.remoteHerdrIndicator = remoteHerdrIndicator
    }

    /// The per-pane socket route this join owns, if any: the herdr pane id or
    /// the cmux surface id. Lets the shared socket-pane screen path key its
    /// start/stop reconciliation without knowing which multiplexer answered.
    package var socketPaneKey: String? {
        switch mechanism {
        case .herdrPane, .remoteHerdrPane, .federatedHerdrPane: return herdrPane?.paneID
        case .cmuxSurface: return cmuxSurface?.surfaceID
        case .ttyDevice, .browserTab, .desktopSession, .remoteSSHConnection, .remoteLocalTTY:
            return nil
        }
    }

    // Deliberately NO `releaseResources()` here. The join VALUE travels — it is
    // consumed by the commit path and captured into a Task — so a resource
    // whose owner is "whoever currently holds the join" has no owner at all,
    // which is how an aborted connect and a quit-during-polish each leaked an
    // ssh child (review finding 4). `DictationViewModel` takes ownership of the
    // handle when it assigns the join, and closes it from every exit.

    /// The workspace path, non-nil only for a locally authenticated session.
    /// The type is what keeps a remote session's cwd away from the filesystem;
    /// there is nothing to check here because there is nothing to check WITH.
    package var localWorkspacePath: LocalWorkspacePath? { snapshot.localWorkspacePath }
}
