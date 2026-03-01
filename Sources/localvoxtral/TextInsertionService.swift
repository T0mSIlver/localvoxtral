import AppKit
import ApplicationServices
import Foundation
import Observation
import os

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

enum PreferredTextInsertionTargetPolicy {
    enum PasteActivationAction: Equatable {
        case useCurrentFrontmost
        case activate(pid_t)
        case deny
    }

    static func accessibilityTargetPID(
        systemFocusedPID: pid_t?,
        preferredPID: pid_t?,
        selfPID: pid_t
    ) -> pid_t? {
        if let preferredPID = normalizedPreferredPID(preferredPID, selfPID: selfPID) {
            return preferredPID
        }

        guard let systemFocusedPID,
              systemFocusedPID != selfPID
        else {
            return nil
        }

        return systemFocusedPID
    }

    static func pasteActivationAction(
        frontmostPID: pid_t?,
        preferredPID: pid_t?,
        selfPID: pid_t
    ) -> PasteActivationAction {
        if let preferredPID = normalizedPreferredPID(preferredPID, selfPID: selfPID) {
            if frontmostPID == preferredPID {
                return .useCurrentFrontmost
            }
            return .activate(preferredPID)
        }

        guard let frontmostPID else { return .deny }
        return frontmostPID == selfPID ? .deny : .useCurrentFrontmost
    }

    private static func normalizedPreferredPID(_ preferredPID: pid_t?, selfPID: pid_t) -> pid_t? {
        guard let preferredPID,
              preferredPID != 0,
              preferredPID != selfPID
        else {
            return nil
        }
        return preferredPID
    }
}

@MainActor
@Observable
final class TextInsertionService {
    private struct PasteboardSnapshot {
        let items: [NSPasteboardItem]
    }

    private let accessibilityTrust = AccessibilityTrustManager()

    var isAccessibilityTrusted: Bool { accessibilityTrust.isTrusted }
    var lastAccessibilityError: String? {
        get { accessibilityTrust.lastError }
        set { accessibilityTrust.lastError = newValue }
    }

    var onAccessibilityTrustChanged: (() -> Void)? {
        get { accessibilityTrust.onTrustChanged }
        set { accessibilityTrust.onTrustChanged = newValue }
    }

    private var pendingRealtimeInsertionText = ""
    private var insertionRetryTask: Task<Void, Never>?
    private var axInsertionSuccessCount = 0
    private var keyboardFallbackSuccessCount = 0
    private var modifierDeferredInsertionCount = 0

    static let accessibilityErrorMessage = AccessibilityTrustManager.errorMessage

    var hasPendingInsertionText: Bool {
        !pendingRealtimeInsertionText.isEmpty
    }

    func drainPendingInsertionText() -> String {
        let text = pendingRealtimeInsertionText
        pendingRealtimeInsertionText = ""
        return text
    }

    /// Try to insert text using only the Accessibility API (no keyboard event
    /// fallback). Returns `true` if the text was inserted successfully.
    /// Use this for delayed/finalized text blocks where keyboard events are
    /// unreliable because focus context may have shifted.
    func insertTextUsingAccessibilityOnly(_ text: String, preferredAppPID: pid_t? = nil) -> Bool {
        guard !text.isEmpty else { return true }
        refreshAccessibilityTrustState()
        if insertTextUsingAccessibility(text, preferredAppPID: preferredAppPID) {
            clearAccessibilityErrorIfNeeded()
            axInsertionSuccessCount += 1
            return true
        }
        return false
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

    func pasteUsingCommandV(_ text: String, preferredAppPID: pid_t? = nil) -> Bool {
        guard !text.isEmpty else { return true }

        if !ensurePasteTargetIsActive(preferredAppPID: preferredAppPID) {
            return false
        }

        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 9, keyDown: false)
        else {
            return false
        }

        let pasteboard = NSPasteboard.general
        let snapshot = capturePasteboardSnapshot(from: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Self.restorePasteboardSnapshot(snapshot, to: pasteboard, expectedChangeCount: pasteboard.changeCount)
            return false
        }
        let insertedChangeCount = pasteboard.changeCount

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        // Restore clipboard only if the user did not change it after our temporary write.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [snapshot] in
            let pasteboard = NSPasteboard.general
            Self.restorePasteboardSnapshot(snapshot, to: pasteboard, expectedChangeCount: insertedChangeCount)
        }
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
        accessibilityTrust.refresh()
    }

    func requestAccessibilityPermission() {
        requestAccessibilityPermissionIfNeeded()
    }

    func requestAccessibilityPermissionIfNeeded() {
        accessibilityTrust.promptIfNeeded()
    }

    func resetDiagnostics() {
        axInsertionSuccessCount = 0
        keyboardFallbackSuccessCount = 0
        modifierDeferredInsertionCount = 0
    }

    func logDiagnostics() {
        let totalInsertions = axInsertionSuccessCount + keyboardFallbackSuccessCount + modifierDeferredInsertionCount
        guard totalInsertions > 0 else { return }

        Log.insertion.info(
            "insertion-paths ax=\(self.axInsertionSuccessCount) keyboard_fallback=\(self.keyboardFallbackSuccessCount) deferred_modifiers=\(self.modifierDeferredInsertionCount)"
        )
    }

    func stopAllTasks() {
        insertionRetryTask?.cancel()
        insertionRetryTask = nil
        accessibilityTrust.stopTasks()
    }

    func clearPendingText() {
        pendingRealtimeInsertionText = ""
    }

    // MARK: - Private

    private func insertTextUsingAccessibility(
        _ text: String,
        preferredAppPID: pid_t? = nil
    ) -> Bool {
        guard isAccessibilityTrusted else { return false }
        guard let focusedElement = resolvedAccessibilityInsertionTarget(
            preferredAppPID: preferredAppPID
        ) else {
            return false
        }

        // Retry once: the Accessibility API can fail on the first attempt when
        // the focused element's attribute state hasn't fully settled (common with
        // larger text blocks from mlx-audio finalization).
        if replaceSelectedTextRange(in: focusedElement, with: text) {
            return true
        }
        return replaceSelectedTextRange(in: focusedElement, with: text)
    }

    private func resolvedAccessibilityInsertionTarget(
        preferredAppPID: pid_t?
    ) -> AXUIElement? {
        let selfPID = getpid()
        let systemFocused = focusedElementFromSystemWide()
        let targetPID = PreferredTextInsertionTargetPolicy.accessibilityTargetPID(
            systemFocusedPID: systemFocused?.pid,
            preferredPID: preferredAppPID,
            selfPID: selfPID
        )

        guard let targetPID else {
            return nil
        }

        if let systemFocused,
           systemFocused.pid == targetPID
        {
            return systemFocused.element
        }

        guard let preferredElement = focusedElement(inApplicationPID: targetPID)
        else {
            return nil
        }

        return preferredElement
    }

    private func focusedElementFromSystemWide() -> (element: AXUIElement, pid: pid_t)? {
        SystemAccessibilityFocus.focusedElement()
    }

    private func focusedElement(inApplicationPID pid: pid_t) -> AXUIElement? {
        SystemAccessibilityFocus.focusedElement(inApplicationPID: pid)
    }

    // TODO: This synchronous spin blocks @MainActor for up to 80ms while waiting
    // for NSWorkspace to report the target app as frontmost. An async approach
    // (e.g. Task.sleep ticks) would be less intrusive but requires making the
    // entire paste path async. Acceptable for now given the small window.
    private func ensurePasteTargetIsActive(preferredAppPID: pid_t?) -> Bool {
        let selfPID = getpid()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let action = PreferredTextInsertionTargetPolicy.pasteActivationAction(
            frontmostPID: frontmostPID,
            preferredPID: preferredAppPID,
            selfPID: selfPID
        )

        switch action {
        case .useCurrentFrontmost:
            return true

        case .deny:
            return false

        case .activate(let targetPID):
            guard let preferredApp = NSRunningApplication(processIdentifier: targetPID)
            else {
                return false
            }

            preferredApp.activate(options: [])
            let deadline = Date().addingTimeInterval(0.08)
            while Date() < deadline {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                    return true
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        }
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
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
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
        accessibilityTrust.promptIfNeeded()
    }

    private func setAccessibilityErrorIfNeeded() {
        accessibilityTrust.setErrorIfNeeded()
    }

    private func clearAccessibilityErrorIfNeeded() {
        accessibilityTrust.clearErrorIfNeeded()
    }

    // NSPasteboardItem.copy() (inherited from NSObject) returns `self` rather than
    // a deep copy — items become invalid once the pasteboard is cleared, so we must
    // manually copy per-type data into fresh NSPasteboardItem instances.
    private func capturePasteboardSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let copiedItems = pasteboard.pasteboardItems?
            .compactMap { item -> NSPasteboardItem? in
                let snapshotItem = NSPasteboardItem()
                var hasAnyRepresentation = false

                for type in item.types {
                    if let data = item.data(forType: type) {
                        snapshotItem.setData(data, forType: type)
                        hasAnyRepresentation = true
                        continue
                    }
                    if let string = item.string(forType: type) {
                        snapshotItem.setString(string, forType: type)
                        hasAnyRepresentation = true
                        continue
                    }
                    if let propertyList = item.propertyList(forType: type) {
                        snapshotItem.setPropertyList(propertyList, forType: type)
                        hasAnyRepresentation = true
                    }
                }

                return hasAnyRepresentation ? snapshotItem : nil
            } ?? []
        return PasteboardSnapshot(
            items: copiedItems
        )
    }

    nonisolated private static func restorePasteboardSnapshot(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) {
        guard pasteboard.changeCount == expectedChangeCount else { return }
        pasteboard.clearContents()
        if !snapshot.items.isEmpty {
            _ = pasteboard.writeObjects(snapshot.items)
        }
    }
}
