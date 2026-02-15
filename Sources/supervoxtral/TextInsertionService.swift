import AppKit
import ApplicationServices
import Foundation
import Observation

enum TextInsertResult {
    case insertedByAccessibility
    case insertedByKeyboardFallback
    case deferredByActiveModifiers
    case failed
}

enum KeyboardFallbackBehavior {
    case always
    case deferIfModifierActive
}

@MainActor
@Observable
final class TextInsertionService {
    private(set) var isAccessibilityTrusted = false
    var lastAccessibilityError: String?

    private var hasPromptedForAccessibilityPermission = false
    private var hasShownAccessibilityError = false
    private var pendingRealtimeInsertionText = ""
    private var insertionRetryTask: Task<Void, Never>?
    private var accessibilityTrustPollingTask: Task<Void, Never>?
    private var axInsertionSuccessCount = 0
    private var keyboardFallbackSuccessCount = 0
    private var modifierDeferredInsertionCount = 0

    static let accessibilityErrorMessage =
        "Enable Accessibility for SuperVoxtral in System Settings > Privacy & Security > Accessibility."

    var hasPendingInsertionText: Bool {
        !pendingRealtimeInsertionText.isEmpty
    }

    func drainPendingInsertionText() -> String {
        let text = pendingRealtimeInsertionText
        pendingRealtimeInsertionText = ""
        return text
    }

    func insertText(
        _ text: String,
        keyboardFallbackBehavior: KeyboardFallbackBehavior = .always
    ) -> TextInsertResult {
        guard !text.isEmpty else { return .insertedByAccessibility }
        refreshAccessibilityTrustState()

        if keyboardFallbackBehavior == .deferIfModifierActive,
           shouldSuppressKeyboardFallbackForActiveModifiers()
        {
            modifierDeferredInsertionCount += 1
            return .deferredByActiveModifiers
        }

        if keyboardFallbackBehavior == .deferIfModifierActive,
           postUnicodeTextEvents(text)
        {
            clearAccessibilityErrorIfNeeded()
            keyboardFallbackSuccessCount += 1
            return .insertedByKeyboardFallback
        }

        if insertTextUsingAccessibility(text) {
            clearAccessibilityErrorIfNeeded()
            axInsertionSuccessCount += 1
            return .insertedByAccessibility
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

    func pasteUsingCommandV(_ text: String) -> Bool {
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

    func enqueueRealtimeInsertion(_ text: String) {
        guard !text.isEmpty else { return }
        pendingRealtimeInsertionText.append(text)
        flushPendingRealtimeInsertion()
    }

    func flushPendingRealtimeInsertion() {
        guard !pendingRealtimeInsertionText.isEmpty else { return }

        let result = insertText(
            pendingRealtimeInsertionText,
            keyboardFallbackBehavior: .deferIfModifierActive
        )

        switch result {
        case .insertedByAccessibility, .insertedByKeyboardFallback:
            pendingRealtimeInsertionText.removeAll(keepingCapacity: true)
        case .deferredByActiveModifiers:
            break
        case .failed:
            break
        }
    }

    func restartInsertionRetryTask(isDictating: @escaping @MainActor () -> Bool) {
        insertionRetryTask?.cancel()

        insertionRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard isDictating() else { continue }
                guard !self.pendingRealtimeInsertionText.isEmpty else { continue }
                self.flushPendingRealtimeInsertion()
            }
        }
    }

    func stopInsertionRetryTask() {
        insertionRetryTask?.cancel()
        insertionRetryTask = nil
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
        if lastAccessibilityError == Self.accessibilityErrorMessage {
            lastAccessibilityError = nil
        }
        if !wasTrusted {
            clearAccessibilityErrorIfNeeded()
        }
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startAccessibilityTrustPolling()
        refreshAccessibilityTrustState()
    }

    func resetDiagnostics() {
        axInsertionSuccessCount = 0
        keyboardFallbackSuccessCount = 0
        modifierDeferredInsertionCount = 0
    }

    func logDiagnostics() {
        let totalInsertions = axInsertionSuccessCount + keyboardFallbackSuccessCount + modifierDeferredInsertionCount
        guard totalInsertions > 0 else { return }

        print(
            "[SuperVoxtral] insertion-paths "
                + "ax=\(axInsertionSuccessCount) "
                + "keyboard_fallback=\(keyboardFallbackSuccessCount) "
                + "deferred_modifiers=\(modifierDeferredInsertionCount)"
        )
    }

    func stopAllTasks() {
        insertionRetryTask?.cancel()
        insertionRetryTask = nil
        accessibilityTrustPollingTask?.cancel()
        accessibilityTrustPollingTask = nil
    }

    func clearPendingText() {
        pendingRealtimeInsertionText = ""
    }

    // MARK: - Private

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

        guard CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            return false
        }

        let focusedElement = focusedObject as! AXUIElement
        var focusedPID: pid_t = 0
        AXUIElementGetPid(focusedElement, &focusedPID)
        if focusedPID == getpid() {
            return false
        }

        if replaceSelectedTextRange(in: focusedElement, with: text) {
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

    private func promptForAccessibilityPermissionIfNeeded() {
        guard !hasPromptedForAccessibilityPermission else { return }
        hasPromptedForAccessibilityPermission = true

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startAccessibilityTrustPolling()
        refreshAccessibilityTrustState()
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

    private func setAccessibilityErrorIfNeeded() {
        guard !hasShownAccessibilityError else { return }
        hasShownAccessibilityError = true
        lastAccessibilityError = Self.accessibilityErrorMessage
    }

    private func clearAccessibilityErrorIfNeeded() {
        refreshAccessibilityTrustState()
        guard hasShownAccessibilityError else { return }
        hasShownAccessibilityError = false
        if lastAccessibilityError == Self.accessibilityErrorMessage {
            lastAccessibilityError = nil
        }
    }
}
