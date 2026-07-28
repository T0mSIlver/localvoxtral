import AppKit
import ApplicationServices
import Foundation
import Observation
import os

enum TextInsertResult: Equatable {
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

    /// Opt-in field diagnostic: when the marker file
    /// `insertion_scalar_trace` exists in the shared config folder, every
    /// UTF-16 chunk posted as keyboard events is hex-logged (see
    /// `postUnicodeTextEvents`). Set once per session at session start.
    var isScalarTracingEnabled = false

    private var pendingRealtimeInsertionText = ""
    private var insertionRetryTask: Task<Void, Never>?
    private var axInsertionSuccessCount = 0
    private var keyboardFallbackSuccessCount = 0
    private var activeModifierFallbackCount = 0

    // Live Auto-Paste streaming replacements apply the dictionary to
    // transcript text BEFORE it is typed, via a hold-back stream: text is
    // held until it can no longer participate in a rule match, replacements
    // are applied to the held text, and only corrected text is ever released
    // for typing. No caret reads, no backspaces — the post-typing backspace
    // corrector was removed (it could never win the race against async
    // CGEvent delivery and produced zero successful field corrections). Nil
    // when no replacement applies (dictionary disabled / no rules /
    // non-terminal with no rules); transcript text is then typed directly.
    @ObservationIgnored
    private var liveHoldBackStream: LiveHoldBackReplacementStream?
    /// Stream-released (already corrected/sanitized) text whose insertion
    /// failed; retried as-is and never re-ingested into the stream.
    @ObservationIgnored
    private var pendingHoldBackReleasedText = ""
    /// Whether this live session's target is terminal-like. TUI autocomplete
    /// popups only exist there, so the trailing-space policy is scoped to it
    /// (`TUIAutocompleteTrailingSpace`).
    @ObservationIgnored
    private var liveTargetIsTerminalLike = false
    /// Everything the hold-back stream released AND successfully handed to the
    /// field this session. The trailing-space policy judges the WHOLE
    /// utterance ("is this only a slash command?"), so the stop flush needs
    /// what came before it. Read-only by construction: typed text is in the
    /// user's app and can never be recalled.
    @ObservationIgnored
    private var liveTypedTextForSession = ""

#if DEBUG
    @ObservationIgnored
    private var debugUnicodePoster: ((String) -> Bool)?
    @ObservationIgnored
    private var debugModifierStateReader: (() -> Bool)?
    @ObservationIgnored
    private var debugAccessibilityInserter: ((String, pid_t?) -> Bool)?
#endif

    static let accessibilityErrorMessage = AccessibilityTrustManager.errorMessage

    var hasPendingInsertionText: Bool {
        !pendingRealtimeInsertionText.isEmpty || !pendingHoldBackReleasedText.isEmpty
    }

    func drainPendingInsertionText() -> String {
        let text = pendingHoldBackReleasedText + pendingRealtimeInsertionText
        pendingHoldBackReleasedText = ""
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
        // Replacement-active sessions route all transcript text through the
        // hold-back stream (replacements applied before typing). Sessions with
        // no active stream (dictionary disabled / no rules) type directly.
        if liveHoldBackStream != nil {
            flushLiveHoldBackStream(releaseRemainder: false)
            return
        }

        guard !pendingRealtimeInsertionText.isEmpty else { return }

        let insertedText = pendingRealtimeInsertionText
        switch insertTextPrioritizingKeyboard(insertedText) {
        case .insertedByAccessibility, .insertedByKeyboardFallback:
            pendingRealtimeInsertionText.removeAll(keepingCapacity: true)
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
                guard self.hasPendingInsertionText else { continue }
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
        pendingHoldBackReleasedText = ""
    }

    // MARK: - Live Auto-Paste Replacement Tracking

    func beginLiveReplacementSession(
        dictionary: ReplacementDictionary?,
        preferredAppPID: pid_t?,
        isTerminalLikeTarget: Bool = false
    ) {
        liveHoldBackStream = nil
        pendingHoldBackReleasedText = ""
        liveTargetIsTerminalLike = isTerminalLikeTarget
        liveTypedTextForSession = ""

        let entryCount = dictionary?.entries.count ?? 0
        let ruleCount = dictionary.map { LiveReplacementCorrector(dictionary: $0).ruleCount } ?? 0

        if isTerminalLikeTarget {
            // Terminals expose a screen-grid caret over the whole scrollback
            // buffer, so replacements are always applied before typing and a
            // typed newline/tab is collapsed to a space — it can never act as
            // Enter and submit a prompt (or trigger completion) mid-dictation.
            // The hold-back stream is armed even with no rules so the newline
            // sanitization still runs.
            liveHoldBackStream = LiveHoldBackReplacementStream(
                dictionary: dictionary ?? ReplacementDictionary(entries: []),
                sanitizesNewlines: true
            )
            Log.corrector.notice(
                "corrector armed strategy=holdback reason=terminal entries=\(entryCount, privacy: .public) rules=\(ruleCount, privacy: .public) newline_sanitize=on"
            )
            return
        }

        // Non-terminal: with no valid rules there is nothing to correct, so
        // text is typed directly (no hold-back delay). With rules, apply them
        // before typing via the same stream (newline sanitization off — a
        // real editor should keep the user's newlines).
        guard let dictionary, LiveReplacementCorrector(dictionary: dictionary).hasRules else {
            if entryCount > 0 {
                Log.corrector.notice(
                    "corrector stand-down reason=no valid rules entries=\(entryCount, privacy: .public)"
                )
            }
            return
        }

        liveHoldBackStream = LiveHoldBackReplacementStream(
            dictionary: dictionary,
            sanitizesNewlines: false
        )
        Log.corrector.notice(
            "corrector armed strategy=holdback entries=\(entryCount, privacy: .public) rules=\(ruleCount, privacy: .public) newline_sanitize=off"
        )
    }

    func endLiveReplacementSession() {
        // Teardown: flush any text the stream is still holding so a stopped
        // session never drops its trailing word(s). Idempotent with the
        // production stop flow, which calls flushFinalLiveReplacementCorrections
        // first — a second remainder flush releases nothing (already at the
        // end) and only retries text whose insertion had failed.
        if liveHoldBackStream != nil {
            flushLiveHoldBackStream(releaseRemainder: true)
        }
        liveHoldBackStream = nil
        // pendingHoldBackReleasedText intentionally survives: the session
        // cleanup path reads hasPendingInsertionText to surface lost text
        // before calling clearPendingText().
    }

    func flushFinalLiveReplacementCorrections() {
        // Session stop: release the whole held tail with replacements applied.
        guard liveHoldBackStream != nil else { return }
        flushLiveHoldBackStream(releaseRemainder: true)
    }

    // MARK: - Private

    /// Hold-back flush path: pending raw transcript text is ingested into the
    /// stream and only what the stream releases (already corrected, already
    /// sanitized) is typed. Text still held by the stream is neither typed
    /// nor retried until the stream releases it — the retry task only ever
    /// retypes `pendingHoldBackReleasedText`, so held text cannot be
    /// double-inserted.
    private func flushLiveHoldBackStream(releaseRemainder: Bool) {
        guard var stream = liveHoldBackStream else { return }

        let rawText = pendingRealtimeInsertionText
        pendingRealtimeInsertionText.removeAll(keepingCapacity: true)
        var releasedText = pendingHoldBackReleasedText
        pendingHoldBackReleasedText = ""

        if !rawText.isEmpty {
            releasedText += stream.ingest(rawText)
        }
        if releaseRemainder {
            releasedText += stream.flushRemainder()
        }
        liveHoldBackStream = stream

        if releaseRemainder, liveTargetIsTerminalLike {
            releasedText = withholdingTUIAutocompleteTrailingSpace(releasedText)
        }

        guard !releasedText.isEmpty else { return }

        switch insertTextPrioritizingKeyboard(releasedText) {
        case .insertedByAccessibility, .insertedByKeyboardFallback:
            liveTypedTextForSession += releasedText
        case .failed:
            // Keep the released text verbatim for the retry task; it must
            // never be re-ingested into the stream.
            pendingHoldBackReleasedText = releasedText
            Log.corrector.notice(
                "corrector holdback release failed chars=\(releasedText.count, privacy: .public) queued_for_retry=1"
            )
        }
    }

    /// Stop-flush trailing-space policy for terminal targets: a lone slash
    /// command (or an utterance ending on an `@mention`) must reach the agent
    /// TUI without the space that would confirm/dismiss its autocomplete popup
    /// (`TUIAutocompleteTrailingSpace`).
    ///
    /// The stop flush is the complete choke point for a terminal session: with
    /// newline sanitization on, `LiveHoldBackReplacementStream` buffers every
    /// trailing whitespace run — the full `Character.isWhitespace` set, NBSP
    /// included — until the next non-whitespace character, so no mid-session
    /// release can ever END in whitespace — the only trailing space a terminal
    /// ever sees is the one emitted here.
    ///
    /// The verdict is taken on the whole session's text, but only the
    /// not-yet-typed tail may be cut (`min` below). That is the same
    /// never-un-type invariant the hold-back stream enforces: text already
    /// handed to the field is in the user's app and there are no backspaces in
    /// the insertion path.
    ///
    /// ACCEPTED LIMITATION (codex review of #198): "the whole session's text"
    /// is exactly that — text the FIELD already held before dictation started
    /// is invisible here. The insertion path cannot read field content and no
    /// popup-state signal exists, so dictating a command-shaped utterance
    /// (`/compact `) after a hand-typed `fix ` prefix withholds a space no
    /// popup consumed, and the user's next keystroke glues to `/compact`.
    /// Accepted deliberately: mid-line command-shaped dictation into a
    /// pre-populated prompt is rare, while the dismissed-popup case this
    /// policy exists for — a genuinely lone command — is the common one.
    /// Pinned by `testPrePopulatedFieldTextCannotRescueTheTrailingSpace`;
    /// changing that behavior is a policy revision, not a refactor.
    private func withholdingTUIAutocompleteTrailingSpace(_ releasedText: String) -> String {
        let sessionText = liveTypedTextForSession + releasedText
        let stripped = TUIAutocompleteTrailingSpace.stripped(sessionText)
        let dropCount = min(sessionText.count - stripped.count, releasedText.count)
        guard dropCount > 0 else { return releasedText }

        Log.corrector.notice(
            "tui autocomplete: withheld \(dropCount, privacy: .public) trailing whitespace char(s) at stop"
        )
        return String(releasedText.dropLast(dropCount))
    }

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

    // MARK: - Caret Guard

    // MARK: - Low-level AX Helpers

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

            if isScalarTracingEnabled {
                // Opt-in field diagnostic (marker file in the config folder):
                // logs the exact UTF-16 units handed to keyboardSetUnicodeString,
                // chunk boundaries included, so pipeline corruption (e.g. a
                // split surrogate pair) is visible in the unified log. The hex
                // IS transcript content — hence opt-in and privacy: .public.
                let hex = chunk.map { String(format: "%04X", $0) }.joined(separator: " ")
                Log.insertion.notice(
                    "scalar-trace chunk[\(i, privacy: .public)..<\(end, privacy: .public)]: \(hex, privacy: .public)"
                )
            }

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

    var debugLiveHoldBackStreamIsActive: Bool {
        liveHoldBackStream != nil
    }

    /// Forces the Accessibility trust verdict for tests. Pass `nil` to restore
    /// the real `AXIsProcessTrusted()` checker.
    func debugSetAccessibilityTrusted(_ trusted: Bool?) {
        accessibilityTrust.debugSetTrustOverride(trusted)
    }
}
#endif
