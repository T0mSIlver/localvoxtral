import Foundation
import os

/// One Overlay Buffer dictation's destinations (#840): the list, where it
/// started, the session pane Tab brought forward, and where a Tab still
/// bringing a pane forward is going.
struct SessionDestinations {
    var list: DictationDestinationList
    /// The app that was focused at start, and the session its pane showed.
    let originPID: pid_t?
    let originSessionID: String?
    let originLabel: String
    let originJoined: Bool?
    /// Names of the sessions listed, kept once a session leaves the queue:
    /// picking it answers it, and its pill still needs a name.
    var names: [String: String] = [:]
    /// The session pane Tab brought forward. While set, the focused app is
    /// not in front, and going back there has to bring it back.
    var paneInFront: (sessionID: String, bundleID: String)?
    /// The destination a focus under way is going to.
    var pending: DictationDestination?
}

/// Tab and ⇧Tab during an Overlay Buffer dictation move its words to the
/// focused app, a session that needs you, or the Inbox. The words go only
/// where the overlay shows: a session is picked only once its terminal
/// confirmed the pane is in front (`.focused`), the way the answer shortcut
/// starts a dictation (#785), and the stop then commits into that pane like
/// any dictation. The Inbox is a quick capture (#751): never inserted.
extension DictationSessionController {
    enum DestinationStatus {
        static let cantGoBack = "Can't bring that window back"
    }

    /// Called when the overlay opens: the list, and Tab while it runs.
    func beginDestinations() {
        let originPID = overlayBufferCoordinator.commitTargetAppPID
        let joinLabel: String?
        let joined: Bool?
        switch sessionClaudeJoinBadge {
        case .joined(let label): (joinLabel, joined) = (label, true)
        case .unjoined: (joinLabel, joined) = (nil, false)
        case .hidden: (joinLabel, joined) = (nil, nil)
        }
        let originSessionID = context.claudeSessionJoin?.snapshot.sessionID
        let waiting = waitingSessions()
        destinations = SessionDestinations(
            list: DictationDestinationList(
                waitingSessionIDs: waiting.map(\.sessionID),
                focusedSessionID: originSessionID,
                selected: sessionIsQuickCapture ? .inbox : .focusedApp
            ),
            originPID: originPID,
            originSessionID: originSessionID,
            originLabel: joinLabel
                ?? originPID.flatMap(dependencies.applicationName)
                ?? "This app",
            originJoined: joined,
            names: Dictionary(waiting.map { ($0.sessionID, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
        destinationKeyHandler.start()
        showDestinations()
    }

    /// Called wherever the dictation stops listening. What the pick decided
    /// is in `sessionIsQuickCapture` and in which app is in front.
    func endDestinations() {
        destinationKeyHandler.stop()
        destinationFocusTask?.cancel()
        destinationFocusTask = nil
        destinations = nil
    }

    /// Tab (`forward`) or ⇧Tab.
    func moveDestination(forward: Bool) {
        guard isDictating, var state = destinations else { return }
        refreshDestinationList(&state)
        let base = state.pending ?? state.list.selected
        destinations = state
        pickDestination(state.list.moving(from: base, forward: forward))
    }

    /// The quick capture shortcut during an Overlay Buffer dictation picks
    /// the Inbox; pressed on the Inbox, it stops.
    /// Returns false when no overlay dictation runs.
    func pickInboxOrStop() -> Bool {
        guard isDictating, let state = destinations else { return false }
        if state.list.selected == .inbox, state.pending == nil {
            stopDictation(reason: "quick capture toggle")
        } else {
            pickDestination(.inbox)
        }
        return true
    }

    /// The answer shortcut during an Overlay Buffer dictation picks the
    /// oldest session that needs you, unless it is already picked; then, or
    /// with nobody waiting, it stops. Returns false when no overlay
    /// dictation runs.
    func pickWaitingSessionOrStop() -> Bool {
        guard isDictating, var state = destinations else { return false }
        refreshDestinationList(&state)
        destinations = state
        let firstSession = state.list.entries.first {
            if case .session = $0 { return true }
            return false
        }
        guard let firstSession, state.list.selected != firstSession, state.pending != firstSession else {
            stopDictation(reason: "answer shortcut")
            return true
        }
        pickDestination(firstSession)
        return true
    }

    private func pickDestination(_ destination: DictationDestination) {
        guard var state = destinations else { return }
        destinationFocusTask?.cancel()
        destinationFocusTask = nil
        state.pending = nil
        destinations = state
        switch destination {
        case .inbox:
            applyDestination(.inbox)
        case .focusedApp:
            guard let paneInFront = state.paneInFront else {
                applyDestination(.focusedApp)
                return
            }
            bringFocusedAppBack(state: state, paneInFront: paneInFront)
        case .session(let id):
            guard let navigator = sessionNavigator else {
                Log.dictation.error("destination: no session navigator; staying put")
                return
            }
            state.pending = destination
            destinations = state
            destinationFocusTask = Task { @MainActor [weak self] in
                let outcome = await navigator.focusPane(sessionID: id)
                guard let self, !Task.isCancelled, self.isDictating, self.destinations != nil else { return }
                self.destinations?.pending = nil
                Log.dictation.notice(
                    "destination: session pane \(outcome.map { String(describing: $0) } ?? "no longer live", privacy: .public)"
                )
                switch outcome {
                case .focused(let bundleID)?:
                    self.destinations?.paneInFront = (id, bundleID)
                    self.agentAttention?.tracker.answered(sessionID: id)
                    self.applyDestination(destination)
                case .unverified?:
                    // The pane may have come forward, but an unconfirmed
                    // one must not get the words: they stay where they were.
                    self.statusText = AnswerAgentStatus.unconfirmed
                case .paneNotFound?, nil:
                    self.statusText = GoToSessionStatus.paneNotFound
                case .unsupported?:
                    self.statusText = GoToSessionStatus.unsupported
                }
            }
        }
    }

    /// The focused app was left for a session pane. Its own session's pane
    /// comes back through the navigator; another app comes back by
    /// activation. The same terminal with no session to find the pane by
    /// cannot: activating it would show the session pane, so the words
    /// would land there.
    private func bringFocusedAppBack(
        state: SessionDestinations,
        paneInFront: (sessionID: String, bundleID: String)
    ) {
        if let originSessionID = state.originSessionID, let navigator = sessionNavigator {
            destinations?.pending = .focusedApp
            destinationFocusTask = Task { @MainActor [weak self] in
                let outcome = await navigator.focusPane(sessionID: originSessionID)
                guard let self, !Task.isCancelled, self.isDictating, self.destinations != nil else { return }
                self.destinations?.pending = nil
                guard case .focused? = outcome else {
                    Log.dictation.notice("destination: the focused app's pane did not come back; staying put")
                    self.statusText = DestinationStatus.cantGoBack
                    return
                }
                self.destinations?.paneInFront = nil
                self.applyDestination(.focusedApp)
            }
            return
        }
        guard let originPID = state.originPID,
              dependencies.bundleIdentifier(originPID) != paneInFront.bundleID,
              dependencies.activateApp(originPID)
        else {
            Log.dictation.notice("destination: the focused app cannot be brought back; staying put")
            statusText = DestinationStatus.cantGoBack
            return
        }
        destinations?.paneInFront = nil
        applyDestination(.focusedApp)
    }

    private func applyDestination(_ destination: DictationDestination) {
        guard destinations?.list.select(destination) == true else { return }
        sessionIsQuickCapture = destination == .inbox
        let kind = switch destination {
        case .focusedApp: "focused app"
        case .session: "session"
        case .inbox: "inbox"
        }
        Log.dictation.notice("destination: \(kind, privacy: .public)")
        showDestinations()
    }

    private func refreshDestinationList(_ state: inout SessionDestinations) {
        let waiting = waitingSessions()
        for entry in waiting where state.names[entry.sessionID] == nil {
            state.names[entry.sessionID] = entry.name
        }
        state.list.refresh(waitingSessionIDs: waiting.map(\.sessionID), focusedSessionID: state.originSessionID)
    }

    /// The needs-you queue in answer order, empty while the cue is off.
    private func waitingSessions() -> [AgentAttentionEntry] {
        guard settings.agentAttentionEnabled, let tracker = agentAttention?.tracker else { return [] }
        tracker.prune()
        return tracker.queue.answerOrder
    }

    private func showDestinations() {
        guard let state = destinations else {
            overlayBufferCoordinator.showDestinations(nil)
            return
        }
        overlayBufferCoordinator.showDestinations(
            OverlayDestinationStrip(
                list: state.list,
                focusedAppLabel: state.originLabel,
                focusedAppJoined: state.originJoined,
                sessionName: { state.names[$0] ?? AgentAttentionText.unnamed }
            )
        )
    }
}
