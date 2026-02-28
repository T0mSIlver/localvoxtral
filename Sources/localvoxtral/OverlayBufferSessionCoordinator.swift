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

@MainActor
final class OverlayBufferSessionCoordinator {
    enum CommitOutcome: Equatable {
        case succeeded
        case failed(message: String)
    }

    private var stateMachine: OverlayBufferStateMachine
    private let renderer: OverlayBufferRendering
    private let anchorResolver: OverlayAnchorResolving

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
        finalizationCommitTargetAppPID = nil
        refreshLiveCommitTargetAppPID()

        let anchor = preResolvedAnchor ?? anchorResolver.resolveAnchor()
        stateMachine.startSession(anchor: anchor)
        stateMachine.updateBuffer(text: "", anchor: anchor)
        renderCurrentSnapshot()
        Log.overlay.info("overlay session started (preResolved=\(preResolvedAnchor != nil, privacy: .public))")
    }

    func beginFinalizing(bufferText: String) {
        lockCommitTargetForFinalizationIfNeeded()
        let anchor = anchorResolver.resolveAnchor()

        stateMachine.beginFinalizing(anchor: anchor)
        stateMachine.updateBuffer(text: bufferText, anchor: anchor)
        renderCurrentSnapshot()
        Log.overlay.info("overlay begin finalizing")
    }

    func refresh(bufferText: String) {
        guard stateMachine.phase == .buffering || stateMachine.phase == .finalizing else { return }

        if stateMachine.phase == .buffering {
            refreshLiveCommitTargetAppPID()
        }

        stateMachine.updateBuffer(text: bufferText, anchor: nil)
        renderCurrentSnapshot()
        Log.overlay.debug("overlay buffer refreshed")
    }

    @discardableResult
    func commitIfNeeded(using textCommitter: OverlayTextCommitting, autoCopyEnabled: Bool) -> CommitOutcome {
        let commitText = OverlayBufferTextAssembler.insertionText(from: stateMachine.bufferText)
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
        if let focusedPID = anchorResolver.resolveFrontmostAppPID(),
           focusedPID != getpid()
        {
            liveCommitTargetAppPID = focusedPID
            return
        }

        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPID != getpid()
        {
            liveCommitTargetAppPID = frontmostPID
            return
        }

        liveCommitTargetAppPID = nil
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
