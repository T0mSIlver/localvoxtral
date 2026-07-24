import AppKit
import ApplicationServices
import Carbon

/// Decides whether the focused dictation target behaves like a terminal
/// emulator. Terminals accept synthetic keyboard events but reject AX value
/// writes, and their AX "caret" (when readable at all) is a screen-grid
/// cursor whose position never matches text-field caret arithmetic — so the
/// live replacement strategy (and future per-app behaviors) key off this
/// verdict, computed once per dictation session at session start.
@MainActor
enum TerminalTargetDetector {
    /// Why the verdict was reached; logged at session start.
    enum Reason: String, Sendable {
        /// The frontmost app's bundle ID is on the built-in terminal allowlist.
        case bundleMatch = "bundle-match"
        /// The frontmost app's bundle ID is in the user's terminal_apps.toml
        /// list (apps that embed a terminal the built-in detection misses).
        case userBundleMatch = "user-bundle-match"
        /// Unknown bundle, Accessibility trust present, and confirmed that
        /// nothing has AX focus.
        case axProbeNoFocusedElement = "ax-probe-no-focus"
        /// Unknown bundle and the focused element's kAXValueAttribute is
        /// confirmed not settable — behaves like a terminal grid, not a
        /// text field.
        case axProbeValueNotSettable = "ax-probe-unsettable"
        /// Unknown bundle but the focused element accepts AX value writes —
        /// an ordinary text field.
        case axProbeValueSettable = "ax-probe-writable"
        /// Unknown bundle and the probe could not tell: Accessibility trust
        /// missing, or a transient AX error (.cannotComplete, .apiDisabled,
        /// ...). Distinct from "confirmed writable" so field logs show the
        /// difference.
        case axProbeUnavailable = "ax-probe-unavailable"
    }

    struct Decision: Equatable, Sendable {
        let isTerminalLike: Bool
        let reason: Reason
    }

    /// Result of probing the focused AX element for kAXValueAttribute
    /// settability. Injectable in DEBUG so decision logic is testable
    /// without live AX.
    enum FocusedElementProbe: Equatable, Sendable {
        /// Trusted and confirmed: nothing has AX focus.
        case noFocusedElement
        /// Confirmed (status == .success): the value attribute is read-only.
        case valueNotSettable
        /// Confirmed (status == .success): the value attribute is writable.
        case valueSettable
        /// The probe could not tell — Accessibility trust missing or a
        /// transient AX failure. Never treated as terminal-like: a false
        /// negative is mild (callers have independent fallbacks), a false
        /// positive would change behavior in ordinary apps on AX flakiness.
        case probeUnavailable
    }

    /// Exact bundle IDs of known terminal emulators (verified against each
    /// app's shipped Info.plist / build config). VS Code and Cursor are
    /// deliberately absent: their editor surfaces are AX-writable, and their
    /// integrated terminals are left to the AX heuristic.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",       // Terminal.app
        "com.googlecode.iterm2",    // iTerm2
        "com.mitchellh.ghostty",    // Ghostty
        "com.github.wez.wezterm",   // WezTerm
        "net.kovidgoyal.kitty",     // kitty
        "org.alacritty",            // Alacritty
        "co.zeit.hyper",            // Hyper
        "org.tabby",                // Tabby (electron-builder appId)
        "com.raphaelamorim.rio",    // Rio (misc/osx Info.plist)
        "com.cmuxterm.app",         // cmux (field-verified bundle id, 2026-07-07;
                                    // its AX value reads writable, so the probe
                                    // can never identify it — allowlist or bust)
    ]

    /// Prefix matches for apps that ship channel-suffixed bundle IDs.
    /// Warp uses dev.warp.Warp-Stable / -Preview / -Dev per release channel.
    private static let terminalBundleIDPrefixes: [String] = [
        "dev.warp.Warp",
    ]

    /// Pure allowlist check: exact match first, then known channel prefixes.
    static func isTerminalLikeBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if terminalBundleIDs.contains(bundleID) { return true }
        return terminalBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Core decision: built-in allowlist first, then the user's
    /// terminal_apps.toml bundle IDs; for unknown bundles fall back to the
    /// AX probe — a confirmed-missing focused element or a confirmed
    /// unsettable value attribute read as terminal-like, while an
    /// inconclusive probe does not. The probe closure is only invoked when
    /// the bundle is unknown to both lists.
    static func decision(
        forBundleID bundleID: String?,
        userBundleIDs: Set<String> = [],
        focusedElementProbe: () -> FocusedElementProbe
    ) -> Decision {
        if isTerminalLikeBundleID(bundleID) {
            return Decision(isTerminalLike: true, reason: .bundleMatch)
        }
        if let bundleID, userBundleIDs.contains(bundleID) {
            return Decision(isTerminalLike: true, reason: .userBundleMatch)
        }
        switch focusedElementProbe() {
        case .noFocusedElement:
            return Decision(isTerminalLike: true, reason: .axProbeNoFocusedElement)
        case .valueNotSettable:
            return Decision(isTerminalLike: true, reason: .axProbeValueNotSettable)
        case .valueSettable:
            return Decision(isTerminalLike: false, reason: .axProbeValueSettable)
        case .probeUnavailable:
            return Decision(isTerminalLike: false, reason: .axProbeUnavailable)
        }
    }

    /// Live verdict for the app focused right now, logged loudly (one line
    /// per session start) so field logs always show what the session decided
    /// and why.
    static func detectCurrentTarget(userBundleIDs: Set<String> = []) -> Decision {
        let bundleID = currentFrontmostBundleID()
        let verdict = decision(forBundleID: bundleID, userBundleIDs: userBundleIDs) {
            probeFocusedElementLive()
        }
        Log.target.notice(
            "Session target verdict: terminalLike=\(verdict.isTerminalLike, privacy: .public) reason=\(verdict.reason.rawValue, privacy: .public) bundle=\(bundleID ?? "<none>", privacy: .public)"
        )
        return verdict
    }

    /// True when macOS Secure Keyboard Entry is active (e.g. Ghostty around
    /// password prompts, or enabled manually in Terminal.app/iTerm2). It
    /// blocks synthetic keyboard events, so dictated text silently lands
    /// nowhere — callers warn, never block.
    static func isSecureKeyboardEntryEnabled() -> Bool {
        #if DEBUG
        if let override = debugSecureEventInputOverride {
            return override()
        }
        if isRunningUnderXCTest { return false }
        #endif
        return IsSecureEventInputEnabled()
    }

    private static func currentFrontmostBundleID() -> String? {
        #if DEBUG
        if let override = debugFrontmostBundleIDOverride {
            return override()
        }
        if isRunningUnderXCTest { return nil }
        #endif
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Reads AX focus directly (not via `SystemAccessibilityFocus`, which
    /// discards the AXError) because the decision must distinguish
    /// "confirmed nothing focused" from "the read itself failed".
    private static func probeFocusedElementLive() -> FocusedElementProbe {
        #if DEBUG
        if let override = debugFocusedElementProbeOverride {
            return override()
        }
        if isRunningUnderXCTest { return .probeUnavailable }
        #endif
        // Without Accessibility trust every AX read fails; that says nothing
        // about the target.
        guard AXIsProcessTrusted() else { return .probeUnavailable }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        switch focusStatus {
        case .success:
            break
        case .noValue:
            // Trusted and confirmed: nothing has AX focus.
            return .noFocusedElement
        default:
            // Transient AX failure (.cannotComplete, .apiDisabled, ...).
            return .probeUnavailable
        }
        guard let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID()
        else {
            return .noFocusedElement
        }

        let element = unsafeDowncast(focusedObject, to: AXUIElement.self)
        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        guard settableStatus == .success else { return .probeUnavailable }
        return settable.boolValue ? .valueSettable : .valueNotSettable
    }

    #if DEBUG
    // Test seams: the live AX/NSWorkspace/Carbon reads are not exercisable
    // from unit tests (mirrors the debugConfigureInsertionHooks pattern).
    static var debugFrontmostBundleIDOverride: (() -> String?)?
    static var debugFocusedElementProbeOverride: (() -> FocusedElementProbe)?
    static var debugSecureEventInputOverride: (() -> Bool)?

    // When XCTest is in the process and a test did not pin an override, the
    // live reads above return whatever the HOST happens to be doing — and
    // loginwindow holds Secure Keyboard Entry the entire time the screen is
    // locked, so every unpinned test on a commit/session-start path failed
    // whenever CI ran unattended (runs 29160724070, 29159948228/455/578).
    // The frontmost-app and AX-focus reads flake the same way (a terminal
    // frontmost while the suite runs flips the session verdict), so all
    // three seams resolve to fixed defaults under XCTest: secure input off,
    // no frontmost bundle, probe unavailable. Tests that exercise the live
    // behaviors pin the overrides explicitly.
    // nonisolated: consulted from nonisolated pinned defaults too
    // (AccessibilityTrustManager) — an immutable Bool is safe anywhere.
    nonisolated static let isRunningUnderXCTest = NSClassFromString("XCTestCase") != nil
    #endif
}
