import AppKit
import Foundation
import os

@MainActor
protocol OverlayBufferRendering: AnyObject {
    func render(snapshot: OverlayBufferStateMachine.Snapshot?)
    func hide()
}

extension DictationOverlayController: OverlayBufferRendering {}

@MainActor
protocol OverlayAnchorResolving: AnyObject {
    func resolveAnchor() -> OverlayAnchor
    func resolveFrontmostAppPID() -> pid_t?
}

extension OverlayAnchorResolver: OverlayAnchorResolving {}

@MainActor
protocol OverlayTextCommitting: AnyObject {
    var isAccessibilityTrusted: Bool { get }

    func insertTextPrioritizingKeyboard(_ text: String, preferredAppPID: pid_t?) -> TextInsertResult
    func pasteUsingCommandV(_ text: String, preferredAppPID: pid_t?) -> Bool
}

extension TextInsertionService: OverlayTextCommitting {}

enum OverlayBufferCommitOutcome: Equatable {
    case succeeded
    case failed(message: String)
    /// Secure Keyboard Entry blocked synthetic insertion; the text was put on
    /// the clipboard instead. Unlike `.failed` (whose panel persists so the
    /// user can see text that may exist nowhere else), this panel is
    /// dismissed after a readable hold — the words are safe.
    case copiedToClipboard(message: String)
}

@MainActor
protocol OverlayBufferSessionCoordinating: AnyObject {
    func resolveAnchorNow() -> OverlayAnchor
    func startSession(preResolvedAnchor: OverlayAnchor?)
    func beginFinalizing(displayBufferText: String, commitBufferText: String)
    func refresh(displayBufferText: String, commitBufferText: String)
    @discardableResult
    func commitIfNeeded(using textCommitter: OverlayTextCommitting, autoCopyEnabled: Bool) -> OverlayBufferCommitOutcome
    func dismissAfterHold(minimumVisibility: TimeInterval)
    func reset()
    /// Latches the frontmost non-self app PID for use as a commit/correction target,
    /// without starting an overlay session. Used by Live Auto-Paste mode to
    /// capture the original target app at session start so the post-session
    /// live replacement guard can re-target it even if focus moved.
    func captureLiveCommitTargetAppPID()
    var commitTargetAppPID: pid_t? { get }
    /// Surfaces the Secure Keyboard Entry warning inside the overlay panel
    /// while buffering. Defaulted so test doubles stay unchanged.
    func showSecureInputWarning()
    /// Flags that LLM polishing changed the committed text vs the raw
    /// transcript, so the overlay shows the "Polished" badge while the polished
    /// text is held before dismissal. Defaulted so test doubles stay unchanged.
    func markPolished(_ polished: Bool)
}

extension OverlayBufferSessionCoordinating {
    func showSecureInputWarning() {}
    func markPolished(_ polished: Bool) {}
}

@MainActor
final class OverlayBufferSessionCoordinator: OverlayBufferSessionCoordinating {
    typealias DateProvider = () -> Date
    typealias SleepClosure = (Duration) async -> Void
    /// Returns whether the write landed — under secure input the clipboard
    /// is the only preservation path, so a failed write must keep the panel.
    typealias PasteboardWriter = (String) -> Bool

    private var stateMachine: OverlayBufferStateMachine
    private let renderer: OverlayBufferRendering
    private let anchorResolver: OverlayAnchorResolving
    // Injected time source so hold-before-dismiss timing is testable without wall-clock sleeps.
    private let now: DateProvider
    private let sleepFor: SleepClosure
    // Injected so tests don't require a pasteboard server (headless CI users
    // have none) and don't clobber the host session's clipboard.
    private let copyToPasteboard: PasteboardWriter

    private var commitBufferText = ""
    private var liveCommitTargetAppPID: pid_t?
    private var finalizationCommitTargetAppPID: pid_t?
    // Tracks only visible display-text changes; phase/anchor changes do not reset hold timing.
    private var lastOverlayDisplayTextChangeAt: Date?
    private var dismissTask: Task<Void, Never>?

    init(
        stateMachine: OverlayBufferStateMachine,
        renderer: OverlayBufferRendering,
        anchorResolver: OverlayAnchorResolving,
        now: @escaping DateProvider = Date.init,
        sleepFor: @escaping SleepClosure = { duration in
            try? await Task.sleep(for: duration)
        },
        copyToPasteboard: @escaping PasteboardWriter = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    ) {
        self.stateMachine = stateMachine
        self.renderer = renderer
        self.anchorResolver = anchorResolver
        self.now = now
        self.sleepFor = sleepFor
        self.copyToPasteboard = copyToPasteboard
    }

    func resolveAnchorNow() -> OverlayAnchor {
        anchorResolver.resolveAnchor()
    }

    func startSession(preResolvedAnchor: OverlayAnchor? = nil) {
        dismissTask?.cancel()
        dismissTask = nil
        commitBufferText = ""
        lastOverlayDisplayTextChangeAt = nil
        finalizationCommitTargetAppPID = nil
        refreshLiveCommitTargetAppPID()

        let anchor = preResolvedAnchor ?? anchorResolver.resolveAnchor()
        stateMachine.startSession(anchor: anchor)
        renderCurrentSnapshot()
        Log.overlay.info("overlay session started (preResolved=\(preResolvedAnchor != nil, privacy: .public))")
    }

    func beginFinalizing(displayBufferText: String, commitBufferText: String) {
        lockCommitTargetForFinalizationIfNeeded()
        let previousOverlayDisplayText = stateMachine.bufferText
        let anchor = anchorResolver.resolveAnchor()

        stateMachine.beginFinalizing(anchor: anchor)
        stateMachine.updateBuffer(text: displayBufferText, anchor: anchor)
        recordOverlayDisplayTextChangeIfNeeded(
            previousOverlayDisplayText: previousOverlayDisplayText,
            newOverlayDisplayText: stateMachine.bufferText
        )
        self.commitBufferText = commitBufferText
        renderCurrentSnapshot()
        Log.overlay.info("overlay begin finalizing")
    }

    func refresh(displayBufferText: String, commitBufferText: String) {
        guard stateMachine.phase == .buffering || stateMachine.phase == .finalizing else { return }
        let previousOverlayDisplayText = stateMachine.bufferText

        if stateMachine.phase == .buffering {
            refreshLiveCommitTargetAppPID()
        }

        stateMachine.updateBuffer(text: displayBufferText, anchor: nil)
        recordOverlayDisplayTextChangeIfNeeded(
            previousOverlayDisplayText: previousOverlayDisplayText,
            newOverlayDisplayText: stateMachine.bufferText
        )
        self.commitBufferText = commitBufferText
        renderCurrentSnapshot()
        Log.overlay.debug("overlay buffer refreshed")
    }

    @discardableResult
    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting,
        autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome {
        let commitText = OverlayBufferTextAssembler.insertionText(from: commitBufferText)
        guard !commitText.isEmpty else {
            Log.overlay.info("overlay commit skipped (empty buffer)")
            return .succeeded
        }

        // Re-check Secure Keyboard Entry AT COMMIT TIME (the session-start
        // sample can be stale in both directions — a password prompt may have
        // appeared or been dismissed while dictating). When it is active,
        // synthetic insertion would be swallowed while REPORTING success
        // (posting succeeds, delivery doesn't), the overlay would dismiss
        // happily, and the words would be gone. Skip the doomed attempts,
        // put the text on the clipboard unconditionally — losing it is the
        // only alternative — and show the failure state.
        if TerminalTargetDetector.isSecureKeyboardEntryEnabled() {
            // The clipboard is the ONLY preservation path here: if the write
            // fails, claiming "copied" and dismissing the panel would lose
            // the transcript's last remaining copy — fall back to the
            // persistent failure panel, which keeps the text visible.
            guard copyToPasteboard(commitText) else {
                let failureMessage =
                    "Secure input blocked auto-paste and the clipboard copy failed — the text stays visible here."
                stateMachine.commitFailed(
                    error: failureMessage,
                    anchor: anchorResolver.resolveAnchor()
                )
                renderCurrentSnapshot()
                Log.overlay.error("overlay commit skipped: secure input active AND clipboard write failed")
                return .failed(message: failureMessage)
            }
            let fallbackMessage = "Secure input blocked auto-paste — text copied, paste it manually."
            stateMachine.commitFailed(
                error: fallbackMessage,
                anchor: anchorResolver.resolveAnchor()
            )
            renderCurrentSnapshot()
            // The message is a fresh display change: anchor the dismiss hold
            // to it so the stop flow's dismissAfterHold keeps it readable
            // instead of measuring from the last buffered word.
            lastOverlayDisplayTextChangeAt = now()
            Log.overlay.notice("overlay commit skipped: Secure Keyboard Entry active; text copied to clipboard")
            return .copiedToClipboard(message: fallbackMessage)
        }

        let preferredPID = finalizationCommitTargetAppPID ?? liveCommitTargetAppPID
        // Keep overlay commit aligned with live auto-paste behavior: try keyboard
        // Unicode insertion first for web field compatibility, then AX, then Cmd+V.
        let primaryResult = textCommitter.insertTextPrioritizingKeyboard(
            commitText,
            preferredAppPID: preferredPID
        )
        let inserted =
            primaryResult.isSuccess
            || textCommitter.pasteUsingCommandV(
                commitText,
                preferredAppPID: preferredPID
            )

        if inserted {
            if autoCopyEnabled {
                _ = copyToPasteboard(commitText)
            }
            Log.overlay.info("overlay commit succeeded")
            return .succeeded
        }

        let failureMessage: String
        if textCommitter.isAccessibilityTrusted {
            failureMessage = "Unable to insert buffered text into the focused app."
        } else {
            failureMessage = TextInsertionService.accessibilityErrorMessage
        }

        if autoCopyEnabled {
            _ = copyToPasteboard(commitText)
        }

        stateMachine.commitFailed(
            error: failureMessage,
            anchor: anchorResolver.resolveAnchor()
        )
        renderCurrentSnapshot()
        Log.overlay.info("overlay commit failed: \(failureMessage, privacy: .public)")
        return .failed(message: failureMessage)
    }

    func showSecureInputWarning() {
        stateMachine.setSecureInputWarning()
        renderCurrentSnapshot()
    }

    func markPolished(_ polished: Bool) {
        stateMachine.setPolished(polished)
        renderCurrentSnapshot()
    }

    func dismissAfterHold(minimumVisibility: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = nil

        let holdRemaining: TimeInterval
        if let lastUpdate = lastOverlayDisplayTextChangeAt {
            let elapsed = now().timeIntervalSince(lastUpdate)
            holdRemaining = max(0, minimumVisibility - elapsed)
        } else {
            holdRemaining = 0
        }

        guard holdRemaining > 0 else {
            reset()
            return
        }

        Log.overlay.info("holding overlay \(String(format: "%.2f", holdRemaining))s before dismiss")
        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleepFor(.seconds(holdRemaining))
            guard !Task.isCancelled else { return }
            self.dismissTask = nil
            Log.overlay.info("overlay hold elapsed, dismissing")
            self.reset()
        }
    }

    func reset() {
        dismissTask?.cancel()
        dismissTask = nil
        lastOverlayDisplayTextChangeAt = nil
        stateMachine.reset()
        commitBufferText = ""
        liveCommitTargetAppPID = nil
        finalizationCommitTargetAppPID = nil
        renderer.hide()
        Log.overlay.info("overlay session reset")
    }

    var commitTargetAppPID: pid_t? {
        finalizationCommitTargetAppPID ?? liveCommitTargetAppPID
    }

    func captureLiveCommitTargetAppPID() {
        refreshLiveCommitTargetAppPID()
    }

    private func renderCurrentSnapshot() {
        renderer.render(snapshot: stateMachine.snapshot)
    }

    private func recordOverlayDisplayTextChangeIfNeeded(
        previousOverlayDisplayText: String,
        newOverlayDisplayText: String
    ) {
        guard previousOverlayDisplayText != newOverlayDisplayText else { return }
        lastOverlayDisplayTextChangeAt = now()
    }

    private func lockCommitTargetForFinalizationIfNeeded() {
        guard finalizationCommitTargetAppPID == nil else { return }
        refreshLiveCommitTargetAppPID()
        finalizationCommitTargetAppPID = liveCommitTargetAppPID
    }

    private func refreshLiveCommitTargetAppPID() {
        // anchorResolver.resolveFrontmostAppPID() already excludes our own PID.
        if let focusedPID = anchorResolver.resolveFrontmostAppPID() {
            liveCommitTargetAppPID = focusedPID
            return
        }

        // Preserve the last non-self PID when AX focus is temporarily unavailable.
        // This avoids replacing a good target with transient frontmost values.
        if liveCommitTargetAppPID == nil {
            if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               frontmostPID != getpid()
            {
                liveCommitTargetAppPID = frontmostPID
                return
            }
        }
    }

}

#if DEBUG
extension OverlayBufferSessionCoordinator {
    /// Exposes the pending hold task so tests can await dismissal deterministically
    /// instead of polling wall-clock time.
    var debugDismissTask: Task<Void, Never>? { dismissTask }
}
#endif
