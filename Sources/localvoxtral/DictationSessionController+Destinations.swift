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
    /// picking it answers it, and its row still needs a name.
    var names: [String: String] = [:]
    /// What is in front as far as the picks know. Anything but `.origin`
    /// means going back to the focused app has to bring it back.
    var front: FrontWindow = .origin
    /// The destination the latest pick is going to while it runs.
    var pending: DictationDestination?
    /// A pick is bringing a window forward; later picks wait for it, and a
    /// stop now cannot know what is in front.
    var focusInFlight = false
    /// Bumped per pick task, so only the latest one clears `focusInFlight`.
    var pickGeneration = 0
    /// The overlay lists every destination while the user moves between
    /// them (#1015), until `DestinationListRule.openFor` passes without a move.
    var listOpen = false
}

enum DestinationListRule {
    /// How long the overlay's list stays open after the last Tab, arrow or
    /// click.
    static let openFor: Duration = .seconds(2)
}

/// Which window a dictation's picks may have put in front.
enum FrontWindow: Equatable {
    /// The app the dictation started in.
    case origin
    /// A session pane in `bundleID`'s app: confirmed for `sessionID`, or
    /// raised by a focus the terminal did not confirm (nil).
    case pane(bundleID: String, sessionID: String?)
}

/// What the commit checks at stop when picks moved the focus, decided when
/// the dictation stops listening.
enum DestinationCommitGuard: Equatable {
    /// The words go into the picked session: the commit target must still
    /// be that pane's app, and its focused pane must still show the session.
    case pickedPane(bundleID: String, sessionID: String)
    /// A pane may have come forward over the focused app: the commit target
    /// must still be the focused app, and not the pane's app.
    case focusedApp(pid: pid_t?, notBundleID: String)
    /// The dictation stopped while a window was coming forward.
    case unsettled
}

/// Tab and ⇧Tab (or → and ←, or a click) during an Overlay Buffer dictation
/// move its words to the focused app, the Inbox, or a session that needs
/// you, and open the overlay's list of them for a moment. The words go only
/// where the overlay shows: a session is picked only once its terminal
/// confirmed the pane is in front (`.focused`), the way the answer shortcut
/// starts a dictation (#785), and the stop then commits into that pane like
/// any dictation. The Inbox is a quick capture (#751): never inserted.
extension DictationSessionController {
    enum DestinationStatus {
        static let cantGoBack = "Can't bring that window back"
        static let paneLeftFront = "That session's window left the front"
        static let originLeftFront = "The window you started in left the front"
        static let stoppedWhileSwitching = "Stopped while a window was switching"
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
        if let state = destinations {
            sessionCommitGuard = Self.commitGuard(for: state)
        }
        destinationKeyHandler.stop()
        destinationFocusTask?.cancel()
        destinationFocusTask = nil
        destinationListCloseTask?.cancel()
        destinationListCloseTask = nil
        destinations = nil
    }

    /// Tab or → (`forward`), ⇧Tab or ←.
    func moveDestination(forward: Bool) {
        guard isDictating, var state = destinations else { return }
        refreshDestinationList(&state)
        let base = state.pending ?? state.list.selected
        destinations = state
        openDestinationList()
        pickDestination(state.list.moving(from: base, forward: forward))
    }

    /// A click on a destination in the overlay (#880) picks it the way Tab
    /// would. A click on where the picks are already going opens the list,
    /// the only way to reach the others by click while it is closed. One on
    /// a session that left the list since the overlay drew it is dropped.
    func clickDestination(_ destination: DictationDestination) {
        guard isDictating, var state = destinations else { return }
        refreshDestinationList(&state)
        destinations = state
        guard state.list.entries.contains(destination) else { return }
        openDestinationList()
        guard destination != (state.pending ?? state.list.selected) else { return }
        pickDestination(destination)
    }

    /// Opens the overlay's list, or keeps it open, for another
    /// `DestinationListRule.openFor` on `dependencies.clock`.
    private func openDestinationList() {
        guard destinations != nil else { return }
        if destinations?.listOpen == false {
            destinations?.listOpen = true
            showDestinations()
        }
        destinationListCloseTask?.cancel()
        let clock = dependencies.clock
        destinationListCloseTask = Task { @MainActor [weak self] in
            await clock.sleep(DestinationListRule.openFor)
            guard let self, !Task.isCancelled, self.destinations?.listOpen == true else { return }
            self.destinationListCloseTask = nil
            self.destinations?.listOpen = false
            self.showDestinations()
        }
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

    /// Picks `destination`. The Inbox, and the focused app while nothing
    /// was brought over it, are picked at once. Anything that brings a
    /// window forward runs in `destinationFocusTask`, after any pick still
    /// running: cancelling one would leave its window in front unrecorded.
    private func pickDestination(_ destination: DictationDestination) {
        guard var state = destinations else { return }
        if !state.focusInFlight, pickAtOnce(destination, state: state) { return }
        state.pending = destination
        state.focusInFlight = true
        state.pickGeneration += 1
        let generation = state.pickGeneration
        destinations = state
        let prior = destinationFocusTask
        destinationFocusTask = Task { @MainActor [weak self] in
            await prior?.value
            guard let self, !Task.isCancelled, self.isDictating, self.destinations != nil else { return }
            await self.pickBringingForward(destination)
            guard !Task.isCancelled, self.destinations?.pickGeneration == generation else { return }
            self.destinations?.pending = nil
            self.destinations?.focusInFlight = false
        }
    }

    private func pickAtOnce(_ destination: DictationDestination, state: SessionDestinations) -> Bool {
        switch destination {
        case .inbox:
            applyDestination(.inbox)
            return true
        case .focusedApp where state.front == .origin:
            applyDestination(.focusedApp)
            return true
        case .focusedApp, .session:
            return false
        }
    }

    private func pickBringingForward(_ destination: DictationDestination) async {
        switch destination {
        case .inbox:
            applyDestination(.inbox)
        case .focusedApp:
            await bringFocusedAppBack()
        case .session(let id):
            guard let navigator = sessionNavigator else {
                Log.dictation.error("destination: no session navigator; staying put")
                return
            }
            let outcome = await navigator.focusPane(sessionID: id)
            guard !Task.isCancelled, isDictating, destinations != nil else { return }
            Log.dictation.notice(
                "destination: session pane \(outcome.map { String(describing: $0) } ?? "no longer live", privacy: .public)"
            )
            switch outcome {
            case .focused(let bundleID)?:
                destinations?.front = .pane(bundleID: bundleID, sessionID: id)
                agentAttention?.tracker.answered(sessionID: id)
                applyDestination(destination)
            case .unverified(let bundleID)?:
                // The pane may have come forward, but an unconfirmed one
                // must not get the words: the pick stays, and the stop
                // checks what is in front.
                destinations?.front = .pane(bundleID: bundleID, sessionID: nil)
                statusText = AnswerAgentStatus.unconfirmed
            case .paneNotFound?, nil:
                statusText = GoToSessionStatus.paneNotFound
            case .unsupported?:
                statusText = GoToSessionStatus.unsupported
            }
        }
    }

    /// A session pane came over the focused app. The focused app's own
    /// session pane comes back through the navigator; another app comes
    /// back by activation. The same terminal with no session to find the
    /// pane by cannot: activating it would show the session pane, so the
    /// words would land there.
    private func bringFocusedAppBack() async {
        guard let state = destinations, case .pane(let paneBundleID, _) = state.front else {
            applyDestination(.focusedApp)
            return
        }
        if let originSessionID = state.originSessionID, let navigator = sessionNavigator {
            let outcome = await navigator.focusPane(sessionID: originSessionID)
            guard !Task.isCancelled, isDictating, destinations != nil else { return }
            guard case .focused? = outcome else {
                Log.dictation.notice("destination: the focused app's pane did not come back; staying put")
                statusText = DestinationStatus.cantGoBack
                return
            }
        } else if let originPID = state.originPID,
                  dependencies.bundleIdentifier(originPID) != paneBundleID,
                  dependencies.activateApp(originPID) {
            // Activated.
        } else {
            Log.dictation.notice("destination: the focused app cannot be brought back; staying put")
            statusText = DestinationStatus.cantGoBack
            return
        }
        destinations?.front = .origin
        applyDestination(.focusedApp)
    }

    static func commitGuard(for state: SessionDestinations) -> DestinationCommitGuard? {
        if state.focusInFlight { return .unsettled }
        switch (state.list.selected, state.front) {
        case (.inbox, _), (.focusedApp, .origin):
            return nil
        case (.session(let id), .pane(let bundleID, let paneSessionID)):
            // A pane in front that is not the picked session's cannot take
            // the words.
            return paneSessionID == id ? .pickedPane(bundleID: bundleID, sessionID: id) : .unsettled
        case (.focusedApp, .pane(let bundleID, _)):
            return .focusedApp(pid: state.originPID, notBundleID: bundleID)
        case (.session, .origin):
            // A session is selected only once its pane is confirmed in front.
            return .unsettled
        }
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
        // The voice stop (#839) depends on where the words go: the Inbox
        // stops on its phrase with no send gate. Re-decide on the words
        // already said, not only on the next ones.
        disarmSpokenStop()
        reconsiderSpokenStop()
    }

    private func refreshDestinationList(_ state: inout SessionDestinations) {
        let waiting = waitingSessions()
        for entry in waiting where state.names[entry.sessionID] == nil {
            state.names[entry.sessionID] = entry.name
        }
        state.list.refresh(waitingSessionIDs: waiting.map(\.sessionID), focusedSessionID: state.originSessionID)
    }

    /// What the commit does about the destination when picks moved the focus.
    enum DestinationCommitCheck: Equatable {
        case commit
        /// Kept in History as not inserted; the stop is finished.
        case kept
        /// Commit once the terminal reads back that its focused pane still
        /// shows the picked session.
        case readBack(sessionID: String, bundleID: String)
    }

    /// When picks moved the focus, the words go in only where the overlay
    /// said: into the picked pane while its app is still the commit target
    /// (the app in front at stop) and its focused pane still shows the
    /// session, or into the focused app while no pane brought over it is.
    /// Two tabs of one terminal share an app, so the pane read-back is what
    /// tells them apart. What fails keeps the words in History as not
    /// inserted.
    func checkDestinationBeforeCommit(sessionMode: DictationOutputMode) -> DestinationCommitCheck {
        guard let commitGuard = sessionCommitGuard else { return .commit }
        sessionCommitGuard = nil
        let targetPID = overlayBufferCoordinator.commitTargetAppPID
        let targetBundleID = targetPID.flatMap(dependencies.bundleIdentifier)
        switch commitGuard {
        case .pickedPane(let bundleID, let sessionID):
            guard targetBundleID == bundleID else {
                keepOverlayInHistory(sessionMode: sessionMode, status: DestinationStatus.paneLeftFront, record: nil)
                return .kept
            }
            return .readBack(sessionID: sessionID, bundleID: bundleID)
        case .focusedApp(let originPID, let paneBundleID):
            guard targetPID == nil || targetPID != originPID || targetBundleID == paneBundleID else { return .commit }
            keepOverlayInHistory(sessionMode: sessionMode, status: DestinationStatus.originLeftFront, record: nil)
            return .kept
        case .unsettled:
            keepOverlayInHistory(sessionMode: sessionMode, status: DestinationStatus.stoppedWhileSwitching, record: nil)
            return .kept
        }
    }

    /// Runs `proceed`, the rest of the commit, once the focused pane reads
    /// back as the picked session's; otherwise keeps the words in History.
    /// A new dictation started meanwhile saves them as not inserted.
    func commitAfterPaneReadBack(
        sessionID: String,
        bundleID: String,
        sessionMode: DictationOutputMode,
        record: StoppedSessionRecordFields,
        proceed: @escaping @MainActor () -> Void
    ) {
        guard let navigator = sessionNavigator else {
            keepOverlayInHistory(sessionMode: sessionMode, status: DestinationStatus.paneLeftFront, record: record)
            return
        }
        let text = transcript.currentDictationEventText
        saveInterruptedPolishCommit = { [weak self] in
            self?.saveSessionRecord(
                startedAt: record.startedAt, rawText: text, polishedText: nil, polishingDuration: nil,
                provider: record.provider, model: record.model, outputMode: record.outputMode,
                targetAppBundleID: nil, status: .sttCompleted, commitSucceeded: false,
                audio: record.audio, joined: nil
            )
        }
        polishAndCommitTask = Task { @MainActor [weak self] in
            let shows = await navigator.focusedPaneShows(sessionID: sessionID, bundleID: bundleID)
            guard let self, !Task.isCancelled else { return }
            self.saveInterruptedPolishCommit = nil
            guard shows else {
                Log.dictation.notice("destination: the focused pane no longer shows the picked session")
                self.keepOverlayInHistory(sessionMode: sessionMode, status: DestinationStatus.paneLeftFront, record: record)
                return
            }
            proceed()
        }
    }

    /// Saves the stopped overlay dictation as not inserted and finishes the
    /// stop with `status`. `record` is the stop's sample when it was taken.
    private func keepOverlayInHistory(
        sessionMode: DictationOutputMode,
        status: String,
        record: StoppedSessionRecordFields?
    ) {
        Log.dictation.notice("destination: the commit target is not the picked window; kept in History")
        let fields = record ?? {
            let sessionAudio = audio.sessionRecording.finish()
            return StoppedSessionRecordFields(
                startedAt: sessionStartedAt ?? Date(),
                provider: sessionProvider?.rawValue ?? settings.realtimeProvider.rawValue,
                model: sessionModelName ?? settings.effectiveModelName,
                outputMode: sessionMode.rawValue,
                targetAppBundleID: nil,
                audio: sessionStoresAudio ? sessionAudio : nil
            )
        }()
        saveSessionRecord(
            startedAt: fields.startedAt,
            rawText: transcript.currentDictationEventText,
            polishedText: nil,
            polishingDuration: nil,
            provider: fields.provider,
            model: fields.model,
            outputMode: fields.outputMode,
            targetAppBundleID: nil,
            status: .sttCompleted,
            commitSucceeded: false,
            audio: fields.audio,
            joined: nil
        )
        overlayBufferCoordinator.reset()
        completeStoppedSessionCleanup(sessionMode: sessionMode, overlayCommitOutcome: nil, shouldCommitOverlay: true)
        statusText = status
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
                sessionName: { state.names[$0] ?? AgentAttentionText.unnamed },
                isOpen: state.listOpen
            )
        )
    }
}
