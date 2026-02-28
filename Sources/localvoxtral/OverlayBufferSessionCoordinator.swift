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

    func insertTextUsingAccessibilityOnly(_ text: String, preferredAppPID: pid_t?) -> Bool
    func pasteUsingCommandV(_ text: String, preferredAppPID: pid_t?) -> Bool
}

extension TextInsertionService: OverlayTextCommitting {}

enum OverlayBufferCommitOutcome: Equatable {
    case succeeded
    case failed(message: String)
}

@MainActor
protocol OverlayBufferSessionCoordinating: AnyObject {
    func resolveAnchorNow() -> OverlayAnchor
    func startSession(preResolvedAnchor: OverlayAnchor?)
    func beginFinalizing(displayBufferText: String, commitBufferText: String)
    func refresh(displayBufferText: String, commitBufferText: String)
    @discardableResult
    func commitIfNeeded(using textCommitter: OverlayTextCommitting, autoCopyEnabled: Bool) -> OverlayBufferCommitOutcome
    func reset()
}

@MainActor
final class OverlayBufferSessionCoordinator: OverlayBufferSessionCoordinating {
    private var stateMachine: OverlayBufferStateMachine
    private let renderer: OverlayBufferRendering
    private let anchorResolver: OverlayAnchorResolving

    private var commitBufferText = ""
    private var liveCommitTargetAppPID: pid_t?
    private var finalizationCommitTargetAppPID: pid_t?

    init(
        stateMachine: OverlayBufferStateMachine,
        renderer: OverlayBufferRendering,
        anchorResolver: OverlayAnchorResolving
    ) {
        self.stateMachine = stateMachine
        self.renderer = renderer
        self.anchorResolver = anchorResolver
    }

    func resolveAnchorNow() -> OverlayAnchor {
        anchorResolver.resolveAnchor()
    }

    func startSession(preResolvedAnchor: OverlayAnchor? = nil) {
        commitBufferText = ""
        finalizationCommitTargetAppPID = nil
        refreshLiveCommitTargetAppPID()

        let anchor = preResolvedAnchor ?? anchorResolver.resolveAnchor()
        stateMachine.startSession(anchor: anchor)
        renderCurrentSnapshot()
        Log.overlay.info("overlay session started (preResolved=\(preResolvedAnchor != nil, privacy: .public))")
    }

    func beginFinalizing(displayBufferText: String, commitBufferText: String) {
        lockCommitTargetForFinalizationIfNeeded()
        let anchor = anchorResolver.resolveAnchor()

        stateMachine.beginFinalizing(anchor: anchor)
        stateMachine.updateBuffer(text: displayBufferText, anchor: anchor)
        self.commitBufferText = commitBufferText
        renderCurrentSnapshot()
        Log.overlay.info("overlay begin finalizing")
    }

    func refresh(displayBufferText: String, commitBufferText: String) {
        guard stateMachine.phase == .buffering || stateMachine.phase == .finalizing else { return }

        if stateMachine.phase == .buffering {
            refreshLiveCommitTargetAppPID()
        }

        stateMachine.updateBuffer(text: displayBufferText, anchor: nil)
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
            stateMachine.commitSucceeded()
            renderCurrentSnapshot()
            Log.overlay.info("overlay commit skipped (empty buffer)")
            return .succeeded
        }

        let preferredPID = finalizationCommitTargetAppPID ?? liveCommitTargetAppPID
        let inserted =
            textCommitter.insertTextUsingAccessibilityOnly(
                commitText,
                preferredAppPID: preferredPID
            )
            || textCommitter.pasteUsingCommandV(
                commitText,
                preferredAppPID: preferredPID
            )

        if inserted {
            if autoCopyEnabled {
                copyToPasteboard(commitText)
            }
            stateMachine.commitSucceeded()
            renderCurrentSnapshot()
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
            copyToPasteboard(commitText)
        }

        stateMachine.commitFailed(
            error: failureMessage,
            anchor: anchorResolver.resolveAnchor()
        )
        renderCurrentSnapshot()
        Log.overlay.info("overlay commit failed: \(failureMessage, privacy: .public)")
        return .failed(message: failureMessage)
    }

    func reset() {
        stateMachine.reset()
        commitBufferText = ""
        liveCommitTargetAppPID = nil
        finalizationCommitTargetAppPID = nil
        renderer.hide()
        Log.overlay.info("overlay session reset")
    }

    private func renderCurrentSnapshot() {
        renderer.render(snapshot: stateMachine.snapshot)
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

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
