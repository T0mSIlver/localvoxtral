import ClaudeContextWire
import CoreGraphics
import Foundation

/// Authorizes raw screen attachment from an already-resolved join.
///
/// Holds no resolution logic of its own — it consults the dictation's single
/// join. Before this, the authorizer read the window title itself at commit
/// time, which meant the screen and the (then unbuilt) repo context could
/// resolve different sessions from two reads taken seconds apart.
@MainActor
struct TerminalScreenClaudeJoinAuthorizer: TerminalScreenRawAttachmentAuthorizing {
    private let resolver: ClaudeSessionJoinResolver
    private let currentJoin: @MainActor () -> ClaudeSessionJoin?

    init(
        resolver: ClaudeSessionJoinResolver,
        currentJoin: @escaping @MainActor () -> ClaudeSessionJoin?
    ) {
        self.resolver = resolver
        self.currentJoin = currentJoin
    }

    func isAuthorized(target: TerminalScreenTarget, windowID: CGWindowID?) -> Bool {
        guard let join = currentJoin() else { return false }
        // Exhaustive on purpose: a new join mechanism must DECIDE here rather
        // than inherit authorization from whichever arm was written first.
        switch join.mechanism {
        case .ttyDevice:
            break
        case .remoteSSHConnection, .remoteLocalTTY:
            // The surface IS this machine's terminal grid, so unlike the
            // multiplexer arms there is readable text here — and it is still
            // refused. The connection binding says which ssh this window
            // holds, not what the remote program drew into it, and a plain ssh
            // shell's scrollback is the user's whole remote session: other
            // commands, other repositories, whatever ran before. The title
            // marker never authorized raw attachment for a remote session
            // either, and its replacement inherits no more than it had.
            Log.claudeContext.info(
                "Plain ssh connection join cannot authorize raw screen attachment; withheld"
            )
            return false
        case .herdrPane, .cmuxSurface, .remoteHerdrPane, .federatedHerdrPane:
            // AX sees herdr's composite TUI. Attaching it would let neighboring
            // panes — potentially other Claude sessions — ride into this
            // session's prompt, so a correct pane join still cannot authorize
            // raw capture.
            //
            // A cmux join is refused for a different reason with the same
            // answer: cmux draws with libghostty into a custom view that
            // exposes no AX text at all, so there is nothing here to authorize
            // — and if some future cmux build ever did expose a composite
            // surface, it must not become attachable by default. Both
            // multiplexers' screen text arrives through their own per-pane
            // socket route instead (`SocketPaneScreenContext`).
            //
            // A REMOTE herdr join is refused for the first reason, doubled: the
            // grid is not even this machine's — it is the local ssh client's
            // window, showing whatever herdr drew, panes and all. A FEDERATED
            // join is this machine's grid but herdr's composite client TUI,
            // which mixes panes from every federated machine — more neighbors
            // to leak, not fewer.
            Log.claudeContext.info(
                "Socket-pane join cannot authorize raw AX screen attachment; withheld"
            )
            return false
        case .browserTab:
            // There is no verified screen route for a browser, and the thing on
            // screen is an arbitrary web page rather than a terminal grid. A
            // browser join buys session/repository context only.
            Log.claudeContext.info(
                "Browser tab join cannot authorize raw screen attachment; withheld"
            )
            return false
        case .desktopSession:
            // Claude Desktop is not a terminal grid either, and its window
            // shows the whole conversation. The join buys session/repository
            // context only; the session's hooks already deliver its prompt.
            Log.claudeContext.info(
                "Claude Desktop join cannot authorize raw screen attachment; withheld"
            )
            return false
        }
        // The join must be about THIS pane. A join resolved for one target
        // says nothing about another, and a recycled PID must not inherit the
        // previous owner's authorization — hence the full target compare
        // (pid AND bundle id), not just the pid.
        guard join.target == target else {
            Log.claudeContext.info(
                "Claude join does not describe the captured pane; raw screen attachment withheld"
            )
            return false
        }
        // The target compare above cannot tell two windows of one Ghostty
        // process apart (same pid, same bundle ID), and the capture and the
        // join are two separate AX reads — a focus change between them pairs
        // one window's screen with another window's session (review F2). Only
        // two ESTABLISHED, equal identities authorize; an unknown on either
        // side is an abstention, never a match.
        guard let joinWindow = join.windowID, let captureWindow = windowID,
              joinWindow == captureWindow
        else {
            Log.claudeContext.info(
                "Claude join and screen capture do not name the same window of the target app; raw screen attachment withheld"
            )
            return false
        }
        guard resolver.isStillLive(join) else {
            Log.claudeContext.info(
                "Claude session ended since dictation start; raw screen attachment withheld"
            )
            return false
        }
        return true
    }
}
