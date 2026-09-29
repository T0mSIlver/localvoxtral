import ClaudeContextWire
import Foundation

/// How a dictation addressed to a session by name ("… send that to
/// payments", #723 step 3) reaches it. The focused app is never a
/// destination: the user named another session.
package enum AddressedSessionRoute: Sendable {
    /// An API into the session's own prompt: opencode's relay or its herdr
    /// pane. Appends, then submits.
    case prompt(any AgentPromptRoute)
    /// A local terminal tab: brought forward with `SessionPaneFocusing`,
    /// typed into, then Return, each step only on the pane's own evidence.
    case terminalPane
    case unsupported(SessionPaneFocusUnsupported)
}

extension ClaudeSessionJoinResolver {
    /// The route into a named session. It writes only where the session's
    /// own records point and a second source agrees: the relay a fresh
    /// declaration by the session's pid published, or the herdr pane whose
    /// foreground holds the session's pid. Read docs/agent/invariants.md
    /// ("The app writes into an agent only through its routes").
    package func addressedRoute(for session: ClaudeSessionSnapshot) async -> AddressedSessionRoute {
        guard session.origin.isLocalAuthenticated else { return .unsupported(.remote) }
        if session.agent == .opencode, let relay = registry.opencodePromptRelay(sessionID: session.sessionID) {
            Log.claudeContext.notice("send to session: opencode prompt relay")
            return .prompt(AddressedPromptRoute(OpencodePromptRoute(relay: relay)))
        }
        if session.process?.herdrPaneID != nil {
            guard let route = await addressedHerdrRoute(for: session) else { return .unsupported(.herdr) }
            Log.claudeContext.notice("send to session: herdr pane")
            return .prompt(AddressedPromptRoute(route))
        }
        switch SessionPaneFocusRoute.of(session) {
        case .terminalTTY:
            return .terminalPane
        case .herdrPane:
            // Handled above: a local herdr pane is written through its route.
            return .unsupported(.herdr)
        case .claudeDesktop:
            // The Return exception is ruled for terminal tabs only.
            Log.claudeContext.notice("send to session: no route (claudeDesktop)")
            return .unsupported(.claudeDesktop)
        case .unsupported(let reason):
            Log.claudeContext.notice("send to session: no route (\(reason.rawValue, privacy: .public))")
            return .unsupported(reason)
        }
    }

    /// The local herdr arm's checks, for a pane that need not be focused:
    /// the one live local herdr is the session's, the registry maps the pane
    /// to this session alone, and herdr lists the session's pid in the
    /// pane's foreground.
    private func addressedHerdrRoute(for session: ClaudeSessionSnapshot) async -> HerdrPanePromptRoute? {
        guard let process = session.process,
              let paneID = process.herdrPaneID,
              let socketPath = process.herdrSocketPath,
              let panes = herdrPanes,
              let writer = herdrPaneWriter
        else {
            Log.claudeContext.notice("send to session: herdr pane without a socket or a client")
            return nil
        }
        guard registry.liveLocalHerdrSocketPaths() == [socketPath] else {
            Log.claudeContext.notice("send to session: not the one live local herdr")
            return nil
        }
        guard case .resolved(let owner) = registry.resolve(herdrPaneID: paneID),
              owner.sessionID == session.sessionID
        else {
            Log.claudeContext.notice("send to session: the pane does not map to that session alone")
            return nil
        }
        guard let foreground = await panes.paneForegroundInfo(socketPath: socketPath, paneID: paneID)?.foregroundPIDs,
              foreground.contains(process.claudePID)
        else {
            Log.claudeContext.notice("send to session: the session's agent is not foreground in its pane")
            return nil
        }
        let claudePID = process.claudePID
        return HerdrPanePromptRoute(
            binding: ClaudeHerdrPaneBinding(paneID: paneID, socketPath: socketPath),
            writer: writer,
            agentIsForeground: {
                await panes.paneForegroundInfo(socketPath: socketPath, paneID: paneID)?
                    .foregroundPIDs?.contains(claudePID) == true
            },
            // Keys go to the focused app, never this pane.
            keysReachThePane: { false }
        )
    }
}

/// A route for addressed dictation: a text the route did not take stays in
/// History. Typing it would put it in the focused app, which the user did
/// not address.
package struct AddressedPromptRoute: AgentPromptRoute {
    package let route: any AgentPromptRoute

    package init(_ route: any AgentPromptRoute) {
        self.route = route
    }

    package var name: String { route.name }

    package func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery {
        switch await route.deliver(call) {
        case .delivered: .delivered
        case .typeInstead, .keepInHistory: .keepInHistory
        }
    }
}
