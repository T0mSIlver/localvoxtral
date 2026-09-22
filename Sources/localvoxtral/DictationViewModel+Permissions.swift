import Foundation

// The permission half of the view model, moved here verbatim from
// DictationViewModel.swift ahead of its extraction into
// `PermissionsCoordinator` (#432 step 4): the startup prompt pass, the
// microphone and Accessibility requests the permission rows make, and the
// two status refreshes. Nine members drop `private` so this file can reach
// them.
extension DictationViewModel {
    func requestStartupPermissionsIfNeeded() {
        guard managesRuntimeServices else { return }
        guard !suppressStartupPermissionPrompts else {
            // .notice so the line persists in the unified log archive: it is
            // the after-the-fact field proof that a CI smoke launch skipped
            // the prompt pass (.info survives only in the memory buffer).
            Log.dictation.notice(
                "startup permission prompts suppressed (LOCALVOXTRAL_SUPPRESS_STARTUP_PERMISSION_PROMPTS=1)"
            )
            return
        }
        guard settings.onboardingCompleted else {
            debugLog("startup permission prompts skipped until onboarding completes")
            return
        }
        guard !hasRequestedStartupPermissions else { return }
        hasRequestedStartupPermissions = true

        startupPermissionTask?.cancel()
        startupPermissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.prepareLLMPolishingPromptAccessIfNeeded()
            guard !Task.isCancelled else { return }
            await self.requestStartupMicrophonePermissionIfNeeded()
            guard !Task.isCancelled else { return }
            self.requestStartupAccessibilityPermissionIfNeeded()
        }
    }

    func requestStartupAccessibilityPermissionIfNeeded() {
        refreshAccessibilityTrustState()
        guard !textInsertion.isAccessibilityTrusted else { return }

        debugLog("startup accessibility permission prompt requested")
        textInsertion.requestAccessibilityPermissionIfNeeded()
    }

    func requestStartupMicrophonePermissionIfNeeded() async {
        guard !isAwaitingMicrophonePermission else { return }
        guard capturesFromMicrophone else { return }
        guard microphone.authorizationStatus() == .notDetermined else { return }

        isAwaitingMicrophonePermission = true
        debugLog("startup microphone permission prompt requested")

        let granted = await withCheckedContinuation { continuation in
            microphone.requestAccess { granted in
                continuation.resume(returning: granted)
            }
        }

        guard !Task.isCancelled else { return }
        isAwaitingMicrophonePermission = false
        debugLog("startup microphone permission result granted=\(granted)")

        guard granted else {
            if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession {
                statusText = StatusStrings.microphoneAccessDenied
            }
            lastError = Self.microphoneDeniedMessage
            return
        }

        if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession,
           currentStatusToken == .awaitingMicrophonePermission
        {
            statusText = StatusStrings.ready
        }
    }

    func requestAccessibilityPermission() {
        textInsertion.requestAccessibilityPermission()

        if textInsertion.isAccessibilityTrusted {
            statusText = StatusStrings.ready
        } else {
            statusText = StatusStrings.waitingForAccessibilityPermission
        }
    }

    /// Re-read the live microphone authorization status into the observable
    /// mirror. Reading only — never prompts. Call on appear / app activation so
    /// permission rows reflect grants made in System Settings.
    func refreshMicrophonePermissionState() {
        let status = currentMicrophoneAuthorizationStatus()
        if microphoneAuthorizationStatus != status {
            microphoneAuthorizationStatus = status
        }
    }

    /// Prompt for microphone access if it has not been decided yet. When access
    /// was already denied/restricted the system dialog no longer appears, so the
    /// permission UI routes the user to System Settings instead. Refreshes the
    /// observable status once the request resolves.
    func requestMicrophonePermission() {
        microphone.requestAccess { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMicrophonePermissionState()
            }
        }
    }

    func refreshAccessibilityTrustState() {
        let wasTrusted = textInsertion.isAccessibilityTrusted
        textInsertion.refreshAccessibilityTrustState()

        if textInsertion.isAccessibilityTrusted, !wasTrusted, !isDictating,
           (currentStatusToken == .waitingForAccessibilityPermission
               || currentStatusToken == .pasteBlockedByAccessibilityPermission)
        {
            statusText = StatusStrings.ready
        }

        if let axError = textInsertion.lastAccessibilityError {
            if lastError == nil || currentErrorToken == .accessibilityPermissionRequired {
                lastError = axError
            }
        } else if currentErrorToken == .accessibilityPermissionRequired {
            lastError = nil
        }
    }
}

#if DEBUG
extension DictationViewModel {
    @ObservationIgnored
    var debugHasRequestedStartupPermissions: Bool { hasRequestedStartupPermissions }
}
#endif
