import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Observation

@MainActor
@Observable
final class DictationViewModel {
    private(set) var isDictating = false
    private(set) var transcriptText = ""
    private(set) var livePartialText = ""
    private(set) var statusText = "Ready"
    private(set) var lastError: String?
    private(set) var lastFinalSegment = ""
    private(set) var isAccessibilityTrusted = false
    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""

    let settings: SettingsStore

    private let microphone = MicrophoneCaptureService()
    private let realtimeClient = RealtimeWebSocketClient()
    private let audioChunkBuffer = AudioChunkBuffer()
    private let audioSendInterval: TimeInterval = 0.1
    private var commitTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var hasPromptedForAccessibilityPermission = false
    private var hasShownAccessibilityError = false
    private var pendingAudioChangeTask: Task<Void, Never>?
    private var captureInterruptionDetectedAt: Date?
    private var startupCaptureGraceUntil: Date?
    private var hasAttemptedCaptureRecovery = false
    private var pendingRealtimeInsertionText = ""
    private var insertionRetryTask: Task<Void, Never>?
    private var axInsertionSuccessCount = 0
    private var keyboardFallbackSuccessCount = 0
    private var modifierDeferredInsertionCount = 0

    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private static let accessibilityErrorMessage =
        "Enable Accessibility for SuperVoxtral in System Settings > Privacy & Security > Accessibility."

    init(settings: SettingsStore) {
        self.settings = settings

        realtimeClient.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }

        microphone.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleAudioChangeEvaluation()
            }
        }

        microphone.onInputDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleAudioChangeEvaluation()
            }
        }

        registerGlobalHotkey()
        refreshAccessibilityTrustState()
        refreshMicrophoneInputs()
    }

    private func registerGlobalHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr,
                      hotKeyID.signature == DictationViewModel.hotKeySignature,
                      hotKeyID.id == 1
                else {
                    return noErr
                }

                let viewModel = Unmanaged<DictationViewModel>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    viewModel.toggleDictation()
                }

                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyHandlerRef
        )

        guard installStatus == noErr else {
            statusText = "Failed to register global hotkey handler."
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey) | UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            statusText = "Failed to register global hotkey."
            if let hotKeyHandlerRef {
                RemoveEventHandler(hotKeyHandlerRef)
                self.hotKeyHandlerRef = nil
            }
        }
    }

    func toggleDictation() {
        if isDictating {
            stopDictation()
        } else {
            startDictation()
        }
    }

    func refreshMicrophoneInputs() {
        let devices = microphone.availableInputDevices()
        if availableInputDevices != devices {
            availableInputDevices = devices
        }

        guard !devices.isEmpty else {
            if !selectedInputDeviceID.isEmpty {
                selectedInputDeviceID = ""
            }
            if !settings.selectedInputDeviceUID.isEmpty {
                settings.selectedInputDeviceUID = ""
            }
            return
        }

        let savedSelection = settings.selectedInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSelection: String

        if devices.contains(where: { $0.id == savedSelection }) {
            resolvedSelection = savedSelection
        } else if let defaultID = microphone.defaultInputDeviceID(),
                  devices.contains(where: { $0.id == defaultID })
        {
            resolvedSelection = defaultID
        } else {
            resolvedSelection = devices[0].id
        }

        if selectedInputDeviceID != resolvedSelection {
            selectedInputDeviceID = resolvedSelection
        }
        if settings.selectedInputDeviceUID != resolvedSelection {
            settings.selectedInputDeviceUID = resolvedSelection
        }
    }

    func selectMicrophoneInput(id: String) {
        guard !id.isEmpty else { return }
        guard selectedInputDeviceID != id else { return }

        selectedInputDeviceID = id
        settings.selectedInputDeviceUID = id

        guard isDictating else { return }
        stopDictation()
        startDictation()
    }

    func startDictation() {
        guard !isDictating else { return }
        refreshMicrophoneInputs()
        lastError = nil
        let deniedMessage = "Grant microphone access in System Settings > Privacy & Security > Microphone."

        switch microphone.authorizationStatus() {
        case .authorized:
            beginDictationSession()
        case .notDetermined:
            statusText = "Requesting microphone permission..."
            microphone.requestAccess { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard granted else {
                        self.statusText = "Microphone access denied."
                        self.lastError = deniedMessage
                        return
                    }
                    self.beginDictationSession()
                }
            }
        case .denied, .restricted:
            statusText = "Microphone access denied."
            lastError = deniedMessage
        }
    }

    func stopDictation() {
        guard isDictating else { return }

        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        insertionRetryTask?.cancel()
        insertionRetryTask = nil
        pendingAudioChangeTask?.cancel()
        pendingAudioChangeTask = nil
        captureInterruptionDetectedAt = nil
        startupCaptureGraceUntil = nil
        hasAttemptedCaptureRecovery = false

        microphone.stop()
        flushBufferedAudio()
        realtimeClient.disconnectAfterFinalCommitIfNeeded()

        isDictating = false
        livePartialText = ""
        statusText = "Ready"
        logInsertionDiagnostics()

        if !pendingRealtimeInsertionText.isEmpty {
            lastError = "Some realtime text could not be inserted into the focused app."
            pendingRealtimeInsertionText = ""
        }

        if lastError?.localizedCaseInsensitiveContains("websocket receive failed") == true {
            lastError = nil
        }
    }

    func clearTranscript() {
        transcriptText = ""
        livePartialText = ""
        lastFinalSegment = ""
        lastError = nil
    }

    func copyTranscript() {
        let fullText = fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullText, forType: .string)

        statusText = "Transcript copied."
    }

    func copyLatestSegment(updateStatus: Bool = true) {
        let segment = lastFinalSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(segment, forType: .string)

        if updateStatus {
            statusText = "Latest segment copied."
        }
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAccessibilityTrustState()

        if isAccessibilityTrusted {
            clearAccessibilityErrorIfNeeded()
            statusText = "Accessibility permission enabled."
        } else {
            setAccessibilityErrorIfNeeded()
            statusText = "Waiting for Accessibility permission."
        }
    }

    func pasteLatestSegment() {
        let segment = lastFinalSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }

        refreshAccessibilityTrustState()

        let directInsertResult = insertTextIntoFocusedField(segment)
        if directInsertResult == .insertedByAccessibility
            || directInsertResult == .insertedByKeyboardFallback
        {
            statusText = "Pasted latest segment."
            return
        }

        if pasteUsingCommandV(segment) {
            statusText = "Pasted latest segment."
            return
        }

        if !isAccessibilityTrusted {
            setAccessibilityErrorIfNeeded()
            statusText = "Paste blocked by Accessibility permission."
        } else {
            statusText = "Unable to paste latest segment."
        }
    }

    var fullTranscript: String {
        let finalPart = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let livePart = livePartialText.trimmingCharacters(in: .whitespacesAndNewlines)

        if finalPart.isEmpty { return livePart }
        if livePart.isEmpty { return finalPart }
        return finalPart + "\n" + livePart
    }

    private func beginDictationSession() {
        guard let endpoint = settings.resolvedWebSocketURL else {
            statusText = "Invalid endpoint URL."
            lastError = "Set a valid `ws://` or `wss://` realtime endpoint in Settings."
            return
        }

        let model = settings.effectiveModelName

        do {
            let chunkBuffer = audioChunkBuffer
            chunkBuffer.clear()
            let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID
            try microphone.start(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }

            isDictating = true
            livePartialText = ""
            statusText = "Listening..."
            pendingRealtimeInsertionText = ""
            captureInterruptionDetectedAt = nil
            startupCaptureGraceUntil = Date().addingTimeInterval(1.2)
            hasAttemptedCaptureRecovery = false
            resetInsertionDiagnostics()

            let client = realtimeClient
            try client.connect(configuration: .init(
                endpoint: endpoint,
                apiKey: settings.trimmedAPIKey,
                model: model
            ))

            restartAudioSendTask()
            restartCommitTask()
            restartInsertionRetryTask()
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            microphone.stop()
            realtimeClient.disconnect()
            isDictating = false
            captureInterruptionDetectedAt = nil
            startupCaptureGraceUntil = nil
            hasAttemptedCaptureRecovery = false
        }
    }

    private func restartCommitTask() {
        commitTask?.cancel()

        let interval = min(1.0, max(0.1, settings.commitIntervalSeconds))
        let client = realtimeClient
        commitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                guard self != nil else { break }
                client.sendCommit(final: false)
            }
        }
    }

    private func restartAudioSendTask() {
        audioSendTask?.cancel()

        let client = realtimeClient
        let chunkBuffer = audioChunkBuffer
        audioSendTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.audioSendInterval ?? 0.1))
                guard !Task.isCancelled else { break }
                guard self != nil else { break }

                let bufferedChunk = chunkBuffer.takeAll()
                guard !bufferedChunk.isEmpty else { continue }
                client.sendAudioChunk(bufferedChunk)
            }
        }
    }

    private func flushBufferedAudio() {
        let chunk = audioChunkBuffer.takeAll()
        guard !chunk.isEmpty else { return }
        realtimeClient.sendAudioChunk(chunk)
    }

    private func handle(event: RealtimeWebSocketClient.Event) {
        switch event {
        case .connected:
            statusText = isDictating ? "Listening..." : "Ready"

        case .disconnected:
            guard isDictating else { return }
            stopDictation()
            lastError = "Connection lost. Dictation stopped."

        case .status(let message):
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !isDictating {
                statusText = "Ready"
                return
            }

            if normalized.contains("session") || normalized.contains("connected") || normalized.contains("disconnected") {
                statusText = "Listening..."
            } else {
                statusText = message
            }

        case .partialTranscript(let delta):
            guard isDictating, !delta.isEmpty else { return }
            livePartialText += delta
            enqueueRealtimeInsertion(delta)
            statusText = "Transcribing..."

        case .finalTranscript(let text):
            let finalizedSegment = resolvedFinalizedSegment(from: text)
            guard !finalizedSegment.isEmpty else {
                livePartialText = ""
                return
            }

            if transcriptText.isEmpty {
                transcriptText = finalizedSegment
            } else {
                transcriptText += "\n" + finalizedSegment
            }

            lastFinalSegment = finalizedSegment
            livePartialText = ""
            statusText = "Listening..."

            if settings.autoCopyEnabled {
                copyLatestSegment(updateStatus: false)
            }

        case .error(let message):
            let normalized = message.lowercased()
            if !isDictating {
                if normalized.contains("websocket receive failed")
                    || normalized.contains("cancelled")
                    || normalized.contains("socket is not connected")
                {
                    statusText = "Ready"
                    return
                }

                statusText = "Ready"
                return
            }

            statusText = "Realtime error."
            lastError = message
        }
    }

    private enum TextInsertResult {
        case insertedByAccessibility
        case insertedByKeyboardFallback
        case deferredByActiveModifiers
        case failed
    }

    private enum KeyboardFallbackBehavior {
        case always
        case deferIfModifierActive
    }

    private func enqueueRealtimeInsertion(_ text: String) {
        guard !text.isEmpty else { return }
        pendingRealtimeInsertionText.append(text)
        flushPendingRealtimeInsertion()
    }

    private func flushPendingRealtimeInsertion() {
        guard !pendingRealtimeInsertionText.isEmpty else { return }

        let result = insertTextIntoFocusedField(
            pendingRealtimeInsertionText,
            keyboardFallbackBehavior: .deferIfModifierActive
        )

        switch result {
        case .insertedByAccessibility, .insertedByKeyboardFallback:
            pendingRealtimeInsertionText.removeAll(keepingCapacity: true)
        case .deferredByActiveModifiers:
            // Retry task will flush once modifiers are released.
            break
        case .failed:
            // Keep pending text and retry on subsequent task ticks.
            break
        }
    }

    private func insertTextIntoFocusedField(
        _ text: String,
        keyboardFallbackBehavior: KeyboardFallbackBehavior = .always
    ) -> TextInsertResult {
        guard !text.isEmpty else { return .insertedByAccessibility }
        refreshAccessibilityTrustState()

        if insertTextUsingAccessibility(text) {
            clearAccessibilityErrorIfNeeded()
            axInsertionSuccessCount += 1
            return .insertedByAccessibility
        }

        if keyboardFallbackBehavior == .deferIfModifierActive,
           shouldSuppressKeyboardFallbackForActiveModifiers()
        {
            modifierDeferredInsertionCount += 1
            return .deferredByActiveModifiers
        }

        if postUnicodeTextEvents(text) {
            clearAccessibilityErrorIfNeeded()
            keyboardFallbackSuccessCount += 1
            return .insertedByKeyboardFallback
        }

        if !isAccessibilityTrusted {
            promptForAccessibilityPermissionIfNeeded()
            setAccessibilityErrorIfNeeded()
        }

        return .failed
    }

    private func insertTextUsingAccessibility(_ text: String) -> Bool {
        guard isAccessibilityTrusted else { return false }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusStatus == .success,
              let focusedObject
        else {
            return false
        }

        let focusedElement = focusedObject as! AXUIElement

        if AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            return true
        }

        return replaceSelectedTextRange(in: focusedElement, with: text)
    }

    private func replaceSelectedTextRange(in element: AXUIElement, with text: String) -> Bool {
        var valueObject: AnyObject?
        let valueStatus = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObject
        )

        guard valueStatus == .success,
              let currentValue = valueObject as? String
        else {
            return false
        }

        var selectedRangeObject: CFTypeRef?
        let selectedRangeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeObject
        )

        guard selectedRangeStatus == .success,
              let selectedRangeObject,
              CFGetTypeID(selectedRangeObject) == AXValueGetTypeID()
        else {
            return false
        }

        let selectedRangeValue = unsafeDowncast(selectedRangeObject, to: AXValue.self)
        guard
              AXValueGetType(selectedRangeValue) == .cfRange
        else {
            return false
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange) else {
            return false
        }

        let currentValueNSString = currentValue as NSString
        let safeLocation = min(max(0, selectedRange.location), currentValueNSString.length)
        let safeLength = min(max(0, selectedRange.length), currentValueNSString.length - safeLocation)

        let replaced = currentValueNSString.replacingCharacters(
            in: NSRange(location: safeLocation, length: safeLength),
            with: text
        )

        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            replaced as CFTypeRef
        ) == .success else {
            return false
        }

        var cursorRange = CFRange(location: safeLocation + (text as NSString).length, length: 0)
        if let newSelection = AXValueCreate(.cfRange, &cursorRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                newSelection
            )
        }

        return true
    }

    private func resolvedFinalizedSegment(from finalText: String) -> String {
        let trimmedFinal = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFinal.isEmpty {
            return trimmedFinal
        }

        return livePartialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func postUnicodeTextEvents(_ text: String) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState)
        else {
            return false
        }

        var didPostAnyEvent = false
        let utf16 = Array(text.utf16)
        let chunkSize = 20

        for i in stride(from: 0, to: utf16.count, by: chunkSize) {
            let end = min(i + chunkSize, utf16.count)
            var chunk = Array(utf16[i ..< end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                continue
            }

            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
            didPostAnyEvent = true
        }

        return didPostAnyEvent
    }

    private func shouldSuppressKeyboardFallbackForActiveModifiers() -> Bool {
        let modifierKeyCodes: [CGKeyCode] = [
            54, // right command
            55, // left command
            58, // left option
            61, // right option
            59, // left control
            62, // right control
            63, // function
        ]

        return modifierKeyCodes.contains { CGEventSource.keyState(.combinedSessionState, key: $0) }
    }

    private func restartInsertionRetryTask() {
        insertionRetryTask?.cancel()

        insertionRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard self.isDictating else { continue }
                guard !self.pendingRealtimeInsertionText.isEmpty else { continue }
                self.flushPendingRealtimeInsertion()
            }
        }
    }

    private func resetInsertionDiagnostics() {
        axInsertionSuccessCount = 0
        keyboardFallbackSuccessCount = 0
        modifierDeferredInsertionCount = 0
    }

    private func logInsertionDiagnostics() {
        let totalInsertions = axInsertionSuccessCount + keyboardFallbackSuccessCount + modifierDeferredInsertionCount
        guard totalInsertions > 0 else { return }

        print(
            "[SuperVoxtral] insertion-paths "
                + "ax=\(axInsertionSuccessCount) "
                + "keyboard_fallback=\(keyboardFallbackSuccessCount) "
                + "deferred_modifiers=\(modifierDeferredInsertionCount)"
        )
    }

    private func pasteUsingCommandV(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private func promptForAccessibilityPermissionIfNeeded() {
        guard !hasPromptedForAccessibilityPermission else { return }
        hasPromptedForAccessibilityPermission = true

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAccessibilityTrustState()
    }

    func refreshAccessibilityTrustState() {
        let trusted = AXIsProcessTrusted()
        if isAccessibilityTrusted != trusted {
            isAccessibilityTrusted = trusted
        }

        guard trusted else { return }
        hasShownAccessibilityError = false
        if lastError == Self.accessibilityErrorMessage {
            lastError = nil
        }
    }

    private func scheduleAudioChangeEvaluation() {
        pendingAudioChangeTask?.cancel()

        pendingAudioChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.evaluateAudioChange()
        }
    }

    private func evaluateAudioChange() {
        pendingAudioChangeTask = nil
        let previousSelection = selectedInputDeviceID
        refreshMicrophoneInputs()

        guard isDictating else {
            captureInterruptionDetectedAt = nil
            return
        }

        if microphone.isCapturing() {
            captureInterruptionDetectedAt = nil
            hasAttemptedCaptureRecovery = false
        } else {
            if let graceDeadline = startupCaptureGraceUntil, Date() < graceDeadline {
                scheduleAudioChangeEvaluation()
                return
            }

            startupCaptureGraceUntil = nil

            if captureInterruptionDetectedAt == nil {
                captureInterruptionDetectedAt = Date()
                scheduleAudioChangeEvaluation()
                return
            }

            if let detectedAt = captureInterruptionDetectedAt,
               Date().timeIntervalSince(detectedAt) < 0.9
            {
                scheduleAudioChangeEvaluation()
                return
            }

            if !hasAttemptedCaptureRecovery {
                hasAttemptedCaptureRecovery = true
                if attemptMicrophoneRecovery() {
                    captureInterruptionDetectedAt = nil
                    startupCaptureGraceUntil = Date().addingTimeInterval(1.0)
                    scheduleAudioChangeEvaluation()
                    return
                }
            }

            stopDictation()
            lastError = "Microphone capture was interrupted. Dictation stopped."
            return
        }

        guard !selectedInputDeviceID.isEmpty else {
            // Device enumeration can be transient; keep an active capture session running.
            return
        }

        if !previousSelection.isEmpty,
           !availableInputDevices.contains(where: { $0.id == previousSelection })
        {
            stopDictation()
            lastError = "Selected microphone is unavailable. Dictation stopped."
            return
        }
    }

    private func setAccessibilityErrorIfNeeded() {
        guard !hasShownAccessibilityError else { return }
        hasShownAccessibilityError = true
        lastError = Self.accessibilityErrorMessage
    }

    private func clearAccessibilityErrorIfNeeded() {
        refreshAccessibilityTrustState()
        guard hasShownAccessibilityError else { return }
        hasShownAccessibilityError = false
        if lastError == Self.accessibilityErrorMessage {
            lastError = nil
        }
    }

    private func attemptMicrophoneRecovery() -> Bool {
        let chunkBuffer = audioChunkBuffer
        let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID

        microphone.stop()

        do {
            try microphone.start(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }
            statusText = "Listening..."
            return true
        } catch {
            lastError = "Failed to recover microphone capture: \(error.localizedDescription)"
            return false
        }
    }
}
