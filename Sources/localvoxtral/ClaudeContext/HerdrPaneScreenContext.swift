import Foundation

/// A start-of-dictation sample of the JOINED herdr pane's visible text,
/// fetched over herdr's JSON socket (`pane.read`) instead of AX.
///
/// For a herdr-hosted session the AX capture is the composite herdr TUI —
/// neighboring panes and all — which is why the join authorizer refuses to
/// render it. This capture is the pane-exact replacement: the same screen
/// question, answered by the one process that can scope it to the joined pane.
struct HerdrPaneScreenCapture: Sendable, Equatable {
    /// Sanitized, capped pane text — the SAME pipeline as an AX screen read
    /// (`TerminalScreenAXReader.sanitizedScreenText`), so start/stop compares
    /// and the excerpt bytes follow identical rules on both transports.
    let text: String
    /// The pane the text came from. Always the join's pane by construction
    /// (the fetch is keyed by the join's binding); retained so the stop path
    /// can PROVE it is reconciling the same pane rather than assume it.
    let paneID: String
}

/// Live plumbing for herdr pane screen context, mirroring
/// `TerminalScreenContextSource`: capture at dictation start, reconcile at
/// stop, with every decision delegated to the shared pure truth table
/// (`TerminalScreenContext.reconcile`) and every live value injected by the
/// caller so the whole flow is unit-testable.
///
/// Invariants (AGENTS "Known tradeoffs", herdr bullet):
/// - `pane.read` fires ONLY downstream of a resolved `.herdrPane` join, and
///   only for that join's pane — both functions refuse anything else, and the
///   resolver's `herdrPaneVisibleText(for:)` re-checks the same thing.
/// - The composite AX capture still never renders for herdr joins (the join
///   authorizer's refusal is untouched); this text REPLACES it for both vocab
///   grounding and — when the join is still live — the rendered excerpt.
/// - Every failure is loud and falls back to exactly the pre-pane.read
///   behavior: the composite AX decision, which for a herdr join is
///   vocabulary-only at best. Fail closed on attachment, never on grounding.
@MainActor
enum HerdrPaneScreenContext {
    /// Start-of-dictation pane sample. Returns nil — having issued NO socket
    /// request — unless `join` is a herdr pane join AND the full screen-context
    /// consent gate clears (same gate as the AX read: setting, permitted
    /// endpoint, allowlisted app, Accessibility trust). Pane text is screen
    /// text; it does not get a weaker gate for arriving over a socket.
    static func captureAtStart(
        join: ClaudeSessionJoin?,
        resolver: ClaudeSessionJoinResolver?,
        settingEnabled: Bool,
        endpointURL: URL,
        isAccessibilityTrusted: Bool,
        trustedEndpointEnabled: Bool
    ) async -> HerdrPaneScreenCapture? {
        guard let join, join.mechanism == .herdrPane, let binding = join.herdrPane else {
            return nil
        }
        guard TerminalScreenContext.shouldAttemptRead(
            settingEnabled: settingEnabled,
            endpointURL: endpointURL,
            bundleID: join.target.bundleID,
            isAccessibilityTrusted: isAccessibilityTrusted,
            trustedEndpointEnabled: trustedEndpointEnabled
        ) else {
            return nil
        }
        guard let resolver else {
            Log.claudeContext.info("Herdr pane screen capture skipped: no join resolver")
            return nil
        }
        guard let raw = await resolver.herdrPaneVisibleText(for: join),
              let text = TerminalScreenAXReader.sanitizedScreenText(raw)
        else {
            // Loud by convention: from here the session behaves exactly as
            // before pane.read existed — composite AX text, vocabulary-only.
            Log.claudeContext.info(
                "Herdr pane screen capture failed at start; composite AX text stays vocabulary-only"
            )
            return nil
        }
        // Count-only: pane text is user content and never reaches a log.
        Log.claudeContext.info(
            "Herdr pane screen context captured at start: \(text.count, privacy: .public)ch"
        )
        return HerdrPaneScreenCapture(text: text, paneID: binding.paneID)
    }

    /// Stop-time reconciliation. Re-reads EXACTLY the joined pane, compares
    /// against the start sample under the shared truth table, and returns the
    /// decision that REPLACES the composite-AX one for this dictation.
    ///
    /// `fallback` is the AX-based decision the commit path already computed —
    /// for a herdr join that is vocabulary-only at best, because the join
    /// authorizer refuses composite raw attachment. It is returned unchanged
    /// whenever this path cannot positively do better: no start sample, a
    /// non-herdr join, a failed or garbage stop read. Consent withdrawal
    /// (`shouldAttemptRead` now false) destroys the pane text instead — a
    /// revoked permission must never degrade into "use the old text anyway".
    ///
    /// Attachment is authorized by the join still being live — the pane text
    /// is pane-exact by construction, so liveness is the only question left,
    /// exactly the final check the AX authorizer runs. A dead session keeps
    /// grounding (the user saw this text while speaking) but renders nothing.
    static func reconcileAtStop(
        start: HerdrPaneScreenCapture?,
        join: ClaudeSessionJoin?,
        resolver: ClaudeSessionJoinResolver?,
        fallback: TerminalScreenContextDecision,
        settingEnabled: Bool,
        endpointURL: URL,
        isAccessibilityTrusted: Bool,
        trustedEndpointEnabled: Bool
    ) async -> TerminalScreenContextDecision {
        guard let start else { return fallback }
        guard let join, join.mechanism == .herdrPane,
              let binding = join.herdrPane, binding.paneID == start.paneID
        else {
            // A start sample without a matching herdr join to reconcile it
            // against cannot claim anything about the screen at stop.
            Log.claudeContext.info(
                "Herdr pane screen context discarded: no matching herdr join at stop"
            )
            return fallback
        }
        guard TerminalScreenContext.shouldAttemptRead(
            settingEnabled: settingEnabled,
            endpointURL: endpointURL,
            bundleID: join.target.bundleID,
            isAccessibilityTrusted: isAccessibilityTrusted,
            trustedEndpointEnabled: trustedEndpointEnabled
        ) else {
            // Consent withdrawn mid-session. The AX reconcile computed the
            // same rejection from the same gate, so `fallback` is normally
            // already a drop — but never assume: pane text captured under the
            // old consent must not survive as grounding either way.
            Log.claudeContext.info(
                "Herdr pane screen context discarded: policy rejected at stop"
            )
            if case .drop = fallback { return fallback }
            return .drop(reason: .policyRejected)
        }
        guard let resolver else {
            Log.claudeContext.info("Herdr pane screen context discarded: no join resolver at stop")
            return fallback
        }
        guard let raw = await resolver.herdrPaneVisibleText(for: join),
              let stopText = TerminalScreenAXReader.sanitizedScreenText(raw)
        else {
            Log.claudeContext.info(
                "Herdr pane stop re-read failed; screen context falls back to the composite-AX decision"
            )
            return fallback
        }
        let decision = TerminalScreenContext.reconcile(
            start: TerminalScreenCapture(text: start.text, target: join.target),
            stop: .read(stopText),
            rawAuthorized: resolver.isStillLive(join)
        )
        Log.claudeContext.info(
            "Herdr pane screen context reconciled: \(decision.provenanceSummary, privacy: .public)"
        )
        return decision
    }
}
