import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Network

@MainActor
final class DictationViewModel: ObservableObject {
    @Published private(set) var isDictating = false
    @Published private(set) var transcriptText = ""
    @Published private(set) var livePartialText = ""
    @Published private(set) var statusText = "Ready"
    @Published private(set) var lastError: String?
    @Published private(set) var lastFinalSegment = ""
    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    @Published private(set) var selectedInputDeviceID = ""

    let settings: SettingsStore

    private let microphone = MicrophoneCaptureService()
    private let realtimeClient = RealtimeWebSocketClient()
    private let audioChunkBuffer = AudioChunkBuffer()
    private let audioSendInterval: TimeInterval = 0.1
    private var commitTimer: Timer?
    private var audioSendTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var hasRunPermissionPreflight = false
    private var hasPromptedForAccessibilityPermission = false
    private var hasShownAccessibilityError = false
    private var localNetworkBrowser: NWBrowser?
    private var localNetworkProbeCancelWorkItem: DispatchWorkItem?

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
                guard let self, self.isDictating else { return }
                self.stopDictation()
                self.lastError = "Audio device changed. Dictation stopped."
            }
        }

        registerGlobalHotkey()
        refreshAccessibilityTrustState()
        refreshMicrophoneInputs()
        runStartupPermissionPreflightIfNeeded()
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

    private func runStartupPermissionPreflightIfNeeded() {
        guard !hasRunPermissionPreflight else { return }
        hasRunPermissionPreflight = true

        Task { @MainActor [weak self] in
            guard let self else { return }

            self.promptAccessibilityPermissionAtLaunchIfNeeded()

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.requestMicrophonePermissionAtLaunch()

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.requestLocalNetworkPermissionAtLaunch()
        }
    }

    private func promptAccessibilityPermissionAtLaunchIfNeeded() {
        refreshAccessibilityTrustState()
        guard !isAccessibilityTrusted else { return }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        hasPromptedForAccessibilityPermission = true
        refreshAccessibilityTrustState()
    }

    private func requestMicrophonePermissionAtLaunch() {
        microphone.requestAccess { _ in }
    }

    private func requestLocalNetworkPermissionAtLaunch() {
        stopLocalNetworkPermissionProbe()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: "_services._dns-sd._udp", domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch state {
                case .ready, .failed:
                    self.stopLocalNetworkPermissionProbe()
                default:
                    break
                }
            }
        }

        localNetworkBrowser = browser
        browser.start(queue: .main)

        let cancelWork = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.stopLocalNetworkPermissionProbe()
            }
        }
        localNetworkProbeCancelWorkItem = cancelWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: cancelWork)
    }

    private func stopLocalNetworkPermissionProbe() {
        localNetworkProbeCancelWorkItem?.cancel()
        localNetworkProbeCancelWorkItem = nil
        localNetworkBrowser?.cancel()
        localNetworkBrowser = nil
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
        availableInputDevices = devices

        guard !devices.isEmpty else {
            selectedInputDeviceID = ""
            settings.selectedInputDeviceUID = ""
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

        selectedInputDeviceID = resolvedSelection
        settings.selectedInputDeviceUID = resolvedSelection
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
        statusText = "Checking microphone permission..."

        microphone.requestAccess { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.statusText = "Microphone access denied."
                    self.lastError = "Grant microphone access in System Settings > Privacy & Security > Microphone."
                    return
                }

                self.beginDictationSession()
            }
        }
    }

    func stopDictation() {
        guard isDictating else { return }

        commitTimer?.invalidate()
        commitTimer = nil
        audioSendTimer?.invalidate()
        audioSendTimer = nil

        microphone.stop()
        flushBufferedAudio()
        realtimeClient.sendCommit(final: true)
        realtimeClient.disconnect()

        isDictating = false
        livePartialText = ""
        statusText = "Ready"
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

        if insertTextIntoFocusedField(segment) {
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
            let client = realtimeClient

            try client.connect(configuration: .init(
                endpoint: endpoint,
                apiKey: settings.trimmedAPIKey,
                model: model
            ))

            let chunkBuffer = audioChunkBuffer
            chunkBuffer.clear()
            let preferredInputID = selectedInputDeviceID.isEmpty ? nil : selectedInputDeviceID
            try microphone.start(preferredDeviceID: preferredInputID) { chunk in
                chunkBuffer.append(chunk)
            }

            isDictating = true
            livePartialText = ""
            statusText = "Listening..."
            restartAudioSendTimer()
            restartCommitTimer()
        } catch {
            statusText = "Failed to start dictation."
            lastError = error.localizedDescription
            microphone.stop()
            realtimeClient.disconnect()
        }
    }

    private func restartCommitTimer() {
        commitTimer?.invalidate()

        let interval = min(1.0, max(0.1, settings.commitIntervalSeconds))
        let client = realtimeClient
        commitTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            client.sendCommit(final: false)
        }

        if let commitTimer {
            RunLoop.main.add(commitTimer, forMode: .common)
        }
    }

    private func restartAudioSendTimer() {
        audioSendTimer?.invalidate()

        let client = realtimeClient
        let chunkBuffer = audioChunkBuffer
        audioSendTimer = Timer.scheduledTimer(withTimeInterval: audioSendInterval, repeats: true) { [weak self] _ in
            guard self != nil else { return }

            let bufferedChunk = chunkBuffer.takeAll()
            guard !bufferedChunk.isEmpty else { return }
            client.sendAudioChunk(bufferedChunk)
        }

        if let audioSendTimer {
            RunLoop.main.add(audioSendTimer, forMode: .common)
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
            _ = insertTextIntoFocusedField(delta)
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

    @discardableResult
    private func insertTextIntoFocusedField(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        refreshAccessibilityTrustState()

        if insertTextUsingAccessibility(text) {
            clearAccessibilityErrorIfNeeded()
            return true
        }

        if postUnicodeTextEvents(text) {
            clearAccessibilityErrorIfNeeded()
            return true
        }

        if !isAccessibilityTrusted {
            promptForAccessibilityPermissionIfNeeded()
            setAccessibilityErrorIfNeeded()
        }

        return false
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

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
            didPostAnyEvent = true
        }

        return didPostAnyEvent
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
        isAccessibilityTrusted = AXIsProcessTrusted()
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
}
