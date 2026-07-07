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

    private var pendingRealtimeInsertionText = ""
    private var insertionRetryTask: Task<Void, Never>?
    private var axInsertionSuccessCount = 0
    private var keyboardFallbackSuccessCount = 0
    private var activeModifierFallbackCount = 0

    // Optional guard for Live Auto-Paste streaming replacements. When the
    // target exposes a caret location, track where our typed session text
    // should end; if the caret diverges, corrections stand down for the rest
    // of the session.
    @ObservationIgnored
    private var liveSessionSpan: LiveSessionSpan?
    @ObservationIgnored
    private var liveReplacementCorrector: LiveReplacementCorrector?
    @ObservationIgnored
    private var didLogLiveReplacementStandDown = false
    @ObservationIgnored
    private var isLiveReplacementCorrectionInFlight = false
    @ObservationIgnored
    private var liveReplacementCorrectionTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingFinalLiveReplacementFlush = false
    private let liveReplacementCaretSettleInterval: Duration = .milliseconds(10)
    private let liveReplacementCaretSettleAttemptCount = 15

    // Hold-back strategy for targets where post-typing backspace corrections
    // cannot be verified (terminals, caret-less targets): replacements are
    // applied BEFORE typing and no backspaces are ever posted. Mutually
    // exclusive with `liveReplacementCorrector`.
    @ObservationIgnored
    private var liveHoldBackStream: LiveHoldBackReplacementStream?
    /// Stream-released (already corrected/sanitized) text whose insertion
    /// failed; retried as-is and never re-ingested into the stream.
    @ObservationIgnored
    private var pendingHoldBackReleasedText = ""

    private struct LiveSessionSpan: Sendable {
        var startCaretLocation: Int
        var insertedUTF16Length: Int
        let preferredAppPID: pid_t?
    }

    private enum LiveReplacementCorrectionPhase: Equatable, Sendable {
        case insertedTextPosted
        case backspacePosted
    }

    private enum LiveReplacementCorrectionResult {
        case applied
        case waiting
        case stopped
    }

#if DEBUG
    @ObservationIgnored
    private var debugUnicodePoster: ((String) -> Bool)?
    @ObservationIgnored
    private var debugBackspacePoster: ((Int) -> Bool)?
    @ObservationIgnored
    private var debugModifierStateReader: (() -> Bool)?
    @ObservationIgnored
    private var debugAccessibilityInserter: ((String, pid_t?) -> Bool)?
    @ObservationIgnored
    private var debugCaretLocationReader: ((pid_t?) -> Int?)?
    @ObservationIgnored
    private var debugLiveReplacementSettleSleep: (() async -> Void)?
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
        if liveHoldBackStream != nil {
            flushLiveHoldBackStream(releaseRemainder: false)
            return
        }

        guard !pendingRealtimeInsertionText.isEmpty else { return }
        guard !isLiveReplacementCorrectionInFlight else { return }

        let insertedText = pendingRealtimeInsertionText
        let result = insertTextPrioritizingKeyboard(insertedText)

        switch result {
        case .insertedByAccessibility, .insertedByKeyboardFallback:
            pendingRealtimeInsertionText.removeAll(keepingCapacity: true)
            recordSuccessfulLiveInsertion(
                text: insertedText,
                result: result
            )
        case .failed:
            standDownLiveReplacementCorrections(
                reason: "realtime insertion failed"
            )
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
        liveReplacementCorrectionTask?.cancel()
        liveReplacementCorrectionTask = nil
        isLiveReplacementCorrectionInFlight = false
        pendingFinalLiveReplacementFlush = false
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
        didLogLiveReplacementStandDown = false
        liveReplacementCorrector = nil
        liveSessionSpan = nil
        liveHoldBackStream = nil
        pendingHoldBackReleasedText = ""

        let entryCount = dictionary?.entries.count ?? 0
        let corrector = dictionary.map { LiveReplacementCorrector(dictionary: $0) }
        let ruleCount = corrector?.ruleCount ?? 0

        if isTerminalLikeTarget {
            // Terminals expose a screen-grid caret over the whole scrollback
            // buffer, so post-typing backspace corrections can never be
            // verified there (field bug 2026-07-06: the caret guard armed,
            // the first correction timed out, and the corrector stood down).
            // Replacements are applied before typing instead, and newlines
            // are collapsed so a typed newline can never act as Enter and
            // submit a prompt mid-dictation.
            liveHoldBackStream = LiveHoldBackReplacementStream(
                dictionary: dictionary ?? ReplacementDictionary(entries: []),
                sanitizesNewlines: true
            )
            Log.corrector.notice(
                "corrector armed strategy=holdback reason=terminal entries=\(entryCount, privacy: .public) rules=\(ruleCount, privacy: .public) newline_sanitize=on"
            )
            return
        }

        guard let dictionary, let corrector, corrector.hasRules else {
            if entryCount > 0 {
                Log.corrector.notice(
                    "corrector stand-down reason=no valid rules entries=\(entryCount, privacy: .public)"
                )
            }
            return
        }

        if let caretLocation = readCurrentCaretLocation(preferredAppPID: preferredAppPID) {
            liveReplacementCorrector = corrector
            liveSessionSpan = LiveSessionSpan(
                startCaretLocation: caretLocation,
                insertedUTF16Length: 0,
                preferredAppPID: preferredAppPID
            )
            Log.corrector.notice(
                "corrector armed strategy=guarded-corrector entries=\(entryCount, privacy: .public) rules=\(ruleCount, privacy: .public) caret_guard=on"
            )
        } else {
            // No readable caret means backspace corrections cannot be
            // verified — and unverified backspaces are never posted into a
            // target whose state we cannot observe. Hold text back and apply
            // replacements before typing instead.
            liveHoldBackStream = LiveHoldBackReplacementStream(
                dictionary: dictionary,
                sanitizesNewlines: false
            )
            Log.corrector.notice(
                "corrector armed strategy=holdback reason=caret-unavailable entries=\(entryCount, privacy: .public) rules=\(ruleCount, privacy: .public) newline_sanitize=off"
            )
        }
    }

    /// Accumulates the UTF-16 length of text successfully inserted during the
    /// session. Kept as a narrow test hook for the caret guard bookkeeping.
    func recordSuccessfulLiveInsertion(utf16Length: Int) {
        guard utf16Length > 0 else { return }
        liveSessionSpan?.insertedUTF16Length += utf16Length
    }

    func endLiveReplacementSession() {
        liveReplacementCorrectionTask?.cancel()
        liveReplacementCorrectionTask = nil
        isLiveReplacementCorrectionInFlight = false
        pendingFinalLiveReplacementFlush = false
        liveSessionSpan = nil
        liveReplacementCorrector = nil
        liveHoldBackStream = nil
        // pendingHoldBackReleasedText intentionally survives: the session
        // cleanup path reads hasPendingInsertionText to surface lost text
        // before calling clearPendingText().
        didLogLiveReplacementStandDown = false
    }

    func flushFinalLiveReplacementCorrections() {
        if liveHoldBackStream != nil {
            flushLiveHoldBackStream(releaseRemainder: true)
            return
        }
        if isLiveReplacementCorrectionInFlight {
            pendingFinalLiveReplacementFlush = true
            return
        }
        processLiveReplacementCorrections(includeFinalUnboundedWord: true)
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

        guard !releasedText.isEmpty else { return }

        switch insertTextPrioritizingKeyboard(releasedText) {
        case .insertedByAccessibility, .insertedByKeyboardFallback:
            break
        case .failed:
            // Keep the released text verbatim for the retry task; it must
            // never be re-ingested into the stream.
            pendingHoldBackReleasedText = releasedText
            Log.corrector.notice(
                "corrector holdback release failed chars=\(releasedText.count, privacy: .public) queued_for_retry=1"
            )
        }
    }

    private func recordSuccessfulLiveInsertion(
        text: String,
        result: TextInsertResult
    ) {
        recordSuccessfulLiveInsertion(utf16Length: (text as NSString).length)

        guard liveReplacementCorrector != nil else { return }
        guard result == .insertedByKeyboardFallback else {
            standDownLiveReplacementCorrections(
                reason: "realtime insertion did not use the keyboard path"
            )
            return
        }

        liveReplacementCorrector?.recordInsertedText(text)
        processLiveReplacementCorrections(includeFinalUnboundedWord: false)
    }

    private func processLiveReplacementCorrections(includeFinalUnboundedWord: Bool) {
        guard !isLiveReplacementCorrectionInFlight else { return }

        while let correction = liveReplacementCorrector?.nextCompletedBoundaryCorrection() {
            switch applyOrDeferLiveReplacementCorrection(correction) {
            case .applied:
                continue
            case .waiting, .stopped:
                return
            }
        }

        if includeFinalUnboundedWord,
           let correction = liveReplacementCorrector?.finalUnboundedCorrection()
        {
            _ = applyOrDeferLiveReplacementCorrection(correction)
        }
    }

    private func applyOrDeferLiveReplacementCorrection(
        _ correction: LiveReplacementCorrection
    ) -> LiveReplacementCorrectionResult {
        guard liveReplacementCorrector != nil else { return .stopped }
        guard liveSessionSpan != nil else {
            // The guarded corrector never runs without an armed caret guard
            // (caret-less sessions use the hold-back stream instead), so a
            // missing span mid-session means the session state was torn down.
            // Never post unverified backspaces.
            standDownLiveReplacementCorrections(reason: "caret guard unavailable")
            return .stopped
        }
        guard let expectedInsertedCaret = expectedLiveReplacementCaretLocation() else {
            standDownLiveReplacementCorrections(reason: "caret unavailable")
            return .stopped
        }

        switch currentCaretSettlement(expectedLocation: expectedInsertedCaret) {
        case .unavailable:
            standDownLiveReplacementCorrections(reason: "caret unavailable")
            return .stopped
        case .mismatched:
            beginDeferredLiveReplacementCorrection(correction, phase: .insertedTextPosted)
            return .waiting
        case .matched:
            return postBackspaceAndFinishLiveReplacementCorrection(correction)
        }
    }

    private func postBackspaceAndFinishLiveReplacementCorrection(
        _ correction: LiveReplacementCorrection
    ) -> LiveReplacementCorrectionResult {
        guard postBackspaceEvents(count: correction.backspaceCount) else {
            standDownLiveReplacementCorrections(reason: "keyboard correction failed")
            return .stopped
        }

        guard let expectedErasedCaret = expectedErasedCaretLocation(for: correction) else {
            standDownLiveReplacementCorrections(reason: "caret unavailable")
            return .stopped
        }

        switch currentCaretSettlement(expectedLocation: expectedErasedCaret) {
        case .unavailable:
            standDownLiveReplacementCorrections(reason: "caret unavailable")
            return .stopped
        case .mismatched:
            beginDeferredLiveReplacementCorrection(correction, phase: .backspacePosted)
            return .waiting
        case .matched:
            return postReplacementAndRecordLiveReplacementCorrection(correction)
        }
    }

    private func postReplacementAndRecordLiveReplacementCorrection(
        _ correction: LiveReplacementCorrection
    ) -> LiveReplacementCorrectionResult {
        guard postUnicodeTextEvents(correction.replacementText) else {
            _ = postUnicodeTextEvents(correction.erasedText)
            standDownLiveReplacementCorrections(reason: "keyboard correction failed")
            return .stopped
        }

        liveReplacementCorrector?.apply(correction)
        liveSessionSpan?.insertedUTF16Length +=
            (correction.replacementText as NSString).length - (correction.erasedText as NSString).length
        Log.corrector.notice(
            "corrector correction posted erased_chars=\(correction.erasedText.count, privacy: .public) replacement_chars=\(correction.replacementText.count, privacy: .public)"
        )
        return .applied
    }

    private enum CaretSettlement {
        case matched
        case mismatched
        case unavailable
    }

    private func currentCaretSettlement(expectedLocation: Int) -> CaretSettlement {
        guard let span = liveSessionSpan else { return .unavailable }
        guard let caretLocation = readCurrentCaretLocation(preferredAppPID: span.preferredAppPID) else {
            return .unavailable
        }
        return caretLocation == expectedLocation ? .matched : .mismatched
    }

    private func expectedLiveReplacementCaretLocation() -> Int? {
        guard let span = liveSessionSpan else { return nil }
        return span.startCaretLocation + span.insertedUTF16Length
    }

    private func expectedErasedCaretLocation(for correction: LiveReplacementCorrection) -> Int? {
        guard let expectedInsertedCaret = expectedLiveReplacementCaretLocation() else { return nil }
        return expectedInsertedCaret - (correction.erasedText as NSString).length
    }

    private func beginDeferredLiveReplacementCorrection(
        _ correction: LiveReplacementCorrection,
        phase: LiveReplacementCorrectionPhase
    ) {
        guard !isLiveReplacementCorrectionInFlight else { return }
        isLiveReplacementCorrectionInFlight = true
        liveReplacementCorrectionTask = Task { @MainActor [weak self] in
            await self?.completeDeferredLiveReplacementCorrection(correction, startingAt: phase)
        }
    }

    private func completeDeferredLiveReplacementCorrection(
        _ correction: LiveReplacementCorrection,
        startingAt phase: LiveReplacementCorrectionPhase
    ) async {
        guard liveReplacementCorrector != nil else {
            finishDeferredLiveReplacementCorrection()
            return
        }

        var currentPhase = phase
        if currentPhase == .insertedTextPosted {
            guard let expectedInsertedCaret = expectedLiveReplacementCaretLocation() else {
                standDownLiveReplacementCorrections(reason: "caret unavailable")
                finishDeferredLiveReplacementCorrection()
                return
            }
            guard await waitForLiveReplacementCaret(expectedLocation: expectedInsertedCaret) else {
                standDownLiveReplacementCorrections(reason: "tracked caret diverged")
                finishDeferredLiveReplacementCorrection()
                return
            }
            guard postBackspaceEvents(count: correction.backspaceCount) else {
                standDownLiveReplacementCorrections(reason: "keyboard correction failed")
                finishDeferredLiveReplacementCorrection()
                return
            }
            currentPhase = .backspacePosted
        }

        if currentPhase == .backspacePosted {
            guard let expectedErasedCaret = expectedErasedCaretLocation(for: correction) else {
                standDownLiveReplacementCorrections(reason: "caret unavailable")
                finishDeferredLiveReplacementCorrection()
                return
            }
            guard await waitForLiveReplacementCaret(expectedLocation: expectedErasedCaret) else {
                standDownLiveReplacementCorrections(reason: "tracked caret diverged")
                finishDeferredLiveReplacementCorrection()
                return
            }
        }

        _ = postReplacementAndRecordLiveReplacementCorrection(correction)
        finishDeferredLiveReplacementCorrection()
    }

    private func waitForLiveReplacementCaret(expectedLocation: Int) async -> Bool {
        for _ in 0 ..< liveReplacementCaretSettleAttemptCount {
            await sleepForLiveReplacementCaretSettleInterval()
            switch currentCaretSettlement(expectedLocation: expectedLocation) {
            case .matched:
                return true
            case .mismatched:
                continue
            case .unavailable:
                return false
            }
        }
        Log.corrector.notice(
            "corrector settle timeout expected_utf16=\(expectedLocation, privacy: .public)"
        )
        return false
    }

    private func sleepForLiveReplacementCaretSettleInterval() async {
#if DEBUG
        if let debugLiveReplacementSettleSleep {
            await debugLiveReplacementSettleSleep()
            return
        }
#endif
        try? await Task.sleep(for: liveReplacementCaretSettleInterval)
    }

    private func finishDeferredLiveReplacementCorrection() {
        liveReplacementCorrectionTask = nil
        isLiveReplacementCorrectionInFlight = false
        let shouldFlushFinalCorrection = pendingFinalLiveReplacementFlush
        pendingFinalLiveReplacementFlush = false

        processLiveReplacementCorrections(includeFinalUnboundedWord: shouldFlushFinalCorrection)
        flushPendingRealtimeInsertion()
    }

    private func standDownLiveReplacementCorrections(reason: String) {
        guard liveReplacementCorrector != nil else { return }
        liveReplacementCorrector?.standDown()
        if !didLogLiveReplacementStandDown {
            didLogLiveReplacementStandDown = true
            Log.corrector.notice(
                "corrector stand-down reason=\(reason, privacy: .public)"
            )
        }
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

    /// Reads the caret location (UTF-16 offset) of the focused text element,
    /// used as an optional divergence guard for Live Auto-Paste corrections.
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

    // MARK: - Low-level AX Helpers

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

    private func postBackspaceEvents(count: Int) -> Bool {
#if DEBUG
        if let debugBackspacePoster {
            return debugBackspacePoster(count)
        }
#endif
        guard count > 0 else { return true }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        for _ in 0 ..< count {
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 51,
                keyDown: true
            ),
                  let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 51,
                    keyDown: false
                  )
            else {
                return false
            }

            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }

        return true
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
        backspacePoster: ((Int) -> Bool)? = nil,
        modifierStateReader: (() -> Bool)? = nil,
        accessibilityInserter: ((String, pid_t?) -> Bool)? = nil,
        caretLocationReader: ((pid_t?) -> Int?)? = nil,
        liveReplacementSettleSleep: (() async -> Void)? = nil
    ) {
        debugUnicodePoster = unicodePoster
        debugBackspacePoster = backspacePoster
        debugModifierStateReader = modifierStateReader
        debugAccessibilityInserter = accessibilityInserter
        debugCaretLocationReader = caretLocationReader
        debugLiveReplacementSettleSleep = liveReplacementSettleSleep
    }

    func debugInsertionSnapshot() -> DebugInsertionSnapshot {
        DebugInsertionSnapshot(
            pendingRealtimeInsertionText: pendingRealtimeInsertionText,
            axInsertionSuccessCount: axInsertionSuccessCount,
            keyboardFallbackSuccessCount: keyboardFallbackSuccessCount,
            activeModifierFallbackCount: activeModifierFallbackCount
        )
    }

    /// Test-only accessor for the live session span bookkeeping.
    func debugLiveSessionSpanSnapshot() -> (startCaret: Int, insertedLength: Int)? {
        guard let span = liveSessionSpan else { return nil }
        return (span.startCaretLocation, span.insertedUTF16Length)
    }

    var debugLiveReplacementCorrectorIsActive: Bool {
        liveReplacementCorrector?.isStandingDown == false
    }

    var debugLiveHoldBackStreamIsActive: Bool {
        liveHoldBackStream != nil
    }

    var debugLiveReplacementCorrectionIsInFlight: Bool {
        isLiveReplacementCorrectionInFlight
    }

    func debugWaitForLiveReplacementCorrectionTasks() async {
        while let task = liveReplacementCorrectionTask {
            await task.value
        }
    }

    /// Forces the Accessibility trust verdict for tests. Pass `nil` to restore
    /// the real `AXIsProcessTrusted()` checker.
    func debugSetAccessibilityTrusted(_ trusted: Bool?) {
        accessibilityTrust.debugSetTrustOverride(trusted)
    }
}
#endif
