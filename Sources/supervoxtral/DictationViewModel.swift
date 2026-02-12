import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
final class DictationViewModel: ObservableObject {
    @Published private(set) var isDictating = false
    @Published private(set) var transcriptText = ""
    @Published private(set) var livePartialText = ""
    @Published private(set) var statusText = "Idle"
    @Published private(set) var lastError: String?
    @Published private(set) var lastFinalSegment = ""

    let settings: SettingsStore

    private let microphone = MicrophoneCaptureService()
    private let realtimeClient = RealtimeWebSocketClient()
    private let audioChunkBuffer = AudioChunkBuffer()
    private let audioSendInterval: TimeInterval = 0.1
    private var commitTimer: Timer?
    private var audioSendTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var hasPromptedForAccessibilityPermission = false
    private var hasShownAccessibilityError = false

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

        registerGlobalHotkey()
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

    func startDictation() {
        guard !isDictating else { return }
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
        statusText = "Stopped."
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

    func pasteLatestSegment() {
        let segment = lastFinalSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }

        if insertTextIntoFocusedField(segment) {
            statusText = "Pasted latest segment."
            return
        }

        if pasteUsingCommandV(segment) {
            statusText = "Pasted latest segment."
            return
        }

        if !AXIsProcessTrusted() {
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

        let model = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            statusText = "Model is required."
            lastError = "Set a realtime model name in Settings."
            return
        }

        do {
            let client = realtimeClient

            try client.connect(configuration: .init(
                endpoint: endpoint,
                apiKey: settings.trimmedAPIKey,
                model: model
            ))

            let chunkBuffer = audioChunkBuffer
            chunkBuffer.clear()
            try microphone.start { chunk in
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

        let interval = max(0.25, settings.commitIntervalSeconds)
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
            statusText = "Connected to realtime endpoint."

        case .status(let message):
            statusText = message

        case .partialTranscript(let delta):
            guard !delta.isEmpty else { return }
            livePartialText += delta
            _ = insertTextIntoFocusedField(delta)
            statusText = "Transcribing..."

        case .finalTranscript(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                livePartialText = ""
                return
            }

            if transcriptText.isEmpty {
                transcriptText = trimmed
            } else {
                transcriptText += "\n" + trimmed
            }

            lastFinalSegment = trimmed
            livePartialText = ""
            statusText = "Listening..."

            if settings.autoCopyEnabled {
                copyTranscript()
            }

        case .error(let message):
            statusText = "Realtime error."
            lastError = message
        }
    }

    @discardableResult
    private func insertTextIntoFocusedField(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        if insertTextUsingAccessibility(text) {
            clearAccessibilityErrorIfNeeded()
            return true
        }

        if postUnicodeTextEvents(text) {
            clearAccessibilityErrorIfNeeded()
            return true
        }

        if !AXIsProcessTrusted() {
            promptForAccessibilityPermissionIfNeeded()
            setAccessibilityErrorIfNeeded()
        }

        return false
    }

    private func insertTextUsingAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

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
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
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

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func promptForAccessibilityPermissionIfNeeded() {
        guard !hasPromptedForAccessibilityPermission else { return }
        hasPromptedForAccessibilityPermission = true

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func setAccessibilityErrorIfNeeded() {
        guard !hasShownAccessibilityError else { return }
        hasShownAccessibilityError = true
        lastError = Self.accessibilityErrorMessage
    }

    private func clearAccessibilityErrorIfNeeded() {
        guard hasShownAccessibilityError else { return }
        hasShownAccessibilityError = false
        if lastError == Self.accessibilityErrorMessage {
            lastError = nil
        }
    }
}
