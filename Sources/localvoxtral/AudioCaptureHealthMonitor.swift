import Foundation

@MainActor
final class AudioCaptureHealthMonitor {
    struct Callbacks {
        var refreshMicrophoneInputs: () -> Void
        var stopDictation: (String) -> Void
        var isDictating: () -> Bool
        var selectedInputDeviceID: () -> String
        var availableInputDevices: () -> [MicrophoneInputDevice]
        var setStatus: (String) -> Void
        var setError: (String?) -> Void
        var restartMicrophone: (String?) throws -> Void
    }

    private var callbacks: Callbacks?
    private var microphone: MicrophoneCaptureService?
    private var captureHealthTask: Task<Void, Never>?
    private var pendingAudioChangeTask: Task<Void, Never>?
    private var captureInterruptionDetectedAt: Date?
    private var startupCaptureGraceUntil: Date?
    private var startupConfigurationChangeDetected = false
    private var startupRouteStabilizationUntil: Date?
    private var startupTapRefreshAttempted = false
    private var captureRecoveryAttemptCount = 0
    private var lastNoAudioDiagnosticAt: Date?
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    static let captureInterruptionConfirmationSeconds: TimeInterval = 4.0
    static let recentAudioToleranceSeconds: TimeInterval = 1.2
    static let startupNoAudioRecoverySeconds: TimeInterval = 1.5
    static let startupCaptureGraceSeconds: TimeInterval = 1.4
    static let startupConfigChangeGraceSeconds: TimeInterval = 0.25
    static let startupConfigChangeRecoverySeconds: TimeInterval = 0.35
    static let startupBuiltinStabilizationSeconds: TimeInterval = 0.45
    static let startupExternalStabilizationSeconds: TimeInterval = 1.6
    static let maxCaptureRecoveryAttempts = 3
    static let fastAudioChangeEvaluationDelayMilliseconds = 120

    func start(microphone: MicrophoneCaptureService, callbacks: Callbacks) {
        self.microphone = microphone
        self.callbacks = callbacks
        resetState()
        startupCaptureGraceUntil = Date().addingTimeInterval(Self.startupCaptureGraceSeconds)
        restartCaptureHealthTask()
    }

    func stop() {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        pendingAudioChangeTask?.cancel()
        pendingAudioChangeTask = nil
        resetState()
        callbacks = nil
        microphone = nil
    }

    func handleConfigurationChange() {
        guard let microphone, let callbacks else { return }

        if callbacks.isDictating() {
            debugLog("configuration changed while dictating; deferring to health evaluation")
            if !microphone.hasCapturedAudioInCurrentRun() {
                startupConfigurationChangeDetected = true
                startupRouteStabilizationUntil = Date().addingTimeInterval(startupRouteStabilizationSeconds())
                startupCaptureGraceUntil = Date().addingTimeInterval(Self.startupConfigChangeGraceSeconds)
                startupTapRefreshAttempted = false
                scheduleAudioChangeEvaluation(delayMilliseconds: Self.fastAudioChangeEvaluationDelayMilliseconds)
                return
            }
        }
        scheduleAudioChangeEvaluation()
    }

    func handleInputDevicesChanged() {
        scheduleAudioChangeEvaluation()
    }

    func resetState() {
        captureInterruptionDetectedAt = nil
        startupCaptureGraceUntil = nil
        startupConfigurationChangeDetected = false
        startupRouteStabilizationUntil = nil
        startupTapRefreshAttempted = false
        captureRecoveryAttemptCount = 0
        lastNoAudioDiagnosticAt = nil
    }

    func cancelTasks() {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        pendingAudioChangeTask?.cancel()
        pendingAudioChangeTask = nil
    }

    // MARK: - Private

    private func restartCaptureHealthTask() {
        captureHealthTask?.cancel()

        captureHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard let microphone = self.microphone else { break }
                guard self.callbacks?.isDictating() == true else { continue }

                let hasRecentAudio = microphone.hasRecentCapturedAudio(
                    within: Self.recentAudioToleranceSeconds
                )
                if hasRecentAudio {
                    self.captureInterruptionDetectedAt = nil
                    self.captureRecoveryAttemptCount = 0
                    continue
                }

                self.scheduleAudioChangeEvaluation()
            }
        }
    }

    private func scheduleAudioChangeEvaluation(delayMilliseconds: Int = 350) {
        pendingAudioChangeTask?.cancel()

        pendingAudioChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            self?.evaluateAudioChange()
        }
    }

    private func evaluateAudioChange() {
        pendingAudioChangeTask = nil
        guard let microphone, let callbacks else { return }

        let previousSelection = callbacks.selectedInputDeviceID()
        callbacks.refreshMicrophoneInputs()

        guard callbacks.isDictating() else {
            captureInterruptionDetectedAt = nil
            return
        }

        if !previousSelection.isEmpty,
           callbacks.selectedInputDeviceID() == previousSelection,
           !callbacks.availableInputDevices().contains(where: { $0.id == previousSelection })
        {
            callbacks.stopDictation("selected input unavailable")
            callbacks.setError("Selected microphone became unavailable. Reconnect it or select another input.")
            return
        }

        let hasRecentAudio = microphone.hasRecentCapturedAudio(
            within: Self.recentAudioToleranceSeconds
        )
        let hasCapturedAnyAudio = microphone.hasCapturedAudioInCurrentRun()
        let isEngineRunning = microphone.isCapturing()
        if isEngineRunning && hasRecentAudio {
            captureInterruptionDetectedAt = nil
            startupConfigurationChangeDetected = false
            startupRouteStabilizationUntil = nil
            startupTapRefreshAttempted = false
            captureRecoveryAttemptCount = 0
            lastNoAudioDiagnosticAt = nil
        } else {
            if startupConfigurationChangeDetected, !hasCapturedAnyAudio {
                if !startupTapRefreshAttempted, microphone.refreshInputTapIfNeeded() {
                    startupTapRefreshAttempted = true
                    debugLog("startup config-change detected; refreshed tap before hard recovery")
                    scheduleAudioChangeEvaluation(
                        delayMilliseconds: Self.fastAudioChangeEvaluationDelayMilliseconds
                    )
                    return
                }

                if !isEngineRunning, microphone.resumeIfNeeded() {
                    scheduleAudioChangeEvaluation(
                        delayMilliseconds: Self.fastAudioChangeEvaluationDelayMilliseconds
                    )
                    return
                }

                if let stabilizationDeadline = startupRouteStabilizationUntil,
                   Date() < stabilizationDeadline
                {
                    scheduleAudioChangeEvaluation(
                        delayMilliseconds: Self.fastAudioChangeEvaluationDelayMilliseconds
                    )
                    return
                }
                startupRouteStabilizationUntil = nil
            }

            if let graceDeadline = startupCaptureGraceUntil, Date() < graceDeadline {
                scheduleAudioChangeEvaluation(
                    delayMilliseconds: startupConfigurationChangeDetected
                        ? Self.fastAudioChangeEvaluationDelayMilliseconds
                        : 350
                )
                return
            }

            startupCaptureGraceUntil = nil

            if captureInterruptionDetectedAt == nil {
                captureInterruptionDetectedAt = Date()
                scheduleAudioChangeEvaluation(
                    delayMilliseconds: startupConfigurationChangeDetected
                        ? Self.fastAudioChangeEvaluationDelayMilliseconds
                        : 350
                )
                return
            }

            let startupRecoverySeconds = startupConfigurationChangeDetected
                ? Self.startupConfigChangeRecoverySeconds
                : Self.startupNoAudioRecoverySeconds
            if !hasCapturedAnyAudio,
               let detectedAt = captureInterruptionDetectedAt,
               Date().timeIntervalSince(detectedAt) >= startupRecoverySeconds
            {
                if captureRecoveryAttemptCount < Self.maxCaptureRecoveryAttempts {
                    captureRecoveryAttemptCount += 1
                    debugLog(
                        "startup produced no audio; attempting capture restart on selected input "
                            + "attempt=\(captureRecoveryAttemptCount)/\(Self.maxCaptureRecoveryAttempts)"
                    )
                    if attemptMicrophoneRecovery() {
                        captureInterruptionDetectedAt = nil
                        startupCaptureGraceUntil = Date().addingTimeInterval(
                            startupConfigurationChangeDetected
                                ? Self.startupConfigChangeGraceSeconds
                                : Self.startupCaptureGraceSeconds
                        )
                        scheduleAudioChangeEvaluation()
                        return
                    }
                }
            }

            if let detectedAt = captureInterruptionDetectedAt,
               Date().timeIntervalSince(detectedAt) < Self.captureInterruptionConfirmationSeconds
            {
                scheduleAudioChangeEvaluation(
                    delayMilliseconds: startupConfigurationChangeDetected
                        ? Self.fastAudioChangeEvaluationDelayMilliseconds
                        : 350
                )
                return
            }

            if !isEngineRunning, microphone.resumeIfNeeded() {
                captureInterruptionDetectedAt = nil
                captureRecoveryAttemptCount = 0
                startupCaptureGraceUntil = Date().addingTimeInterval(Self.startupCaptureGraceSeconds)
                scheduleAudioChangeEvaluation()
                return
            }

            if captureRecoveryAttemptCount < Self.maxCaptureRecoveryAttempts {
                captureRecoveryAttemptCount += 1
                debugLog(
                    "attempting capture recovery on selected input "
                        + "attempt=\(captureRecoveryAttemptCount)/\(Self.maxCaptureRecoveryAttempts)"
                )
                if attemptMicrophoneRecovery() {
                    captureInterruptionDetectedAt = nil
                    startupCaptureGraceUntil = Date().addingTimeInterval(Self.startupCaptureGraceSeconds)
                    scheduleAudioChangeEvaluation()
                    return
                }
            }

            if shouldEmitNoAudioDiagnosticNow() {
                let selectedID = callbacks.selectedInputDeviceID()
                debugLog(
                    "no recent audio; engineRunning=\(isEngineRunning) selectedInput=\(selectedID)"
                )
            }
            callbacks.setStatus("Listening... (waiting for microphone audio)")
            callbacks.setError("No microphone audio frames captured yet.")
            scheduleAudioChangeEvaluation(
                delayMilliseconds: startupConfigurationChangeDetected
                    ? Self.fastAudioChangeEvaluationDelayMilliseconds
                    : 350
            )
            return
        }
    }

    private func startupRouteStabilizationSeconds() -> TimeInterval {
        guard let callbacks else { return Self.startupExternalStabilizationSeconds }
        if callbacks.selectedInputDeviceID() == "BuiltInMicrophoneDevice" {
            return Self.startupBuiltinStabilizationSeconds
        }
        return Self.startupExternalStabilizationSeconds
    }

    private func attemptMicrophoneRecovery() -> Bool {
        guard let callbacks else { return false }
        let preferredInputID = callbacks.selectedInputDeviceID()
        let inputID = preferredInputID.isEmpty ? nil : preferredInputID

        do {
            debugLog("attempting microphone recovery input=\(inputID ?? "default")")
            try callbacks.restartMicrophone(inputID)
            callbacks.setStatus("Listening...")
            debugLog("microphone recovery succeeded")
            return true
        } catch {
            callbacks.setError("Failed to recover microphone capture: \(error.localizedDescription)")
            debugLog("microphone recovery failed error=\(error.localizedDescription)")
            return false
        }
    }

    private func shouldEmitNoAudioDiagnosticNow() -> Bool {
        let now = Date()
        if let last = lastNoAudioDiagnosticAt, now.timeIntervalSince(last) < 1.0 {
            return false
        }
        lastNoAudioDiagnosticAt = now
        return true
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        print("[localvoxtral][Dictation] \(message)")
    }
}
