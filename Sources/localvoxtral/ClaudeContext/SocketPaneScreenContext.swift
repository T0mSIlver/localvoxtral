import Foundation

/// A start-of-dictation sample of the JOINED pane's visible text, fetched over
/// the hosting multiplexer's own control socket instead of AX.
///
/// Two joins land here, for two different reasons that reach the same answer:
///
/// * **herdr** — the AX capture is the composite herdr TUI, neighboring panes
///   and all, which is why the join authorizer refuses to render it.
/// * **cmux** — there is no AX capture at all: cmux draws with libghostty into
///   a custom view that exposes no text area, and it has no scripting
///   dictionary either. The socket is the only route to the text.
///
/// Either way this is the pane-exact replacement: the same screen question,
/// answered by the one process that can scope it to the joined pane.
struct SocketPaneScreenCapture: Sendable, Equatable {
    /// Sanitized, capped pane text — the SAME pipeline as an AX screen read
    /// (`TerminalScreenAXReader.sanitizedScreenText`), so start/stop compares
    /// and the excerpt bytes follow identical rules on every transport.
    let text: String
    /// The pane the text came from: a herdr pane id or a cmux surface id.
    /// Always the join's own by construction (the fetch is keyed by the join's
    /// binding); retained so the stop path can PROVE it is reconciling the same
    /// pane rather than assume it.
    let paneKey: String
}

/// Live plumbing for socket-routed pane screen context, mirroring
/// `TerminalScreenContextSource`: capture at dictation start, reconcile at
/// stop, with every decision delegated to the shared pure truth table
/// (`TerminalScreenContext.reconcile`) and every live value injected by the
/// caller so the whole flow is unit-testable.
///
/// Invariants (AGENTS "Known tradeoffs", herdr and cmux bullets):
/// - A pane read fires ONLY downstream of a resolved `.herdrPane`/`.cmuxSurface`
///   join, and only for that join's pane — both functions refuse anything else,
///   and the resolver's `herdrPaneVisibleText(for:)` /
///   `cmuxSurfaceVisibleText(for:)` re-check the same thing.
/// - Raw AX attachment still never happens for either join (the join
///   authorizer's refusal is untouched); this text REPLACES it for both vocab
///   grounding and — when the join is still live — the rendered excerpt.
/// - Every failure is loud and falls back to exactly the pre-socket behavior:
///   the AX decision, which for these joins is vocabulary-only at best (and for
///   cmux nothing at all, since AX reads no text there). Fail closed on
///   attachment, never on grounding.
@MainActor
enum SocketPaneScreenContext {
    /// Start-of-dictation pane sample. Returns nil — having issued NO socket
    /// request — unless `join` is a socket-routed pane join AND the full
    /// screen-context consent gate clears (same gate as the AX read: setting,
    /// permitted endpoint, allowlisted app, Accessibility trust). Pane text is
    /// screen text; it does not get a weaker gate for arriving over a socket.
    static func captureAtStart(
        join: ClaudeSessionJoin?,
        resolver: ClaudeSessionJoinResolver?,
        settingEnabled: Bool,
        endpointURL: URL,
        isAccessibilityTrusted: Bool,
        trustedEndpointEnabled: Bool
    ) async -> SocketPaneScreenCapture? {
        guard let join, let paneKey = join.socketPaneKey else { return nil }
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
            Log.claudeContext.info("Socket pane screen capture skipped: no join resolver")
            return nil
        }
        guard let raw = await paneText(join: join, resolver: resolver),
              let text = TerminalScreenAXReader.sanitizedScreenText(raw)
        else {
            // Loud by convention: from here the session behaves exactly as
            // before the socket read existed — AX text, vocabulary-only.
            Log.claudeContext.info(
                "Socket pane screen capture failed at start; AX text stays vocabulary-only"
            )
            return nil
        }
        // Count-only: pane text is user content and never reaches a log.
        Log.claudeContext.info(
            "Socket pane screen context captured at start: \(text.count, privacy: .public)ch"
        )
        return SocketPaneScreenCapture(text: text, paneKey: paneKey)
    }

    /// Stop-time reconciliation. Re-reads EXACTLY the joined pane, compares
    /// against the start sample under the shared truth table, and returns the
    /// decision that REPLACES the AX one for this dictation.
    ///
    /// `fallback` is the AX-based decision the commit path already computed —
    /// for these joins that is vocabulary-only at best, because the join
    /// authorizer refuses raw attachment. It is returned unchanged whenever this
    /// path cannot positively do better: no start sample, a different or absent
    /// pane join, a failed or garbage stop read. Consent withdrawal
    /// (`shouldAttemptRead` now false) destroys the pane text instead — a
    /// revoked permission must never degrade into "use the old text anyway".
    ///
    /// Attachment is authorized by the join still being live — the pane text is
    /// pane-exact by construction, so liveness is the only question left,
    /// exactly the final check the AX authorizer runs. A dead session keeps
    /// grounding (the user saw this text while speaking) but renders nothing.
    static func reconcileAtStop(
        start: SocketPaneScreenCapture?,
        join: ClaudeSessionJoin?,
        resolver: ClaudeSessionJoinResolver?,
        fallback: TerminalScreenContextDecision,
        settingEnabled: Bool,
        endpointURL: URL,
        isAccessibilityTrusted: Bool,
        trustedEndpointEnabled: Bool
    ) async -> TerminalScreenContextDecision {
        guard let start else { return fallback }
        guard let join, let paneKey = join.socketPaneKey, paneKey == start.paneKey else {
            // A start sample without a matching pane join to reconcile it
            // against cannot claim anything about the screen at stop.
            Log.claudeContext.info(
                "Socket pane screen context discarded: no matching pane join at stop"
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
            // Consent withdrawn mid-session. The AX reconcile computed the same
            // rejection from the same gate, so `fallback` is normally already a
            // drop — but never assume: pane text captured under the old consent
            // must not survive as grounding either way.
            Log.claudeContext.info(
                "Socket pane screen context discarded: policy rejected at stop"
            )
            if case .drop = fallback { return fallback }
            return .drop(reason: .policyRejected)
        }
        guard let resolver else {
            Log.claudeContext.info("Socket pane screen context discarded: no join resolver at stop")
            return fallback
        }
        guard let raw = await paneText(join: join, resolver: resolver),
              let stopText = TerminalScreenAXReader.sanitizedScreenText(raw)
        else {
            Log.claudeContext.info(
                "Socket pane stop re-read failed; screen context falls back to the AX decision"
            )
            return fallback
        }
        let decision = TerminalScreenContext.reconcile(
            start: TerminalScreenCapture(text: start.text, target: join.target),
            stop: .read(stopText),
            rawAuthorized: resolver.isStillLive(join)
        )
        Log.claudeContext.info(
            "Socket pane screen context reconciled: \(decision.provenanceSummary, privacy: .public)"
        )
        return decision
    }

    /// Routes to the one client that can answer for this join's mechanism. The
    /// resolver's per-mechanism functions re-check the binding themselves, so a
    /// wrong route here cannot read another pane — it reads nothing.
    private static func paneText(
        join: ClaudeSessionJoin,
        resolver: ClaudeSessionJoinResolver
    ) async -> String? {
        switch join.mechanism {
        case .herdrPane, .remoteHerdrPane:
            // One route for both herdr arms: a remote herdr differs only in
            // WHERE its socket is — the local end of an app-managed `ssh -L`,
            // captured in the same binding — so the request, the sanitizing and
            // the caps are identical.
            return await resolver.herdrPaneVisibleText(for: join)
        case .cmuxSurface:
            return await resolver.cmuxSurfaceVisibleText(for: join)
        case .ttyDevice, .titleMarker, .browserTab:
            // A browser tab has no pane socket to read, and no verified screen
            // route of any kind — its join buys session/repository context only.
            return nil
        }
    }
}
