import Foundation

// The keyboard-trigger half of the view model, moved here verbatim from
// DictationViewModel.swift ahead of its extraction into
// `ShortcutController` (#432 step 3): the push-to-talk, toggle and
// modifier-only gestures, hotkey registration and its retry, and the two
// shortcut slots. Ten members drop `private` so this file can reach them.
extension DictationViewModel {
    func handleDictationShortcutPress(mode: DictationOutputMode? = nil) {
        switch settings.dictationShortcutMode {
        case .toggle:
            hasActivePushToTalkShortcutSession = false
            if isDictating {
                stopDictation(reason: "manual toggle")
            } else if isConnectingRealtimeSession {
                statusText = StatusStrings.connectingRealtimeBackend
            } else if isFinalizingStop {
                statusText = StatusStrings.finalizingPreviousDictation
            } else {
                startDictation(outputMode: mode)
            }
        case .pushToTalk:
            guard !isPushToTalkShortcutHeld else { return }
            isPushToTalkShortcutHeld = true
            guard !isDictating, !isConnectingRealtimeSession, !isFinalizingStop else { return }
            hasActivePushToTalkShortcutSession = true
            startDictation(outputMode: mode)
            if !isDictating, !isConnectingRealtimeSession, !isAwaitingMicrophonePermission {
                hasActivePushToTalkShortcutSession = false
            }
        }
    }

    func handleDictationShortcutRelease() {
        // A REFUSED live start (secure input) resets the hold flags inside
        // handleModifierOnlyHoldStart, so no branch below fires for it —
        // this is the moment the user's attempt gesture ends, and the
        // warning icon must end with it (owner field feedback on #90). The
        // popover line stays as the explanation until the next start
        // re-samples.
        clearSecureInputRefusalSignalsIfAttemptEnded()
        // Modifier-only hold release
        if isModifierOnlyHoldActive {
            isModifierOnlyHoldActive = false
            isPushToTalkShortcutHeld = false
            if isDictating {
                stopDictation(reason: "modifier hold release")
            } else if isConnectingRealtimeSession {
                statusText = StatusStrings.connectingRealtimeBackend
                return
            } else if isAwaitingMicrophonePermission {
                statusText = StatusStrings.ready
                return
            }
            clearPushToTalkShortcutSessionAttempt()
            return
        }

        guard isPushToTalkShortcutHeld else { return }
        isPushToTalkShortcutHeld = false

        guard settings.dictationShortcutMode == .pushToTalk else {
            hasActivePushToTalkShortcutSession = false
            return
        }
        guard hasActivePushToTalkShortcutSession else { return }

        if isConnectingRealtimeSession {
            // Keep the connection attempt alive so timeout/errors surface to the user
            // instead of silently resetting to Ready on key release.
            statusText = StatusStrings.connectingRealtimeBackend
            return
        } else if isDictating {
            stopDictation(reason: "push-to-talk release")
        } else if isAwaitingMicrophonePermission {
            // Keep the pending-session flag until the permission callback resolves so we can
            // suppress starting if the key was released before permission was granted.
            statusText = StatusStrings.ready
            return
        }
        clearPushToTalkShortcutSessionAttempt()
    }

    /// Modifier-only hold gesture started — use push-to-talk semantics with live auto-paste.
    func handleModifierOnlyHoldStart() {
        guard !isDictating, !isConnectingRealtimeSession, !isFinalizingStop else { return }
        isModifierOnlyHoldActive = true
        isPushToTalkShortcutHeld = true
        hasActivePushToTalkShortcutSession = true
        startDictation(outputMode: .liveAutoPaste)
        if !isDictating, !isConnectingRealtimeSession, !isAwaitingMicrophonePermission {
            hasActivePushToTalkShortcutSession = false
            isModifierOnlyHoldActive = false
            isPushToTalkShortcutHeld = false
        }
    }

    /// Modifier-only TAP is a toggle by contract regardless of the configured
    /// shortcut behavior: taps have no release event, so routing them through
    /// push-to-talk semantics latches dictation on with no way to stop it.
    func handleModifierOnlyTap(mode: DictationOutputMode) {
        toggleDictation(outputMode: mode)
    }

    func shouldCancelPushToTalkStartAfterConnect() -> Bool {
        hasActivePushToTalkShortcutSession
            && !isPushToTalkShortcutHeld
    }

    func clearPushToTalkShortcutSessionAttempt() {
        hasActivePushToTalkShortcutSession = false
    }

    /// Re-register the hotkey based on current settings.
    /// Called when modifier-only mode or modifier key selection changes.
    func applyHotKeySettingsChange() {
        switch registerCurrentHotKeys() {
        case .success:
            if !isDictating, !isFinalizingStop,
               (currentStatusToken == .hotKeyHandlerRegistrationFailure
                || currentStatusToken == .hotKeyShortcutUnavailable)
            {
                statusText = StatusStrings.ready
            }
            if currentErrorToken == .hotKeyShortcutUnavailable
                || currentErrorToken == .hotKeyHandlerRegistrationFailure
            {
                lastError = nil
            }
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
              textInsertion.isAccessibilityTrusted,
              !hotKeyManager.isModifierOnlyRegistrationActive
        else { return }
        Log.modifierKeys.notice(
            "Accessibility trust granted; retrying modifier-only hotkey registration."
        )
        applyHotKeySettingsChange()
    }

    /// The trigger picker in Settings > Dictation. Switching between the
    /// single-modifier gesture and per-mode shortcuts changes whether an
    /// Overlay Buffer session is reachable, so managed polishd follows.
    func applyDictationTriggerModeChange(modifierOnlyEnabled: Bool) {
        guard settings.modifierOnlyHotKeyEnabled != modifierOnlyEnabled else { return }
        let wasReachable = settings.isOverlayBufferSessionReachable
        settings.modifierOnlyHotKeyEnabled = modifierOnlyEnabled
        applyHotKeySettingsChange()
        engines.handleOverlayReachabilityTransition(wasReachable: wasReachable)
    }

    /// Register hotkeys based on current settings.
    /// Uses modifier-only, dual shortcuts, or legacy single shortcut depending on config.
    @discardableResult
    func registerCurrentHotKeys() -> HotKeyManager.RegistrationResult {
        if settings.modifierOnlyHotKeyEnabled {
            return hotKeyManager.registerModifierOnly(
                settings.modifierOnlyHotKeyModifier,
                holdThreshold: settings.modifierOnlyHoldDelay
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

    func updateDictationShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.dictationShortcut
        let previousWasEnabled = settings.dictationShortcutEnabled

        settings.setDictationShortcut(shortcut)

        switch registerCurrentHotKeys() {
        case .success:
            if !isDictating, !isFinalizingStop,
               (currentStatusToken == .hotKeyHandlerRegistrationFailure
                || currentStatusToken == .hotKeyShortcutUnavailable)
            {
                statusText = StatusStrings.ready
            }

            if currentErrorToken == .hotKeyShortcutUnavailable
                || currentErrorToken == .hotKeyHandlerRegistrationFailure
            {
                lastError = nil
            }
            return
        case .failure(let reason):
            if previousWasEnabled {
                settings.setDictationShortcut(previousShortcut ?? SettingsStore.defaultDictationShortcut)
            } else {
                settings.setDictationShortcut(nil)
            }
            _ = registerCurrentHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
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
    }

    /// Records into the Overlay Buffer slot, unless Live Auto-Paste already
    /// holds the same key. Settings asks first and calls
    /// `moveShortcutToOverlayBuffer` if the answer is yes; nothing changes in
    /// the meantime, so a declined move leaves both slots as they were.
    func requestOverlayBufferShortcut(_ shortcut: DictationShortcut?) -> ShortcutAssignment {
        if let shortcut, settings.livePasteShortcut == shortcut.normalized {
            return .needsMoveConfirmation(shortcut: shortcut.normalized, from: .liveAutoPaste)
        }
        updateOverlayBufferShortcut(shortcut)
        return .applied
    }

    func requestLivePasteShortcut(_ shortcut: DictationShortcut?) -> ShortcutAssignment {
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
        engines.handleOverlayReachabilityTransition(wasReachable: wasReachable)
    }

    func moveShortcutToLivePaste(_ shortcut: DictationShortcut) {
        let wasReachable = settings.isOverlayBufferSessionReachable
        let restore = shortcutSlotRestorer()

        settings.setOverlayBufferShortcut(nil)
        settings.setLivePasteShortcut(shortcut)

        finishShortcutMove(restore: restore)
        engines.handleOverlayReachabilityTransition(wasReachable: wasReachable)
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
        engines.handleOverlayReachabilityTransition(wasReachable: wasReachable)
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

    private func clearHotKeyErrors() {
        if !isDictating, !isFinalizingStop,
           (currentStatusToken == .hotKeyHandlerRegistrationFailure
            || currentStatusToken == .hotKeyShortcutUnavailable)
        {
            statusText = StatusStrings.ready
        }
        if currentErrorToken == .hotKeyShortcutUnavailable
            || currentErrorToken == .hotKeyHandlerRegistrationFailure
        {
            lastError = nil
        }
    }

    private func applyHotKeyRegistrationFailure(_ reason: HotKeyManager.RegistrationFailure) {
        switch reason {
        case .handlerInstallFailed:
            statusText = HotKeyManager.handlerRegistrationErrorMessage
            lastError = HotKeyManager.handlerRegistrationErrorMessage
        case .shortcutUnavailable:
            statusText = HotKeyManager.registrationErrorStatus
            lastError = HotKeyManager.unavailableErrorMessage
        case .livePasteShortcutUnavailable:
            statusText = HotKeyManager.registrationErrorStatus
            lastError = HotKeyManager.livePasteUnavailableErrorMessage
        case .modifierOnlyHotKeyUnavailable:
            statusText = HotKeyManager.registrationErrorStatus
            lastError = HotKeyManager.modifierOnlyUnavailableErrorMessage
        }
    }
}

#if DEBUG
extension DictationViewModel {
    func debugHandleDictationShortcutPressForTesting(mode: DictationOutputMode? = nil) {
        handleDictationShortcutPress(mode: mode)
    }

    func debugHandleDictationShortcutReleaseForTesting() {
        handleDictationShortcutRelease()
    }

    func debugHandleModifierOnlyTapForTesting(mode: DictationOutputMode) {
        handleModifierOnlyTap(mode: mode)
    }

    func debugHandleModifierOnlyHoldStartForTesting() {
        handleModifierOnlyHoldStart()
    }

    var debugIsPushToTalkShortcutHeldForTesting: Bool {
        isPushToTalkShortcutHeld
    }

    func debugSetPushToTalkShortcutStateForTesting(
        isHeld: Bool,
        hasActiveSession: Bool
    ) {
        isPushToTalkShortcutHeld = isHeld
        hasActivePushToTalkShortcutSession = hasActiveSession
    }

    func debugSetModifierOnlyHoldStateForTesting(isActive: Bool) {
        isModifierOnlyHoldActive = isActive
    }

    var debugCurrentHotKeyRegistrationKindForTesting: HotKeyManager.DebugRegistrationKind {
        hotKeyManager.debugCurrentRegistrationKind
    }
}
#endif
