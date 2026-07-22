import AppKit
import Foundation

/// Live plumbing for terminal screen context: resolves the target app and
/// drives the gated AX reads. All decisions live in `TerminalScreenContext`
/// (pure); this type only supplies the live values that feed them.
@MainActor
enum TerminalScreenContextSource {
    /// The frontmost application, excluding ourselves, as a value type.
    ///
    /// Resolved INDEPENDENTLY of the overlay's own target tracking (mirroring
    /// `OverlayAnchorResolver.resolveFrontmostAppPID`, including its `getpid()`
    /// exclusion) and called at session start, before the overlay can take
    /// focus. The overlay's `commitTargetAppPID` is not usable here: it is
    /// populated later in the session, and by stop time the frontmost app may
    /// be our own panel — a screen capture must be pinned to the app the user
    /// was actually looking at when they began speaking.
    static func frontmostTarget() -> TerminalScreenTarget? {
        #if DEBUG
        if let override = debugFrontmostTargetOverride {
            return override()
        }
        if TerminalTargetDetector.isRunningUnderXCTest { return nil }
        #endif
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(),
              let bundleID = app.bundleIdentifier
        else {
            return nil
        }
        return TerminalScreenTarget(pid: app.processIdentifier, bundleID: bundleID)
    }

    /// Re-resolves the target for a PID captured earlier, or nil when that PID
    /// no longer names a running app. The bundle ID is read fresh so the caller
    /// can detect a recycled PID.
    static func target(forPID pid: pid_t) -> TerminalScreenTarget? {
        #if DEBUG
        if let override = debugTargetForPIDOverride {
            return override(pid)
        }
        if TerminalTargetDetector.isRunningUnderXCTest { return nil }
        #endif
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier
        else {
            return nil
        }
        return TerminalScreenTarget(pid: pid, bundleID: bundleID)
    }

    /// One screen read, routed by capture route: Ghostty through the verified
    /// AX grid read, iTerm2/Terminal.app through the AppleScript focused
    /// session/tab contents read. The routes are EXCLUSIVE by construction —
    /// an AppleScript-captured terminal must never be read over AX (its tree
    /// is unverified, and iTerm2's would mix split panes into one read) — and
    /// a bundle on neither list reads nothing, as a second line behind the
    /// allowlist gate. Both routes return the same sanitized/capped form and
    /// window identity, so everything downstream (matching, start/stop
    /// comparison, budgeting, raw-attachment authorization) is
    /// route-agnostic.
    static func readVisibleScreen(
        target: TerminalScreenTarget
    ) -> TerminalScreenAXReader.VisibleScreenRead? {
        if TerminalScreenAllowlist.isAppleScriptCaptureSupported(target.bundleID) {
            return TerminalScreenAppleScriptReader.readVisibleScreen(target: target)
        }
        if TerminalScreenAllowlist.isAXCaptureSupported(target.bundleID) {
            return TerminalScreenAXReader.readVisibleScreen(applicationPID: target.pid)
        }
        return nil
    }

    /// Start-of-dictation capture. Resolves the frontmost non-self app, clears
    /// the full gate, and only then reads the screen. Returns nil (having made
    /// NO AX or AppleScript call) whenever the gate rejects.
    ///
    /// Call before the overlay changes focus — see `frontmostTarget()`.
    static func captureAtStart(
        settingEnabled: Bool,
        endpointURL: URL,
        isAccessibilityTrusted: Bool,
        trustedEndpointEnabled: Bool = false
    ) -> TerminalScreenCapture? {
        guard let target = frontmostTarget() else { return nil }
        guard TerminalScreenContext.shouldAttemptRead(
            settingEnabled: settingEnabled,
            endpointURL: endpointURL,
            bundleID: target.bundleID,
            isAccessibilityTrusted: isAccessibilityTrusted,
            trustedEndpointEnabled: trustedEndpointEnabled
        ) else {
            return nil
        }
        guard let read = readVisibleScreen(target: target) else {
            return nil
        }
        // Count-only: screen text is user content and never reaches a log.
        Log.target.info(
            "Terminal screen context captured at start: \(read.text.count, privacy: .public)ch"
        )
        return TerminalScreenCapture(text: read.text, target: target, windowID: read.windowID)
    }

    /// Stop-time reconciliation for a start capture. Re-reads ONLY the start
    /// capture's PID, and only while it still resolves to the same bundle ID —
    /// never the frontmost app, which may be our overlay by now.
    ///
    /// Returns `.drop(.noStartCapture)` when `start` is nil: a stop-time read
    /// with no start capture would be stop-only context, which is text the user
    /// could not have seen while speaking.
    static func reconcileAtStop(
        start: TerminalScreenCapture?,
        settingEnabled: Bool,
        endpointURL: URL,
        isAccessibilityTrusted: Bool,
        trustedEndpointEnabled: Bool = false
    ) -> TerminalScreenContextDecision {
        // ORDER IS LOAD-BEARING: sample first, authorize second.
        //
        // Asking the policy is not free and not passive — the broker-backed
        // authorizer makes a live AX round trip for the window title. So it must
        // sit BEHIND the same gate as every other read, and only `stopSample`
        // knows whether that gate still holds. Authorizing first would:
        //
        // - read a title after the user turned the setting off, repointed the
        //   endpoint no longer permitted, or revoked trust — i.e. after consent was
        //   withdrawn (`.policyRejected`);
        // - read the title of a RECYCLED PID's new owner (`.targetChanged`).
        //   The authorizer allowlist-checks the START capture's bundle ID, so a
        //   quit-and-relaunch that reused the pid would sail past it and the
        //   reader's own `elementPID == pid` check cannot help — the pid is the
        //   one that got recycled.
        //
        // Only `.read` — the gate holding, the target still ours, the screen
        // actually re-read — is worth asking about. Every other sample already
        // determines the decision without it.
        let sample = stopSample(
            start: start,
            settingEnabled: settingEnabled,
            endpointURL: endpointURL,
            isAccessibilityTrusted: isAccessibilityTrusted,
            trustedEndpointEnabled: trustedEndpointEnabled
        )
        // Asked about the START capture's target — the pane the user was
        // actually looking at while speaking — never the frontmost app, which by
        // commit time may be our own overlay.
        var rawAuthorized = false
        if case .read = sample, let start {
            rawAuthorized = TerminalScreenRawAttachmentPolicy.isAuthorized(
                target: start.target, windowID: start.windowID
            )
        }
        let decision = TerminalScreenContext.reconcile(
            start: start,
            stop: sample,
            rawAuthorized: rawAuthorized
        )
        Log.target.info(
            "Terminal screen context reconciled: \(decision.provenanceSummary, privacy: .public)"
        )
        return decision
    }

    /// Classifies the stop-time re-read, keeping a POLICY rejection distinct
    /// from an AX read failure — they authorize very different outcomes (see
    /// `TerminalScreenStopSample`), and only this function can tell them apart,
    /// because only it knows which of the two guards fired.
    private static func stopSample(
        start: TerminalScreenCapture?,
        settingEnabled: Bool,
        endpointURL: URL,
        isAccessibilityTrusted: Bool,
        trustedEndpointEnabled: Bool
    ) -> TerminalScreenStopSample {
        // Irrelevant when start is nil (reconcile drops first); keeps the
        // signature total.
        guard let start else { return .targetChanged }

        // Identity first: a stale PID must not even be gated, let alone read.
        guard let stopTarget = target(forPID: start.target.pid),
              stopTarget == start.target
        else {
            return .targetChanged
        }

        // Re-evaluate the FULL gate: the setting can be toggled off, the
        // endpoint repointed, and trust revoked mid-session. Any of those is a
        // withdrawal of consent, not a read failure.
        guard TerminalScreenContext.shouldAttemptRead(
            settingEnabled: settingEnabled,
            endpointURL: endpointURL,
            bundleID: stopTarget.bundleID,
            isAccessibilityTrusted: isAccessibilityTrusted,
            trustedEndpointEnabled: trustedEndpointEnabled
        ) else {
            return .policyRejected
        }

        guard let read = readVisibleScreen(target: stopTarget) else {
            return .readFailed
        }
        // The re-read must describe the WINDOW captured at start, not merely
        // the same app: two panes of one Ghostty can show byte-identical text
        // (both idle), and the text compare alone would then "confirm" a
        // screen nobody re-read (review F2). A definite mismatch is treated as
        // a failed confirmation — the start text stays valid for matching (the
        // user did see it while speaking), but nothing may claim it is still
        // on screen. Unknown identity on either side falls through: rendering
        // is separately refused at the authorization step, which requires two
        // established identities.
        if let startWindow = start.windowID, let stopWindow = read.windowID,
           startWindow != stopWindow {
            Log.target.info(
                "Terminal screen stop re-read landed on a different window of the target app; treating as a failed confirmation"
            )
            return .readFailed
        }
        return .read(read.text)
    }

    #if DEBUG
    /// Test seams. Live `NSWorkspace` reads return whatever the HOST is doing
    /// under XCTest (the flake class documented on
    /// `TerminalTargetDetector.isRunningUnderXCTest`), so both default to nil
    /// there and tests pin them explicitly.
    static var debugFrontmostTargetOverride: (() -> TerminalScreenTarget?)?
    static var debugTargetForPIDOverride: ((pid_t) -> TerminalScreenTarget?)?
    #endif
}
