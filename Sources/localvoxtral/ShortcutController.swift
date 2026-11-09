import Foundation

/// What the keyboard triggers ask of the dictation session they drive.
/// `DictationViewModel` adopts it; a test fake records the calls.
@MainActor
protocol ShortcutSessionControlling: DictationPhaseReading {
    var isAccessibilityTrusted: Bool { get }
    var statusText: String { get set }
    var lastError: String? { get set }
    var currentStatusToken: DictationViewModel.StatusToken { get }
    var currentErrorToken: DictationViewModel.ErrorToken? { get }
    func startDictation(outputMode: DictationOutputMode?)
    func endDictation(reason: String)
    func toggleDictation(outputMode: DictationOutputMode?)
    func clearSecureInputRefusalSignalsIfAttemptEnded()
    func overlayReachabilityDidChange(wasReachable: Bool)
    func copyLastDictation()
}

/// The keyboard triggers: the push-to-talk, toggle and modifier-only
/// gestures, hotkey registration and its retry, the two shortcut slots, and
/// the "Copy last dictation" shortcut.
/// Owned by `DictationViewModel` and reached as `viewModel.shortcuts`. It
/// drives the session through `ShortcutSessionControlling`, installed by
/// the owner once it exists; until then, and after the owner is gone, a
/// gesture lands on an inert session and is logged.
@MainActor
final class ShortcutController {
    let settings: SettingsStore
    let hotKeyManager = HotKeyManager()

    /// Held weakly: the owner holds this controller, and a cycle would keep
    /// the hotkeys registered past the owner's deinit.
    private weak var owner: (any ShortcutSessionControlling)?
    private var session: any ShortcutSessionControlling { owner ?? Self.detached }
    private static let detached = DetachedShortcutSession()

    /// The push-to-talk key, and whether the start it made is still its to
    /// end. Toggle presses and modifier taps have no release event and never
    /// leave `idle`.
    enum PushToTalkGesture: Equatable {
        enum Key: Equatable {
            /// A dictation shortcut, in push-to-talk mode.
            case shortcut
            /// The single modifier or the chord, held past its threshold.
            case modifierHold
        }

        /// No key down, and no start waits on a release.
        case idle
        /// The key is down; its repeats are ignored. `ownsStart`: this press
        /// started the session, so its release stops it, or drops the start
        /// while it still connects.
        case held(Key, ownsStart: Bool)
        /// The key came up while the start it made still connects or waits
        /// for the microphone prompt: that start is dropped when it lands.
        case releasedBeforeStart
    }

    var gesture: PushToTalkGesture = .idle

    /// True while the user is still physically holding the dictation
    /// shortcut/modifier — a release event is still coming, and it owns
    /// ending the attempt's refusal signals. The managed-startup path in
    /// DictationSessionController+Session.swift consults this: a secure-input
    /// refusal that fires after backend boot may land with no gesture-end
    /// event left to clear it.
    var isDictationAttemptGestureActive: Bool {
        if case .held = gesture { true } else { false }
    }

    /// The session's stop is a release: a push-to-talk start still owned, or
    /// a modifier hold still down.
    var isHoldGestureSession: Bool {
        switch gesture {
        case .held(.modifierHold, _), .held(.shortcut, ownsStart: true), .releasedBeforeStart: true
        case .idle, .held(.shortcut, ownsStart: false): false
        }
    }

    init(settings: SettingsStore) {
        self.settings = settings
        hotKeyManager.onPressWithMode = { [weak self] mode in self?.handleDictationShortcutPress(mode: mode) }
        hotKeyManager.onPress = { [weak self] in self?.handleDictationShortcutPress() }
        hotKeyManager.onRelease = { [weak self] in self?.handleDictationShortcutRelease() }
        hotKeyManager.onHoldStart = { [weak self] in self?.handleModifierOnlyHoldStart() }
        hotKeyManager.onModifierOnlyTap = { [weak self] mode in self?.handleModifierOnlyTap(mode: mode) }
        hotKeyManager.onCopyLastDictation = { [weak self] in self?.session.copyLastDictation() }
    }

    func install(session: any ShortcutSessionControlling) {
        owner = session
    }

    /// The launch registration; the owner calls it once runtime services run.
    func registerAtLaunch() {
        // A key another app already holds leaves the dictation trigger dead,
        // so say so as a settings change would. A modifier gesture refused
        // before Accessibility trust lands is the exception: trust can lag a
        // cold launch, and the trust retry registers it then.
        if case .failure(let reason) = registerCurrentHotKeys(),
           reason != .modifierOnlyHotKeyUnavailable || session.isAccessibilityTrusted
        {
            applyHotKeyRegistrationFailure(reason)
        }
        if case .failure = hotKeyManager.registerCopyLastDictation(settings.copyLastDictationShortcut) {
            applyHotKeyRegistrationFailure(.copyLastDictationShortcutUnavailable)
        }
    }

    func unregister() {
        hotKeyManager.unregister()
        hotKeyManager.registerCopyLastDictation(nil)
    }

    func handleDictationShortcutPress(mode: DictationOutputMode? = nil) {
        switch settings.dictationShortcutMode {
        case .toggle:
            // A toggle press also ends a hold whose release never came (the
            // trigger re-registered mid-hold): that release would otherwise
            // stop the session this press starts.
            gesture = .idle
            if session.isDictating {
                session.endDictation(reason: "manual toggle")
            } else if session.isConnectingRealtimeSession {
                session.statusText = DictationViewModel.StatusStrings.connectingRealtimeBackend
            } else if session.isFinalizingStop {
                session.statusText = DictationViewModel.StatusStrings.finalizingPreviousDictation
            } else {
                session.startDictation(outputMode: mode)
            }
        case .pushToTalk:
            if case .held = gesture { return }
            guard !session.isDictating, !session.isConnectingRealtimeSession, !session.isFinalizingStop else {
                // A press while the start an earlier press dropped still
                // connects takes that start back: this release ends it.
                gesture = .held(.shortcut, ownsStart: gesture == .releasedBeforeStart)
                return
            }
            startHoldSession(.shortcut, outputMode: mode)
        }
    }

    func handleDictationShortcutRelease() {
        // A REFUSED modifier-hold start (secure input) forgets the key in
        // startHoldSession, so no branch below fires for it —
        // this is the moment the user's attempt gesture ends, and the
        // warning icon must end with it (owner field feedback on #90). The
        // popover line stays as the explanation until the next start
        // re-samples.
        session.clearSecureInputRefusalSignalsIfAttemptEnded()
        guard case .held(let key, let ownsStart) = gesture else { return }
        gesture = ownsStart ? .releasedBeforeStart : .idle

        switch key {
        case .modifierHold:
            if session.isDictating {
                session.endDictation(reason: "modifier hold release")
            } else if session.isConnectingRealtimeSession {
                session.statusText = DictationViewModel.StatusStrings.connectingRealtimeBackend
                return
            } else if session.isAwaitingMicrophonePermission {
                session.statusText = DictationViewModel.StatusStrings.ready
                return
            }
        case .shortcut:
            guard settings.dictationShortcutMode == .pushToTalk, ownsStart else {
                gesture = .idle
                return
            }
            if session.isConnectingRealtimeSession {
                // Keep the connection attempt alive so timeout/errors surface to the user
                // instead of silently resetting to Ready on key release.
                session.statusText = DictationViewModel.StatusStrings.connectingRealtimeBackend
                return
            } else if session.isDictating {
                session.endDictation(reason: "push-to-talk release")
            } else if session.isAwaitingMicrophonePermission {
                // Keep the dropped start until the permission callback resolves so we can
                // suppress starting if the key was released before permission was granted.
                session.statusText = DictationViewModel.StatusStrings.ready
                return
            }
        }
        clearPushToTalkShortcutSessionAttempt()
    }

    /// Modifier-only hold gesture started: push to talk, in Overlay Buffer
    /// unless Advanced → "Hold the key for Live Auto-Paste" is on (#840).
    func handleModifierOnlyHoldStart() {
        guard !session.isDictating, !session.isConnectingRealtimeSession, !session.isFinalizingStop else { return }
        startHoldSession(
            .modifierHold,
            outputMode: settings.modifierHoldLiveAutoPaste ? .liveAutoPaste : .overlayBuffer
        )
    }

    /// Starts the session a push-to-talk press or a modifier hold owns. A
    /// refused start (secure input, no backend) leaves its release nothing to
    /// stop; a refused modifier hold forgets the key altogether, so its
    /// release only ends the refusal signals.
    private func startHoldSession(_ key: PushToTalkGesture.Key, outputMode: DictationOutputMode?) {
        gesture = .held(key, ownsStart: true)
        session.startDictation(outputMode: outputMode)
        guard !session.isDictating, !session.isConnectingRealtimeSession, !session.isAwaitingMicrophonePermission
        else { return }
        gesture = key == .shortcut ? .held(.shortcut, ownsStart: false) : .idle
    }

    /// Modifier-only TAP is a toggle by contract regardless of the configured
    /// shortcut behavior: taps have no release event, so routing them through
    /// push-to-talk semantics latches dictation on with no way to stop it.
    func handleModifierOnlyTap(mode: DictationOutputMode) {
        session.toggleDictation(outputMode: mode)
    }

    func shouldCancelPushToTalkStartAfterConnect() -> Bool {
        gesture == .releasedBeforeStart
    }

    /// The session stopped or its start was dropped: no release owns it any more.
    func clearPushToTalkShortcutSessionAttempt() {
        switch gesture {
        case .held(let key, ownsStart: true): gesture = .held(key, ownsStart: false)
        case .releasedBeforeStart: gesture = .idle
        case .idle, .held(_, ownsStart: false): break
        }
    }

    /// Re-register the hotkey based on current settings.
    /// Called when modifier-only mode or modifier key selection changes.
    func applyHotKeySettingsChange() {
        switch registerCurrentHotKeys() {
        case .success:
            clearHotKeyErrors()
        case .failure(let reason):
            applyHotKeyRegistrationFailure(reason)
        }
    }

    /// Modifier-only NSEvent monitors require Accessibility trust, and
    /// `AXIsProcessTrusted()` can transiently report false at cold launch even
    /// with a persisted grant (field-hit 2026-07-05: launch-time registration
    /// died and the shortcut stayed dead until the user touched the modifier
    /// setting). Once trust lands, re-register — but never churn a live
    /// registration.
    func retryModifierOnlyHotKeyRegistrationIfNeeded() {
        guard settings.modifierOnlyHotKeyEnabled,
              settings.modifierOnlyHotKeyModifier != .chord || settings.dictationChord != nil,
              session.isAccessibilityTrusted,
              !hotKeyManager.isModifierOnlyRegistrationActive
        else { return }
        Log.modifierKeys.notice(
            "Accessibility trust granted; retrying modifier-only hotkey registration."
        )
        applyHotKeySettingsChange()
    }

    /// The chord shortcuts (#831) need Accessibility trust like the
    /// single-modifier gesture, and fail at a cold launch the same way; once
    /// trust lands, register each chord slot that isn't.
    func retryChordShortcutRegistrationIfNeeded() {
        guard session.isAccessibilityTrusted else { return }
        let slots: [(DictationShortcut?, Bool, (DictationShortcut?) -> HotKeyManager.RegistrationResult, String)] = [
            (settings.copyLastDictationShortcut, hotKeyManager.isCopyLastDictationShortcutRegistered,
             { self.hotKeyManager.registerCopyLastDictation($0) },
             HotKeyManager.copyLastDictationUnavailableErrorMessage),
        ]
        for (shortcut, registered, register, message) in slots
        where shortcut?.modifierChord != nil && !registered {
            Log.modifierKeys.notice("Accessibility trust granted; retrying a chord shortcut.")
            if case .success = register(shortcut) {
                clearHotKeyErrors(actionMessage: message)
            }
        }
    }

    /// The trigger picker in Settings > Dictation. Switching between the
    /// single-modifier gesture and per-mode shortcuts changes whether an
    /// Overlay Buffer session is reachable, so managed polishd follows.
    func applyDictationTriggerModeChange(modifierOnlyEnabled: Bool) {
        guard settings.modifierOnlyHotKeyEnabled != modifierOnlyEnabled else { return }
        let wasReachable = settings.isOverlayBufferSessionReachable
        settings.modifierOnlyHotKeyEnabled = modifierOnlyEnabled
        dropDictationChordIfAnActionSlotHoldsIt()
        applyHotKeySettingsChange()
        session.overlayReachabilityDidChange(wasReachable: wasReachable)
    }

    /// Register hotkeys based on current settings.
    /// Uses modifier-only, dual shortcuts, or legacy single shortcut depending on config.
    @discardableResult
    func registerCurrentHotKeys() -> HotKeyManager.RegistrationResult {
        if settings.modifierOnlyHotKeyEnabled {
            return hotKeyManager.registerModifierOnly(
                settings.modifierOnlyHotKeyModifier,
                holdThreshold: settings.modifierOnlyHoldDelay,
                chord: settings.dictationChord
            )
        }

        // Use dual shortcut registration
        let overlayShortcut = settings.overlayBufferShortcut
        let livePasteShortcut = settings.livePasteShortcut

        return hotKeyManager.registerDual(
            overlay: overlayShortcut,
            livePaste: livePasteShortcut
        )
    }

    /// What recording a shortcut into one slot means once the other slot is
    /// taken into account.
    enum ShortcutAssignment: Equatable {
        case applied
        /// The key already triggers the other mode. Carbon refuses a second
        /// registration of the same key on the same target, so the only way to
        /// grant it here is to take it from there — the user's call, not ours.
        /// The shortcut rides along so the caller raising the question has no
        /// optional left to unwrap.
        case needsMoveConfirmation(shortcut: DictationShortcut, from: DictationOutputMode)
        /// The key is the "Copy last dictation" shortcut. One key does one
        /// job, and there is no dictation slot to move it from, so the
        /// recorder says so and keeps what it had.
        case refused(message: String)
    }

    static let copyLastDictationConflictMessage = "Already the Copy last dictation shortcut."
    static let dictationChordConflictMessage = "Already the dictation key."

    /// The Modifier key picker. A chord (#863) that an action slot took while
    /// another key dictated is dropped rather than registered twice, and the
    /// row asks for a new one.
    func selectModifierKey(_ key: ModifierOnlyHotKeyManager.ModifierKey) {
        let wasReachable = settings.isOverlayBufferSessionReachable
        settings.modifierOnlyHotKeyModifier = key
        dropDictationChordIfAnActionSlotHoldsIt()
        applyHotKeySettingsChange()
        session.overlayReachabilityDidChange(wasReachable: wasReachable)
    }

    private func dropDictationChordIfAnActionSlotHoldsIt() {
        if let chord = settings.dictationChord, actionSlotConflict(DictationShortcut(chord: chord)) != nil {
            Log.modifierKeys.notice("dictation chord dropped: an action shortcut holds it")
            settings.modifierOnlyHotKeyChord = ""
        }
    }

    /// Records the dictation key's chord (#863), nil to clear it. Returns
    /// the sentence the recorder shows when an action slot holds that chord,
    /// nil once it is set. A chord that can't register puts the previous one
    /// back, like the other slots.
    func requestDictationChord(_ chord: ModifierChord?) -> String? {
        if let chord, let conflict = actionSlotConflict(DictationShortcut(chord: chord)) {
            return conflict
        }
        let wasReachable = settings.isOverlayBufferSessionReachable
        let previous = settings.modifierOnlyHotKeyChord
        settings.modifierOnlyHotKeyChord = chord?.storageValue ?? ""
        switch registerCurrentHotKeys() {
        case .success:
            clearHotKeyErrors()
        case .failure(let reason):
            settings.modifierOnlyHotKeyChord = previous
            _ = registerCurrentHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
        session.overlayReachabilityDidChange(wasReachable: wasReachable)
        return nil
    }

    /// The sentence for a shortcut one of the action slots already holds.
    private func actionSlotConflict(_ key: DictationShortcut) -> String? {
        if settings.copyLastDictationShortcut == key { return Self.copyLastDictationConflictMessage }
        return nil
    }

    /// True when `key` is the dictation key's chord.
    private func isDictationChord(_ key: DictationShortcut) -> Bool {
        key.modifierChord != nil && key.modifierChord == settings.dictationChord
    }

    /// Records into the Overlay Buffer slot, unless Live Auto-Paste already
    /// holds the same key. Settings asks first and calls
    /// `moveShortcutToOverlayBuffer` if the answer is yes; nothing changes in
    /// the meantime, so a declined move leaves both slots as they were.
    func requestOverlayBufferShortcut(_ shortcut: DictationShortcut?) -> ShortcutAssignment {
        if let shortcut, settings.copyLastDictationShortcut == shortcut.normalized {
            return .refused(message: Self.copyLastDictationConflictMessage)
        }
        if let shortcut, settings.livePasteShortcut == shortcut.normalized {
            return .needsMoveConfirmation(shortcut: shortcut.normalized, from: .liveAutoPaste)
        }
        updateOverlayBufferShortcut(shortcut)
        return .applied
    }

    func requestLivePasteShortcut(_ shortcut: DictationShortcut?) -> ShortcutAssignment {
        if let shortcut, settings.copyLastDictationShortcut == shortcut.normalized {
            return .refused(message: Self.copyLastDictationConflictMessage)
        }
        if let shortcut, settings.overlayBufferShortcut == shortcut.normalized {
            return .needsMoveConfirmation(shortcut: shortcut.normalized, from: .overlayBuffer)
        }
        updateLivePasteShortcut(shortcut)
        return .applied
    }

    /// Takes the key from Live Auto-Paste and gives it to Overlay Buffer, as
    /// one change: both slots move before the single registration, and a
    /// registration failure puts both back. Clearing first is what makes the
    /// registration legal at all — the same key twice on one target is
    /// `eventHotKeyExistsErr`.
    func moveShortcutToOverlayBuffer(_ shortcut: DictationShortcut) {
        let wasReachable = settings.isOverlayBufferSessionReachable
        let restore = shortcutSlotRestorer()

        settings.setLivePasteShortcut(nil)
        settings.setOverlayBufferShortcut(shortcut)

        finishShortcutMove(restore: restore)
        session.overlayReachabilityDidChange(wasReachable: wasReachable)
    }

    func moveShortcutToLivePaste(_ shortcut: DictationShortcut) {
        let wasReachable = settings.isOverlayBufferSessionReachable
        let restore = shortcutSlotRestorer()

        settings.setOverlayBufferShortcut(nil)
        settings.setLivePasteShortcut(shortcut)

        finishShortcutMove(restore: restore)
        session.overlayReachabilityDidChange(wasReachable: wasReachable)
    }

    /// Captures both slots as they stand, and returns the closure that puts
    /// them back. Verbatim, through `restoreShortcutSlots` rather than the
    /// setters: a slot can be enabled while holding a value the validator
    /// rejects, and restoring that through the setters would write the default
    /// shortcut instead — installing a trigger the user never chose, and
    /// flipping Overlay Buffer reachability into a polishd warmup.
    private func shortcutSlotRestorer() -> () -> Void {
        let snapshot = settings.shortcutSlotSnapshot
        return { [settings] in settings.restoreShortcutSlots(snapshot) }
    }

    private func finishShortcutMove(restore: () -> Void) {
        switch registerCurrentHotKeys() {
        case .success:
            clearHotKeyErrors()
        case .failure(let reason):
            restore()
            _ = registerCurrentHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
    }

    func updateOverlayBufferShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.overlayBufferShortcut
        let previousWasEnabled = settings.overlayBufferShortcutEnabled
        let wasReachable = settings.isOverlayBufferSessionReachable

        settings.setOverlayBufferShortcut(shortcut)

        switch registerCurrentHotKeys() {
        case .success:
            clearHotKeyErrors()
        case .failure(let reason):
            if previousWasEnabled {
                settings.setOverlayBufferShortcut(previousShortcut ?? SettingsStore.defaultDictationShortcut)
            } else {
                settings.setOverlayBufferShortcut(nil)
            }
            _ = registerCurrentHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
        session.overlayReachabilityDidChange(wasReachable: wasReachable)
    }

    func updateLivePasteShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.livePasteShortcut
        let previousWasEnabled = settings.livePasteShortcutEnabled

        settings.setLivePasteShortcut(shortcut)

        switch registerCurrentHotKeys() {
        case .success:
            clearHotKeyErrors()
        case .failure(let reason):
            if previousWasEnabled, let previousShortcut {
                settings.setLivePasteShortcut(previousShortcut)
            } else {
                settings.setLivePasteShortcut(nil)
            }
            _ = registerCurrentHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
    }

    /// Records the "Copy last dictation" shortcut, nil to clear it. Returns
    /// the sentence the recorder shows when the key already starts a
    /// dictation, nil once the shortcut is set. A key macOS refuses puts the
    /// previous shortcut back, like the dictation slots.
    func requestCopyLastDictationShortcut(_ shortcut: DictationShortcut?) -> String? {
        if let key = shortcut?.normalized {
            if settings.overlayBufferShortcut == key {
                return "Already the \(DictationOutputMode.overlayBuffer.displayName) shortcut."
            }
            if settings.livePasteShortcut == key {
                return "Already the \(DictationOutputMode.liveAutoPaste.displayName) shortcut."
            }
            if isDictationChord(key) {
                return Self.dictationChordConflictMessage
            }
        }
        let previous = settings.copyLastDictationShortcut
        settings.setCopyLastDictationShortcut(shortcut)
        switch hotKeyManager.registerCopyLastDictation(settings.copyLastDictationShortcut) {
        case .success:
            clearHotKeyErrors(actionMessage: HotKeyManager.copyLastDictationUnavailableErrorMessage)
        case .failure:
            settings.setCopyLastDictationShortcut(previous)
            hotKeyManager.registerCopyLastDictation(previous)
            // Its own message whatever failed, a handler install included:
            // that message is how `clearHotKeyErrors` tells the slots apart.
            applyHotKeyRegistrationFailure(.copyLastDictationShortcutUnavailable)
        }
        return nil
    }

    /// Clears a hotkey registration error once a registration succeeded.
    /// The dictation triggers and each action shortcut register apart, so
    /// each clears only its own error: a working copy shortcut must not hide
    /// a dead dictation trigger, nor the reverse. `actionMessage` is the
    /// action shortcut's own error, nil for the dictation triggers.
    private func clearHotKeyErrors(actionMessage: String? = nil) {
        if let lastError = session.lastError,
           session.currentErrorToken == .hotKeyShortcutUnavailable
            || session.currentErrorToken == .hotKeyHandlerRegistrationFailure
        {
            let actionMessages = [
                HotKeyManager.copyLastDictationUnavailableErrorMessage,
            ]
            let standingActionMessage = actionMessages.contains(lastError) ? lastError : nil
            guard standingActionMessage == actionMessage else { return }
        }
        if !session.isDictating, !session.isFinalizingStop,
           (session.currentStatusToken == .hotKeyHandlerRegistrationFailure
            || session.currentStatusToken == .hotKeyShortcutUnavailable)
        {
            session.statusText = DictationViewModel.StatusStrings.ready
        }
        if session.currentErrorToken == .hotKeyShortcutUnavailable
            || session.currentErrorToken == .hotKeyHandlerRegistrationFailure
        {
            session.lastError = nil
        }
    }

    private func applyHotKeyRegistrationFailure(_ reason: HotKeyManager.RegistrationFailure) {
        switch reason {
        case .handlerInstallFailed:
            session.statusText = HotKeyManager.handlerRegistrationErrorMessage
            session.lastError = HotKeyManager.handlerRegistrationErrorMessage
        case .shortcutUnavailable:
            session.statusText = HotKeyManager.registrationErrorStatus
            session.lastError = HotKeyManager.unavailableErrorMessage
        case .livePasteShortcutUnavailable:
            session.statusText = HotKeyManager.registrationErrorStatus
            session.lastError = HotKeyManager.livePasteUnavailableErrorMessage
        case .modifierOnlyHotKeyUnavailable:
            session.statusText = HotKeyManager.registrationErrorStatus
            session.lastError = HotKeyManager.modifierOnlyUnavailableErrorMessage
        case .copyLastDictationShortcutUnavailable:
            session.statusText = HotKeyManager.registrationErrorStatus
            session.lastError = HotKeyManager.copyLastDictationUnavailableErrorMessage
        }
    }
}

/// Where a gesture lands with no session to drive. Nothing happens, loudly.
@MainActor
private final class DetachedShortcutSession: ShortcutSessionControlling {
    var phase: DictationPhase { .idle }
    var isAccessibilityTrusted: Bool { false }
    var statusText: String {
        get { "" }
        set { note("statusText") }
    }
    var lastError: String? {
        get { nil }
        set { note("lastError") }
    }
    var currentStatusToken: DictationViewModel.StatusToken { .from("") }
    var currentErrorToken: DictationViewModel.ErrorToken? { nil }
    func startDictation(outputMode _: DictationOutputMode?) { note("startDictation") }
    func endDictation(reason _: String) { note("endDictation") }
    func toggleDictation(outputMode _: DictationOutputMode?) { note("toggleDictation") }
    func clearSecureInputRefusalSignalsIfAttemptEnded() { note("clearSecureInputRefusalSignals") }
    func overlayReachabilityDidChange(wasReachable _: Bool) { note("overlayReachabilityDidChange") }
    func copyLastDictation() { note("copyLastDictation") }

    private func note(_ what: String) {
        Log.dictation.error("shortcut: \(what, privacy: .public) reached no session owner; nothing happened")
    }
}
