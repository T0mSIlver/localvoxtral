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
        /// The frontmost app's bundle ID is on the terminal allowlist.
        case bundleMatch = "bundle-match"
        /// Unknown bundle and no focused AX element could be read.
        case axProbeNoFocusedElement = "ax-probe-no-focus"
        /// Unknown bundle and the focused element's kAXValueAttribute is not
        /// settable — behaves like a terminal grid, not a text field.
        case axProbeValueNotSettable = "ax-probe-unsettable"
        /// Unknown bundle but the focused element accepts AX value writes —
        /// an ordinary text field.
        case axProbeValueSettable = "ax-probe-writable"
    }

    struct Decision: Equatable, Sendable {
        let isTerminalLike: Bool
        let reason: Reason
    }

    /// Result of probing the focused AX element for kAXValueAttribute
    /// settability. Injectable in DEBUG so decision logic is testable
    /// without live AX.
    enum FocusedElementProbe: Equatable, Sendable {
        case noFocusedElement
        case valueNotSettable
        case valueSettable
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

    /// Core decision: allowlist first; for unknown bundles fall back to the
    /// AX probe — a missing focused element or an unsettable value attribute
    /// both read as terminal-like. The probe closure is only invoked when the
    /// bundle is unknown.
    static func decision(
        forBundleID bundleID: String?,
        focusedElementProbe: () -> FocusedElementProbe
    ) -> Decision {
        if isTerminalLikeBundleID(bundleID) {
            return Decision(isTerminalLike: true, reason: .bundleMatch)
        }
        switch focusedElementProbe() {
        case .noFocusedElement:
            return Decision(isTerminalLike: true, reason: .axProbeNoFocusedElement)
        case .valueNotSettable:
            return Decision(isTerminalLike: true, reason: .axProbeValueNotSettable)
        case .valueSettable:
            return Decision(isTerminalLike: false, reason: .axProbeValueSettable)
        }
    }

    /// Live verdict for the app focused right now, logged loudly (one line
    /// per session start) so field logs always show what the session decided
    /// and why.
    static func detectCurrentTarget() -> Decision {
        let bundleID = currentFrontmostBundleID()
        let verdict = decision(forBundleID: bundleID) {
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
        #endif
        return IsSecureEventInputEnabled()
    }

    private static func currentFrontmostBundleID() -> String? {
        #if DEBUG
        if let override = debugFrontmostBundleIDOverride {
            return override()
        }
        #endif
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private static func probeFocusedElementLive() -> FocusedElementProbe {
        #if DEBUG
        if let override = debugFocusedElementProbeOverride {
            return override()
        }
        #endif
        guard let (element, _) = SystemAccessibilityFocus.focusedElement() else {
            return .noFocusedElement
        }
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        guard status == .success else { return .valueNotSettable }
        return settable.boolValue ? .valueSettable : .valueNotSettable
    }

    #if DEBUG
    // Test seams: the live AX/NSWorkspace/Carbon reads are not exercisable
    // from unit tests (mirrors the debugConfigureInsertionHooks pattern).
    static var debugFrontmostBundleIDOverride: (() -> String?)?
    static var debugFocusedElementProbeOverride: (() -> FocusedElementProbe)?
    static var debugSecureEventInputOverride: (() -> Bool)?
    #endif
}
