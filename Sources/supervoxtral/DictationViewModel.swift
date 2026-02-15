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
    private var startupConfigurationChangeDetected = false
    private var captureRecoveryAttemptCount = 0
    private var isAwaitingMicrophonePermission = false
    private var pendingRealtimeInsertionText = ""
    private var insertionRetryTask: Task<Void, Never>?
    private var captureHealthTask: Task<Void, Never>?
    private var accessibilityTrustPollingTask: Task<Void, Never>?
    private var axInsertionSuccessCount = 0
    private var keyboardFallbackSuccessCount = 0
    private var modifierDeferredInsertionCount = 0
    private var lastNoAudioDiagnosticAt: Date?
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["SUPERVOXTRAL_DEBUG"] == "1"

    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private static let accessibilityErrorMessage =
        "Enable Accessibility for SuperVoxtral in System Settings > Privacy & Security > Accessibility."
    private static weak var hotKeyTarget: DictationViewModel?
    private static let captureInterruptionConfirmationSeconds: TimeInterval = 4.0
    private static let recentAudioToleranceSeconds: TimeInterval = 1.2
    private static let startupNoAudioRecoverySeconds: TimeInterval = 1.5
    private static let startupCaptureGraceSeconds: TimeInterval = 1.4
    private static let startupConfigChangeGraceSeconds: TimeInterval = 0.25
    private static let startupConfigChangeRecoverySeconds: TimeInterval = 0.35
    private static let maxCaptureRecoveryAttempts = 3
    private static let fastAudioChangeEvaluationDelayMilliseconds = 120

    init(settings: SettingsStore) {
        self.settings = settings

        realtimeClient.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }

        microphone.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleMicrophoneConfigurationChange()
            }
        }

        microphone.onInputDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleAudioChangeEvaluation()
            }
        }

        Self.hotKeyTarget = self
        registerGlobalHotkey()
        refreshAccessibilityTrustState()
        refreshMicrophoneInputs()
    }

    @MainActor
    deinit {
        Self.hotKeyTarget = nil
        commitTask?.cancel()
        audioSendTask?.cancel()
        insertionRetryTask?.cancel()
        captureHealthTask?.cancel()
        accessibilityTrustPollingTask?.cancel()
        pendingAudioChangeTask?.cancel()
        microphone.stop()
        unregisterGlobalHotkey()
    }

    private func registerGlobalHotkey() {
        unregisterGlobalHotkey()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef else { return noErr }

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

                DispatchQueue.main.async {
                    DictationViewModel.hotKeyTarget?.toggleDictation()
                }

                return noErr
            },
            1,
            &eventType,
            nil,
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
            unregisterGlobalHotkey()
        }
    }

    private func unregisterGlobalHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
            self.hotKeyHandlerRef = nil
        }
    }

    func toggleDictation() {
        if isDictating {
            stopDictation(reason: "manual toggle")
        } else {
            startDictation()
        }
    }

    func refreshMicrophoneInputs() {
        let devices = microphone.availableInputDevices()
        if availableInputDevices != devices {
            availableInputDevices = devices
        }

        let savedSelection = settings.selectedInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSelection = selectedInputDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitSelection = !savedSelection.isEmpty ? savedSelection : currentSelection

        guard !devices.isEmpty else { return }

        if !explicitSelection.isEmpty {
            if devices.contains(where: { $0.id == explicitSelection }) {
                if selectedInputDeviceID != explicitSelection {
                    selectedInputDeviceID = explicitSelection
                }
                if settings.selectedInputDeviceUID != explicitSelection {
                    settings.selectedInputDeviceUID = explicitSelection
                }
            } else {
                // Keep the user-selected device pinned until they explicitly choose a different input.
                if selectedInputDeviceID != explicitSelection {
                    selectedInputDeviceID = explicitSelection
                }
                if settings.selectedInputDeviceUID != explicitSelection {
                    settings.selectedInputDeviceUID = explicitSelection
                }
            }
            return
        }

        let resolvedSelection: String
        if let defaultID = microphone.defaultInputDeviceID(),
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
        stopDictation(reason: "input device changed by user")
        startDictation()
    }

    func startDictation() {
        guard !isDictating else { return }
        guard !isAwaitingMicrophonePermission else {
            statusText = "Awaiting microphone permission..."
            return
        }
        debugLog("startDictation requested")
        refreshMicrophoneInputs()
        if debugLoggingEnabled {
            let inputs = availableInputDevices.map { "\($0.name)=\($0.id)" }.joined(separator: ", ")
            debugLog("available inputs: \(inputs)")
            debugLog("selected input id=\(selectedInputDeviceID)")
        }
        lastError = nil
        let deniedMessage = "Grant microphone access in System Settings > Privacy & Security > Microphone."

        switch microphone.authorizationStatus() {
        case .authorized:
            beginDictationSession()
        case .notDetermined:
            isAwaitingMicrophonePermission = true
            statusText = "Requesting microphone permission..."
            debugLog("microphone permission prompt requested")
            microphone.requestAccess { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAwaitingMicrophonePermission = false
                    self.debugLog("microphone permission result granted=\(granted)")
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
            debugLog("microphone access denied or restricted")
        }
    }

    func stopDictation(reason: String = "unspecified") {
        guard isDictating else { return }
        debugLog("stopDictation reason=\(reason)")

        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        insertionRetryTask?.cancel()
        insertionRetryTask = nil
        captureHealthTask?.cancel()
        captureHealthTask = nil
        accessibilityTrustPollingTask?.cancel()
        accessibilityTrustPollingTask = nil
        pendingAudioChangeTask?.cancel()
        pendingAudioChangeTask = nil
        captureInterruptionDetectedAt = nil
        startupCaptureGraceUntil = nil
        startupConfigurationChangeDetected = false
        captureRecoveryAttemptCount = 0
        isAwaitingMicrophonePermission = false
        lastNoAudioDiagnosticAt = nil

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
        startAccessibilityTrustPolling()
        refreshAccessibilityTrustState()

        if isAccessibilityTrusted {
            clearAccessibilityErrorIfNeeded()
            statusText = "Ready"
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

        if !selectedInputDeviceID.isEmpty,
           !availableInputDevices.contains(where: { $0.id == selectedInputDeviceID })
        {
            statusText = "Selected microphone unavailable."
            lastError = "Selected microphone is unavailable. Reconnect it or choose another input."
            return
        }

        let model = settings.effectiveModelName

        do {
            let chunkBuffer = audioChunkBuffer
            chunkBuffer.clear()
            let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID
            debugLog("beginDictationSession endpoint=\(endpoint.absoluteString) model=\(model) input=\(preferredInputID ?? "default")")
            try microphone.start(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }

            isDictating = true
            livePartialText = ""
            statusText = "Listening..."
            pendingRealtimeInsertionText = ""
            captureInterruptionDetectedAt = nil
            startupCaptureGraceUntil = Date().addingTimeInterval(Self.startupCaptureGraceSeconds)
            startupConfigurationChangeDetected = false
            captureRecoveryAttemptCount = 0
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
            restartCaptureHealthTask()
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            microphone.stop()
            realtimeClient.disconnect()
            isDictating = false
            captureInterruptionDetectedAt = nil
            startupCaptureGraceUntil = nil
            startupConfigurationChangeDetected = false
            captureRecoveryAttemptCount = 0
            captureHealthTask?.cancel()
            captureHealthTask = nil
            debugLog("beginDictationSession failed error=\(error.localizedDescription)")
        }
    }

    private func restartCommitTask() {
        commitTask?.cancel()

        let interval = min(1.0, max(0.1, settings.commitIntervalSeconds))
        let client = realtimeClient
        commitTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                client.sendCommit(final: false)
            }
        }
    }

    private func restartAudioSendTask() {
        audioSendTask?.cancel()

        let interval = audioSendInterval
        let client = realtimeClient
        let chunkBuffer = audioChunkBuffer
        let debugLoggingEnabled = debugLoggingEnabled
        audioSendTask = Task.detached(priority: .utility) {
            var emptyBufferTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                let bufferedChunk = chunkBuffer.takeAll()
                guard !bufferedChunk.isEmpty else {
                    emptyBufferTicks += 1
                    if debugLoggingEnabled, emptyBufferTicks % 20 == 0 {
                        print("[SuperVoxtral][Dictation] audio send loop has no buffered chunks")
                    }
                    continue
                }
                emptyBufferTicks = 0
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
            stopDictation(reason: "websocket disconnected")
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

    private func restartCaptureHealthTask() {
        captureHealthTask?.cancel()

        captureHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard self.isDictating else { continue }

                let hasRecentAudio = self.microphone.hasRecentCapturedAudio(
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
        startAccessibilityTrustPolling()
        refreshAccessibilityTrustState()
    }

    func refreshAccessibilityTrustState() {
        let wasTrusted = isAccessibilityTrusted
        let trusted = AXIsProcessTrusted()
        if isAccessibilityTrusted != trusted {
            isAccessibilityTrusted = trusted
        }

        guard trusted else { return }
        accessibilityTrustPollingTask?.cancel()
        accessibilityTrustPollingTask = nil
        hasShownAccessibilityError = false
        if lastError == Self.accessibilityErrorMessage {
            lastError = nil
        }
        if !wasTrusted, !isDictating,
           statusText == "Waiting for Accessibility permission."
            || statusText == "Paste blocked by Accessibility permission."
        {
            statusText = "Ready"
        }
    }

    private func startAccessibilityTrustPolling() {
        guard !isAccessibilityTrusted else { return }
        guard accessibilityTrustPollingTask == nil else { return }

        accessibilityTrustPollingTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(90)
            defer {
                self.accessibilityTrustPollingTask = nil
            }

            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(400))
                self.refreshAccessibilityTrustState()
                if self.isAccessibilityTrusted {
                    break
                }
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

    private func handleMicrophoneConfigurationChange() {
        if isDictating {
            debugLog("configuration changed while dictating; deferring to health evaluation")
            if !microphone.hasCapturedAudioInCurrentRun() {
                startupConfigurationChangeDetected = true
                startupCaptureGraceUntil = Date().addingTimeInterval(Self.startupConfigChangeGraceSeconds)
                scheduleAudioChangeEvaluation(delayMilliseconds: Self.fastAudioChangeEvaluationDelayMilliseconds)
                return
            }
        }
        scheduleAudioChangeEvaluation()
    }

    private func evaluateAudioChange() {
        pendingAudioChangeTask = nil
        let previousSelection = selectedInputDeviceID
        refreshMicrophoneInputs()

        guard isDictating else {
            captureInterruptionDetectedAt = nil
            return
        }

        if !previousSelection.isEmpty,
           selectedInputDeviceID == previousSelection,
           !availableInputDevices.contains(where: { $0.id == previousSelection })
        {
            stopDictation(reason: "selected input unavailable")
            lastError = "Selected microphone became unavailable. Reconnect it or select another input."
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
            captureRecoveryAttemptCount = 0
            lastNoAudioDiagnosticAt = nil
        } else {
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
                debugLog(
                    "no recent audio; engineRunning=\(isEngineRunning) selectedInput=\(selectedInputDeviceID)"
                )
            }
            statusText = "Listening... (waiting for microphone audio)"
            lastError = "No microphone audio frames captured yet."
            scheduleAudioChangeEvaluation(
                delayMilliseconds: startupConfigurationChangeDetected
                    ? Self.fastAudioChangeEvaluationDelayMilliseconds
                    : 350
            )
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

        do {
            debugLog("attempting microphone recovery input=\(preferredInputID ?? "default")")
            try microphone.start(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }
            statusText = "Listening..."
            debugLog("microphone recovery succeeded")
            return true
        } catch {
            lastError = "Failed to recover microphone capture: \(error.localizedDescription)"
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
        print("[SuperVoxtral][Dictation] \(message)")
    }
}
