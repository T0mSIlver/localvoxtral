import AppKit
import ApplicationServices
import Foundation
import Observation
import os

enum TextInsertResult {
    case insertedByAccessibility
    case insertedByKeyboardFallback
    case failed

    var isSuccess: Bool {
        switch self {
        case .insertedByAccessibility, .insertedByKeyboardFallback:
            true
        case .failed:
            false
        }
    }
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
    private var activeModifierFallbackCount = 0

    // Live Auto-Paste post-session sweep bookkeeping (issue #23, Stage 1).
    // When non-nil, tracks the UTF-16 span of text inserted during the current
    // Live Auto-Paste session so a dictionary sweep can locate and revise it
    // in place on stop. This extends the existing insertion-tracking state
    // (the diagnostic counters above) rather than introducing parallel state.
    @ObservationIgnored
    private var liveSessionSpan: LiveSessionSpan?

    private struct LiveSessionSpan: Sendable {
        var startCaretLocation: Int
        var insertedUTF16Length: Int
        let preferredAppPID: pid_t?
    }

#if DEBUG
    @ObservationIgnored
    private var debugUnicodePoster: ((String) -> Bool)?
    @ObservationIgnored
    private var debugModifierStateReader: (() -> Bool)?
    @ObservationIgnored
    private var debugAccessibilityInserter: ((String, pid_t?) -> Bool)?
    // Sweep hooks (DEBUG-only). When set, the AX operations backing the sweep
    // route through these closures instead of real Accessibility calls, so the
    // decision logic and span arithmetic can be exercised headlessly.
    @ObservationIgnored
    private var debugCaretLocationReader: ((pid_t?) -> Int?)?
    @ObservationIgnored
    private var debugFieldReader: ((pid_t?) -> String?)?
    @ObservationIgnored
    private var debugSpanReplacer: ((Int, Int, String, pid_t?) -> String?)?
    @ObservationIgnored
    private var debugSelectionSetter: ((Int, Int, pid_t?) -> Bool)?
#endif

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

    func insertText(_ text: String) -> TextInsertResult {
        guard !text.isEmpty else { return .insertedByAccessibility }
        refreshAccessibilityTrustState()

        if tryAccessibilityInsertion(text, preferredAppPID: nil) {
            return .insertedByAccessibility
        }
        if tryKeyboardInsertion(
            text,
            preferredAppPID: nil,
            requirePreferredTargetActivation: false
        ) {
            return .insertedByKeyboardFallback
        }
        return failedInsertionResult()
    }

    /// Inserts text by trying Unicode keyboard events first, then AX insertion.
    /// Useful for realtime-style insertion paths where keyboard posting is more
    /// reliable than AX in certain web fields.
    func insertTextPrioritizingKeyboard(
        _ text: String,
        preferredAppPID: pid_t? = nil
    ) -> TextInsertResult {
        guard !text.isEmpty else { return .insertedByAccessibility }
        refreshAccessibilityTrustState()

        if tryKeyboardInsertion(
            text,
            preferredAppPID: preferredAppPID,
            requirePreferredTargetActivation: preferredAppPID != nil
        ) {
            return .insertedByKeyboardFallback
        }
        if tryAccessibilityInsertion(text, preferredAppPID: preferredAppPID) {
            return .insertedByAccessibility
        }
        return failedInsertionResult()
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

        let insertedText = pendingRealtimeInsertionText
        let result = insertTextPrioritizingKeyboard(insertedText)

        switch result {
        case .insertedByAccessibility, .insertedByKeyboardFallback:
            pendingRealtimeInsertionText.removeAll(keepingCapacity: true)
            recordSuccessfulLiveInsertion(utf16Length: (insertedText as NSString).length)
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
        activeModifierFallbackCount = 0
    }

    func logDiagnostics() {
        let totalInsertions =
            axInsertionSuccessCount + keyboardFallbackSuccessCount + activeModifierFallbackCount
        guard totalInsertions > 0 else { return }

        Log.insertion.info(
            "insertion-paths ax=\(self.axInsertionSuccessCount) keyboard_fallback=\(self.keyboardFallbackSuccessCount) active_modifiers=\(self.activeModifierFallbackCount)"
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

    // MARK: - Live Auto-Paste Session Span Tracking

    /// Begins tracking the insertion span for a Live Auto-Paste session.
    ///
    /// Reads the current caret location via one Accessibility query and records
    /// it as the span start. If the read fails (AX untrusted, no focused text
    /// element, field doesn't expose `kAXSelectedTextRange`), the session is
    /// marked un-sweepable — `liveSessionSpanSnapshot` returns nil and the
    /// post-session sweep silently no-ops. This is the design doc's option A2
    /// "tracked-length" bookkeeping.
    func beginLiveSessionSpan(preferredAppPID: pid_t?) {
        guard let caretLocation = readCurrentCaretLocation(preferredAppPID: preferredAppPID) else {
            liveSessionSpan = nil
            Log.sweep.notice(
                "live auto-paste sweep unavailable: could not read caret at session start"
            )
            return
        }
        liveSessionSpan = LiveSessionSpan(
            startCaretLocation: caretLocation,
            insertedUTF16Length: 0,
            preferredAppPID: preferredAppPID
        )
    }

    /// Accumulates the UTF-16 length of text successfully inserted during the
    /// session. Called from `flushPendingRealtimeInsertion` on every successful
    /// live insertion. No-op when no session span is active (overlay sessions,
    /// or when `beginLiveSessionSpan` could not read the caret).
    func recordSuccessfulLiveInsertion(utf16Length: Int) {
        guard utf16Length > 0 else { return }
        liveSessionSpan?.insertedUTF16Length += utf16Length
    }

    /// Clears the session span tracking. Called during stop-finalization cleanup.
    func endLiveSessionSpan() {
        liveSessionSpan = nil
    }

    /// A snapshot of the tracked span, or nil if no span is active.
    var liveSessionSpanSnapshot: (startCaret: Int, insertedLength: Int, preferredAppPID: pid_t?)? {
        guard let span = liveSessionSpan else { return nil }
        return (span.startCaretLocation, span.insertedUTF16Length, span.preferredAppPID)
    }

    // MARK: - Live Auto-Paste Post-Session Sweep

    /// Attempts to revise the live-inserted text in place by replacing the
    /// tracked span with `processedText`. The full safe algorithm:
    ///
    /// 1. Read the field's full value (`kAXValue`).
    /// 2. Delegate to the pure `LiveAutoPasteSweep.computeDecision` planner,
    ///    which verifies the tracked span currently contains exactly `rawText`
    ///    (the safety guard against user edits / drift). If the decision is
    ///    `.skip`, return without writing.
    /// 3. Write the field's value with the span replaced (one AX value-set).
    /// 4. Re-read to verify the write took effect (detects silent no-ops in
    ///    web `contenteditable` fields). If unverified, fall back to
    ///    select-range + Cmd+V.
    /// 5. On any failure, leave the raw text intact — never corrupt user text.
    func performLiveAutoPasteSweep(
        rawText: String,
        processedText: String,
        startCaret: Int,
        insertedUTF16Length: Int,
        preferredAppPID: pid_t?
    ) -> LivePasteSweepOutcome {
        guard let fieldValue = readFieldValue(preferredAppPID: preferredAppPID) else {
            return .skipped(reason: "field value not readable")
        }

        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: rawText,
            processedText: processedText,
            fieldValue: fieldValue,
            startCaret: startCaret,
            insertedUTF16Length: insertedUTF16Length
        )

        switch decision {
        case .skip(let reason):
            return .skipped(reason: reason)
        case .apply(let replacement, let location, let length):
            return applySpanReplacement(
                replacement: replacement,
                location: location,
                length: length,
                originalFullValue: fieldValue,
                expectedFullValue: replaceSpanInString(
                    fieldValue, location: location, length: length, with: replacement
                ),
                preferredAppPID: preferredAppPID
            )
        }
    }

    // MARK: - Private

    private func tryAccessibilityInsertion(
        _ text: String,
        preferredAppPID: pid_t?
    ) -> Bool {
        guard insertTextUsingAccessibility(text, preferredAppPID: preferredAppPID) else { return false }
        clearAccessibilityErrorIfNeeded()
        axInsertionSuccessCount += 1
        return true
    }

    private func tryKeyboardInsertion(
        _ text: String,
        preferredAppPID: pid_t?,
        requirePreferredTargetActivation: Bool
    ) -> Bool {
        let modifiersActive = hasActiveFallbackModifiers()
        if modifiersActive {
            activeModifierFallbackCount += 1
        }

        if requirePreferredTargetActivation,
           !ensurePasteTargetIsActive(preferredAppPID: preferredAppPID)
        {
            return false
        }

        guard postUnicodeTextEvents(text) else {
            if modifiersActive {
                Log.insertion.debug("keyboard unicode insertion failed with active modifiers")
            }
            return false
        }

        if modifiersActive {
            Log.insertion.debug("keyboard unicode insertion succeeded with active modifiers")
        }
        clearAccessibilityErrorIfNeeded()
        keyboardFallbackSuccessCount += 1
        return true
    }

    private func failedInsertionResult() -> TextInsertResult {
        if !isAccessibilityTrusted {
            promptForAccessibilityPermissionIfNeeded()
            setAccessibilityErrorIfNeeded()
        }
        return .failed
    }

    private func insertTextUsingAccessibility(
        _ text: String,
        preferredAppPID: pid_t? = nil
    ) -> Bool {
#if DEBUG
        if let debugAccessibilityInserter {
            return debugAccessibilityInserter(text, preferredAppPID)
        }
#endif
        guard isAccessibilityTrusted else { return false }
        guard let focusedElement = resolvedAccessibilityInsertionTarget(
            preferredAppPID: preferredAppPID
        ) else {
            return false
        }

        // Retry once: the Accessibility API can fail on the first attempt when
        // the focused element's attribute state hasn't fully settled (common with
        // larger text blocks during finalization).
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

    // MARK: - Sweep AX Primitives

    /// Reads the caret location (UTF-16 offset) of the focused text element,
    /// used to snapshot the span start at Live Auto-Paste session start.
    private func readCurrentCaretLocation(preferredAppPID: pid_t?) -> Int? {
#if DEBUG
        if let debugCaretLocationReader {
            return debugCaretLocationReader(preferredAppPID)
        }
#endif
        guard isAccessibilityTrusted,
              let element = resolvedAccessibilityInsertionTarget(preferredAppPID: preferredAppPID)
        else {
            return nil
        }
        return readSelectedTextRangeLocation(in: element)
    }

    /// Reads the full text of the focused field (`kAXValue`). Returns nil if AX
    /// is untrusted, no target resolves, or the field does not expose its value
    /// (terminals, some web views).
    private func readFieldValue(preferredAppPID: pid_t?) -> String? {
#if DEBUG
        if let debugFieldReader {
            return debugFieldReader(preferredAppPID)
        }
#endif
        guard isAccessibilityTrusted,
              let element = resolvedAccessibilityInsertionTarget(preferredAppPID: preferredAppPID)
        else {
            return nil
        }
        var valueObject: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueObject
        )
        guard status == .success else { return nil }
        return valueObject as? String
    }

    /// Replaces the UTF-16 range `[location, location + length)` in the focused
    /// field with `replacement` by writing the full revised `kAXValue`. Returns
    /// the new full field value on success (for verify-after-write), or nil if
    /// the write failed. Also advances the caret to the end of the replacement.
    private func replaceFieldSpan(
        location: Int,
        length: Int,
        with replacement: String,
        preferredAppPID: pid_t?
    ) -> String? {
#if DEBUG
        if let debugSpanReplacer {
            return debugSpanReplacer(location, length, replacement, preferredAppPID)
        }
#endif
        guard isAccessibilityTrusted,
              let element = resolvedAccessibilityInsertionTarget(preferredAppPID: preferredAppPID),
              let currentValue = readElementValue(in: element)
        else {
            return nil
        }

        let replaced = replaceSpanInString(
            currentValue, location: location, length: length, with: replacement
        )

        guard AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, replaced as CFTypeRef
        ) == .success else {
            return nil
        }

        moveCursor(in: element,
                   to: min(location + (replacement as NSString).length,
                           (replaced as NSString).length))
        return replaced
    }

    /// Sets the field's selection to `[location, location + length)`. Used by
    /// the sweep's select-then-Cmd+V fallback when a value-write does not verify.
    private func setFieldSelection(
        location: Int,
        length: Int,
        preferredAppPID: pid_t?
    ) -> Bool {
#if DEBUG
        if let debugSelectionSetter {
            return debugSelectionSetter(location, length, preferredAppPID)
        }
#endif
        guard isAccessibilityTrusted,
              let element = resolvedAccessibilityInsertionTarget(preferredAppPID: preferredAppPID)
        else {
            return false
        }
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, rangeValue
        ) == .success
    }

    /// Executes the verified span replacement + select/Cmd+V fallback for the
    /// sweep. Split out so the main sweep method stays readable.
    private func applySpanReplacement(
        replacement: String,
        location: Int,
        length: Int,
        originalFullValue: String,
        expectedFullValue: String,
        preferredAppPID: pid_t?
    ) -> LivePasteSweepOutcome {
        guard replaceFieldSpan(
            location: location,
            length: length,
            with: replacement,
            preferredAppPID: preferredAppPID
        ) != nil else {
            return attemptSelectionPasteFallback(
                replacement: replacement,
                location: location,
                length: length,
                preferredAppPID: preferredAppPID,
                failureReason: "AX value-write failed and fallback failed; raw text left intact"
            )
        }

        // Verify-after-write: detects silent no-ops in web contenteditable
        // fields where the value-set appears to succeed but doesn't take.
        guard let verifiedValue = readFieldValue(preferredAppPID: preferredAppPID) else {
            return .failed(reason: "AX value-write could not be verified")
        }
        if verifiedValue == expectedFullValue {
            return .applied
        }
        guard verifiedValue == originalFullValue else {
            return .failed(reason: "AX value-write verification returned unexpected field value")
        }

        // Primary write did not verify. Fall back to selecting the span and
        // pasting over it only when the re-read proves the field is still at
        // its original value. If the field is in any other state, another edit
        // would risk corrupting user text.
        Log.sweep.notice(
            "live auto-paste sweep: primary write did not verify; trying select+Cmd+V fallback"
        )
        return attemptSelectionPasteFallback(
            replacement: replacement,
            location: location,
            length: length,
            preferredAppPID: preferredAppPID,
            failureReason: "primary write did not verify and fallback failed; raw text left intact"
        )
    }

    private func attemptSelectionPasteFallback(
        replacement: String,
        location: Int,
        length: Int,
        preferredAppPID: pid_t?,
        failureReason: String
    ) -> LivePasteSweepOutcome {
        if setFieldSelection(location: location, length: length, preferredAppPID: preferredAppPID),
           pasteUsingCommandV(replacement, preferredAppPID: preferredAppPID) {
            return .applied
        }
        return .failed(reason: failureReason)
    }

    // MARK: - Low-level AX Helpers

    private func readElementValue(in element: AXUIElement) -> String? {
        var valueObject: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueObject
        )
        guard status == .success else { return nil }
        return valueObject as? String
    }

    private func readSelectedTextRangeLocation(in element: AXUIElement) -> Int? {
        var rangeObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeObject
        )
        guard status == .success,
              let rangeObject,
              CFGetTypeID(rangeObject) == AXValueGetTypeID()
        else {
            return nil
        }
        let rangeValue = unsafeDowncast(rangeObject, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range.location
    }

    private func moveCursor(in element: AXUIElement, to location: Int) {
        var cursorRange = CFRange(location: location, length: 0)
        if let newSelection = AXValueCreate(.cfRange, &cursorRange) {
            _ = AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, newSelection
            )
        }
    }

    /// Pure helper: replaces `[location, location+length)` in `value` (treated
    /// as an NSString for UTF-16 offset parity with the AX API) with
    /// `replacement`, clamping the range to the string bounds.
    private func replaceSpanInString(
        _ value: String, location: Int, length: Int, with replacement: String
    ) -> String {
        let nsValue = value as NSString
        let safeLocation = min(max(0, location), nsValue.length)
        let safeLength = min(max(0, length), nsValue.length - safeLocation)
        return nsValue.replacingCharacters(
            in: NSRange(location: safeLocation, length: safeLength),
            with: replacement
        )
    }

    private func postUnicodeTextEvents(_ text: String) -> Bool {
#if DEBUG
        if let debugUnicodePoster {
            return debugUnicodePoster(text)
        }
#endif
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

    private func hasActiveFallbackModifiers() -> Bool {
#if DEBUG
        if let debugModifierStateReader {
            return debugModifierStateReader()
        }
#endif
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

#if DEBUG
extension TextInsertionService {
    struct DebugInsertionSnapshot {
        let pendingRealtimeInsertionText: String
        let axInsertionSuccessCount: Int
        let keyboardFallbackSuccessCount: Int
        let activeModifierFallbackCount: Int
    }

    func debugConfigureInsertionHooks(
        unicodePoster: ((String) -> Bool)? = nil,
        modifierStateReader: (() -> Bool)? = nil,
        accessibilityInserter: ((String, pid_t?) -> Bool)? = nil
    ) {
        debugUnicodePoster = unicodePoster
        debugModifierStateReader = modifierStateReader
        debugAccessibilityInserter = accessibilityInserter
    }

    func debugInsertionSnapshot() -> DebugInsertionSnapshot {
        DebugInsertionSnapshot(
            pendingRealtimeInsertionText: pendingRealtimeInsertionText,
            axInsertionSuccessCount: axInsertionSuccessCount,
            keyboardFallbackSuccessCount: keyboardFallbackSuccessCount,
            activeModifierFallbackCount: activeModifierFallbackCount
        )
    }

    /// Configures DEBUG-only hooks that back the sweep's Accessibility
    /// operations. When set, the sweep's caret read / field read / span
    /// replace / selection set route through these closures instead of real
    /// AX, so tests can model a target field and exercise the decision logic
    /// and span arithmetic headlessly. Pass `nil` for any hook to restore real
    /// AX behavior for that operation.
    func debugConfigureSweepHooks(
        caretLocationReader: ((pid_t?) -> Int?)? = nil,
        fieldReader: ((pid_t?) -> String?)? = nil,
        spanReplacer: ((Int, Int, String, pid_t?) -> String?)? = nil,
        selectionSetter: ((Int, Int, pid_t?) -> Bool)? = nil,
        clearExisting: Bool = true
    ) {
        if clearExisting {
            debugCaretLocationReader = nil
            debugFieldReader = nil
            debugSpanReplacer = nil
            debugSelectionSetter = nil
        }
        if let caretLocationReader { debugCaretLocationReader = caretLocationReader }
        if let fieldReader { debugFieldReader = fieldReader }
        if let spanReplacer { debugSpanReplacer = spanReplacer }
        if let selectionSetter { debugSelectionSetter = selectionSetter }
    }

    /// Test-only accessor for the live session span bookkeeping.
    func debugLiveSessionSpanSnapshot() -> (startCaret: Int, insertedLength: Int)? {
        guard let span = liveSessionSpan else { return nil }
        return (span.startCaretLocation, span.insertedUTF16Length)
    }
}
#endif
