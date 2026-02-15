import AppKit
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
    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""

    var isAccessibilityTrusted: Bool { textInsertion.isAccessibilityTrusted }

    let settings: SettingsStore
    let textInsertion = TextInsertionService()

    private let microphone = MicrophoneCaptureService()
    private let realtimeClient = RealtimeWebSocketClient()
    private let audioChunkBuffer = AudioChunkBuffer()
    private let healthMonitor = AudioCaptureHealthMonitor()
    private let audioSendInterval: TimeInterval = 0.1
    private var commitTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var isAwaitingMicrophonePermission = false
    private var pendingRealtimeFinalizationText = ""
    private var currentDictationEventText = ""
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    private static let hotKeySignature = OSType(0x53565854) // SVXT
    private static weak var hotKeyTarget: DictationViewModel?

    init(settings: SettingsStore) {
        self.settings = settings

        realtimeClient.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }

        microphone.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.healthMonitor.handleConfigurationChange()
            }
        }

        microphone.onInputDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.healthMonitor.handleInputDevicesChanged()
            }
        }

        textInsertion.onAccessibilityTrustChanged = { [weak self] in
            guard let self else { return }
            if self.lastError == TextInsertionService.accessibilityErrorMessage {
                self.lastError = nil
            }
            if !self.isDictating,
               self.statusText == "Waiting for Accessibility permission."
                || self.statusText == "Paste blocked by Accessibility permission."
            {
                self.statusText = "Ready"
            }
        }

        Self.hotKeyTarget = self
        registerGlobalHotkey()
        textInsertion.refreshAccessibilityTrustState()
        refreshMicrophoneInputs()
    }

    @MainActor
    deinit {
        Self.hotKeyTarget = nil
        commitTask?.cancel()
        audioSendTask?.cancel()
        textInsertion.stopAllTasks()
        healthMonitor.cancelTasks()
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

        if !explicitSelection.isEmpty,
           devices.contains(where: { $0.id == explicitSelection })
        {
            if selectedInputDeviceID != explicitSelection {
                selectedInputDeviceID = explicitSelection
            }
            if settings.selectedInputDeviceUID != explicitSelection {
                settings.selectedInputDeviceUID = explicitSelection
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
        textInsertion.stopInsertionRetryTask()
        healthMonitor.stop()
        isAwaitingMicrophonePermission = false

        microphone.stop()
        flushBufferedAudio()
        realtimeClient.disconnectAfterFinalCommitIfNeeded()
        promotePendingRealtimeTextToLatestSegment()

        isDictating = false
        livePartialText = ""
        pendingRealtimeFinalizationText = ""
        statusText = "Ready"
        textInsertion.logDiagnostics()

        if textInsertion.hasPendingInsertionText {
            lastError = "Some realtime text could not be inserted into the focused app."
            textInsertion.clearPendingText()
        }

        if lastError?.localizedCaseInsensitiveContains("websocket receive failed") == true {
            lastError = nil
        }
    }

    func clearTranscript() {
        transcriptText = ""
        livePartialText = ""
        lastFinalSegment = ""
        pendingRealtimeFinalizationText = ""
        currentDictationEventText = ""
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
        textInsertion.requestAccessibilityPermission()

        if textInsertion.isAccessibilityTrusted {
            statusText = "Ready"
        } else {
            statusText = "Waiting for Accessibility permission."
        }
    }

    func refreshAccessibilityTrustState() {
        let wasTrusted = textInsertion.isAccessibilityTrusted
        textInsertion.refreshAccessibilityTrustState()

        if textInsertion.isAccessibilityTrusted, !wasTrusted, !isDictating,
           statusText == "Waiting for Accessibility permission."
            || statusText == "Paste blocked by Accessibility permission."
        {
            statusText = "Ready"
        }

        if let axError = textInsertion.lastAccessibilityError {
            if lastError == nil || lastError == TextInsertionService.accessibilityErrorMessage {
                lastError = axError
            }
        } else if lastError == TextInsertionService.accessibilityErrorMessage {
            lastError = nil
        }
    }

    func pasteLatestSegment() {
        let segment = lastFinalSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }

        textInsertion.refreshAccessibilityTrustState()

        let directInsertResult = textInsertion.insertText(segment)
        if directInsertResult == .insertedByAccessibility
            || directInsertResult == .insertedByKeyboardFallback
        {
            statusText = "Pasted latest segment."
            return
        }

        if textInsertion.pasteUsingCommandV(segment) {
            statusText = "Pasted latest segment."
            return
        }

        if !textInsertion.isAccessibilityTrusted {
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
            pendingRealtimeFinalizationText = ""
            currentDictationEventText = ""
            statusText = "Listening..."
            textInsertion.clearPendingText()
            textInsertion.resetDiagnostics()

            let client = realtimeClient
            try client.connect(configuration: .init(
                endpoint: endpoint,
                apiKey: settings.trimmedAPIKey,
                model: model
            ))

            restartAudioSendTask()
            restartCommitTask()
            textInsertion.restartInsertionRetryTask { [weak self] in
                self?.isDictating ?? false
            }
            healthMonitor.start(microphone: microphone, callbacks: makeHealthMonitorCallbacks())
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            microphone.stop()
            realtimeClient.disconnect()
            isDictating = false
            healthMonitor.stop()
            debugLog("beginDictationSession failed error=\(error.localizedDescription)")
        }
    }

    private func makeHealthMonitorCallbacks() -> AudioCaptureHealthMonitor.Callbacks {
        let chunkBuffer = audioChunkBuffer
        let mic = microphone
        return AudioCaptureHealthMonitor.Callbacks(
            refreshMicrophoneInputs: { [weak self] in
                self?.refreshMicrophoneInputs()
            },
            stopDictation: { [weak self] reason in
                self?.stopDictation(reason: reason)
            },
            isDictating: { [weak self] in
                self?.isDictating ?? false
            },
            selectedInputDeviceID: { [weak self] in
                self?.selectedInputDeviceID ?? ""
            },
            availableInputDevices: { [weak self] in
                self?.availableInputDevices ?? []
            },
            setStatus: { [weak self] status in
                self?.statusText = status
            },
            setError: { [weak self] error in
                self?.lastError = error
            },
            restartMicrophone: { preferredInputID in
                try mic.start(preferredDeviceID: preferredInputID) { chunk in
                    chunkBuffer.append(chunk)
                }
            }
        )
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
                        print("[localvoxtral][Dictation] audio send loop has no buffered chunks")
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
            pendingRealtimeFinalizationText += delta
            livePartialText = pendingRealtimeFinalizationText
            textInsertion.enqueueRealtimeInsertion(delta)
            statusText = "Transcribing..."

        case .finalTranscript(let text):
            let finalizedSegment = resolvedFinalizedSegment(from: text)
            let hadLiveDelta = !pendingRealtimeFinalizationText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                || !livePartialText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard !finalizedSegment.isEmpty else {
                livePartialText = ""
                pendingRealtimeFinalizationText = ""
                return
            }

            if transcriptText.isEmpty {
                transcriptText = finalizedSegment
            } else {
                transcriptText += "\n" + finalizedSegment
            }

            currentDictationEventText = appendToCurrentDictationEvent(
                segment: finalizedSegment,
                existingText: currentDictationEventText
            )
            lastFinalSegment = currentDictationEventText
            livePartialText = ""
            pendingRealtimeFinalizationText = ""
            statusText = isDictating ? "Listening..." : "Ready"

            // Some providers emit only finalized transcript events. Ensure text is still inserted.
            if !hadLiveDelta {
                textInsertion.enqueueRealtimeInsertion(finalizedSegment)
            }

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

    private func resolvedFinalizedSegment(from finalText: String) -> String {
        let finalizedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bufferedText = pendingRealtimeFinalizationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBufferedText = livePartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingText = bufferedText.isEmpty ? fallbackBufferedText : bufferedText

        if finalizedText.isEmpty {
            return pendingText
        }

        if pendingText.isEmpty {
            return finalizedText
        }

        if finalizedText.count > pendingText.count, finalizedText.hasPrefix(pendingText) {
            return finalizedText
        }
        if pendingText.hasSuffix(finalizedText) {
            return pendingText
        }
        if pendingText.hasPrefix(finalizedText) {
            return pendingText
        }

        if let pendingLast = pendingText.last,
           let finalizedFirst = finalizedText.first,
           !pendingLast.isWhitespace,
           !finalizedFirst.isWhitespace
        {
            return pendingText + " " + finalizedText
        }
        return pendingText + finalizedText
    }

    private func promotePendingRealtimeTextToLatestSegment() {
        let pendingSegment = resolvedFinalizedSegment(from: "")
        guard !pendingSegment.isEmpty else { return }

        currentDictationEventText = appendToCurrentDictationEvent(
            segment: pendingSegment,
            existingText: currentDictationEventText
        )
        lastFinalSegment = currentDictationEventText

        if settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }
    }

    private func appendToCurrentDictationEvent(segment: String, existingText: String) -> String {
        let normalizedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSegment.isEmpty else { return existingText }

        let normalizedExisting = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExisting.isEmpty else { return normalizedSegment }

        if normalizedSegment.count > normalizedExisting.count,
           normalizedSegment.hasPrefix(normalizedExisting)
        {
            return normalizedSegment
        }

        return normalizedExisting + "\n" + normalizedSegment
    }

    private func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        print("[localvoxtral][Dictation] \(message)")
    }
}
