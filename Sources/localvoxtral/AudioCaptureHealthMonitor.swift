import Foundation
import os

@MainActor
final class AudioCaptureHealthMonitor {
    struct Callbacks {
        var refreshMicrophoneInputs: () -> Void
        var stopForSilentInput: () -> Void
        var stopForUnavailableInput: () -> Void
        var isDictating: () -> Bool
        var selectedInputDeviceID: () -> String
        var availableInputDevices: () -> [MicrophoneInputDevice]
        var setStatus: (String) -> Void
        var setError: (String?) -> Void
        var restartMicrophone: (String?) throws -> Void
    }

    private var callbacks: Callbacks?
    private var microphone: (any MicrophoneCapturing)?
    /// The input the running capture was started on. The selection cannot
    /// stand in for it: a device refresh moves the selection to a fallback
    /// as soon as the selected mic disappears.
    private var captureInputID = ""
    /// The session's clock: the health poll and the evaluation debounce
    /// sleep on it, and the grace and recovery deadlines read its `now`.
    private var clock = SessionClock.live
    private var captureHealthTask: Task<Void, Never>?
    private var pendingAudioChangeTask: Task<Void, Never>?
    private var silentInputStopTask: Task<Void, Never>?
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
    /// How long a mic that still sends no frames after the last recovery
    /// attempt keeps the dictation going. Past it the dictation stops and
    /// commits what it has (owner decision on #1865, reversing #314): the
    /// user would otherwise keep talking into nothing.
    static let silentInputStopSeconds: TimeInterval = 10
    static let fastAudioChangeEvaluationDelayMilliseconds = 120

    var isMonitoring: Bool { callbacks != nil }

    /// `captureInputID` is the input the capture already runs on; nil reads
    /// the selection.
    func start(
        microphone: any MicrophoneCapturing, callbacks: Callbacks, clock: SessionClock,
        captureInputID: String? = nil
    ) {
        self.microphone = microphone
        self.callbacks = callbacks
        self.clock = clock
        self.captureInputID = captureInputID ?? callbacks.selectedInputDeviceID()
        resetState()
        startupCaptureGraceUntil = clock.now().addingTimeInterval(Self.startupCaptureGraceSeconds)
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
        captureInputID = ""
    }

    func handleConfigurationChange() {
        guard let microphone, let callbacks else { return }

        if callbacks.isDictating() {
            debugLog("configuration changed while dictating; deferring to health evaluation")
            if !microphone.hasCapturedAudioInCurrentRun() {
                startupConfigurationChangeDetected = true
                startupRouteStabilizationUntil = clock.now().addingTimeInterval(startupRouteStabilizationSeconds())
                startupCaptureGraceUntil = clock.now().addingTimeInterval(Self.startupConfigChangeGraceSeconds)
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

    #if DEBUG
    /// Runs the pending device/route evaluation now instead of after its
    /// debounce sleep.
    func debugEvaluateAudioChangeNow() {
        pendingAudioChangeTask?.cancel()
        evaluateAudioChange()
    }
    #endif

    func resetState() {
        captureInterruptionDetectedAt = nil
        startupCaptureGraceUntil = nil
        startupConfigurationChangeDetected = false
        startupRouteStabilizationUntil = nil
        startupTapRefreshAttempted = false
        captureRecoveryAttemptCount = 0
        disarmSilentInputStop()
        lastNoAudioDiagnosticAt = nil
    }

    func cancelTasks() {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        pendingAudioChangeTask?.cancel()
        pendingAudioChangeTask = nil
        disarmSilentInputStop()
    }

    // MARK: - Private

    private func restartCaptureHealthTask() {
        captureHealthTask?.cancel()

        let sleep = clock.sleep
        captureHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(.milliseconds(600))
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
                    self.disarmSilentInputStop()
                    continue
                }

                self.scheduleAudioChangeEvaluation()
            }
        }
    }

    private func scheduleAudioChangeEvaluation(delayMilliseconds: Int = 350) {
        pendingAudioChangeTask?.cancel()

        let sleep = clock.sleep
        pendingAudioChangeTask = Task { [weak self] in
            await sleep(.milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            self?.evaluateAudioChange()
        }
    }

    private func evaluateAudioChange() {
        pendingAudioChangeTask = nil
        guard let microphone, let callbacks else { return }

        callbacks.refreshMicrophoneInputs()

        guard callbacks.isDictating() else {
            captureInterruptionDetectedAt = nil
            return
        }

        if !captureInputID.isEmpty,
           !callbacks.availableInputDevices().contains(where: { $0.id == captureInputID })
        {
            callbacks.stopForUnavailableInput()
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
            disarmSilentInputStop()
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
                   clock.now() < stabilizationDeadline
                {
                    scheduleAudioChangeEvaluation(
                        delayMilliseconds: Self.fastAudioChangeEvaluationDelayMilliseconds
                    )
                    return
                }
                startupRouteStabilizationUntil = nil
            }

            if let graceDeadline = startupCaptureGraceUntil, clock.now() < graceDeadline {
                scheduleAudioChangeEvaluation(
                    delayMilliseconds: startupConfigurationChangeDetected
                        ? Self.fastAudioChangeEvaluationDelayMilliseconds
                        : 350
                )
                return
            }

            startupCaptureGraceUntil = nil

            if captureInterruptionDetectedAt == nil {
                captureInterruptionDetectedAt = clock.now()
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
               clock.now().timeIntervalSince(detectedAt) >= startupRecoverySeconds
            {
                if captureRecoveryAttemptCount < Self.maxCaptureRecoveryAttempts {
                    captureRecoveryAttemptCount += 1
                    armSilentInputStopAfterLastAttempt()
                    debugLog(
                        "startup produced no audio; attempting capture restart on selected input "
                            + "attempt=\(captureRecoveryAttemptCount)/\(Self.maxCaptureRecoveryAttempts)"
                    )
                    if attemptMicrophoneRecovery() {
                        captureInterruptionDetectedAt = nil
                        startupCaptureGraceUntil = clock.now().addingTimeInterval(
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
               clock.now().timeIntervalSince(detectedAt) < Self.captureInterruptionConfirmationSeconds
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
                disarmSilentInputStop()
                startupCaptureGraceUntil = clock.now().addingTimeInterval(Self.startupCaptureGraceSeconds)
                scheduleAudioChangeEvaluation()
                return
            }

            if captureRecoveryAttemptCount < Self.maxCaptureRecoveryAttempts {
                captureRecoveryAttemptCount += 1
                armSilentInputStopAfterLastAttempt()
                debugLog(
                    "attempting capture recovery on selected input "
                        + "attempt=\(captureRecoveryAttemptCount)/\(Self.maxCaptureRecoveryAttempts)"
                )
                if attemptMicrophoneRecovery() {
                    captureInterruptionDetectedAt = nil
                    startupCaptureGraceUntil = clock.now().addingTimeInterval(Self.startupCaptureGraceSeconds)
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

    /// Arms the stop when the attempt just made was the last one: if the mic
    /// still sends nothing `silentInputStopSeconds` later, the dictation
    /// stops. Audio coming back, or a fresh round of attempts, disarms it.
    private func armSilentInputStopAfterLastAttempt() {
        guard captureRecoveryAttemptCount >= Self.maxCaptureRecoveryAttempts else { return }
        silentInputStopTask?.cancel()
        let sleep = clock.sleep
        silentInputStopTask = Task { [weak self] in
            await sleep(.seconds(Self.silentInputStopSeconds))
            guard !Task.isCancelled, let self, let microphone = self.microphone,
                  let callbacks = self.callbacks, callbacks.isDictating(),
                  !microphone.hasRecentCapturedAudio(within: Self.recentAudioToleranceSeconds)
            else { return }
            self.silentInputStopTask = nil
            callbacks.stopForSilentInput()
        }
    }

    private func disarmSilentInputStop() {
        silentInputStopTask?.cancel()
        silentInputStopTask = nil
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
            captureInputID = preferredInputID
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
        let now = clock.now()
        if let last = lastNoAudioDiagnosticAt, now.timeIntervalSince(last) < 1.0 {
            return false
        }
        lastNoAudioDiagnosticAt = now
        return true
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.dictation.debug("\(message)")
    }
}
