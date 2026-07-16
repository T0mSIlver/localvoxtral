import AppKit
import ApplicationServices
import ClaudeContextWire
import Foundation

/// Reads the visible screen text of a Ghostty terminal window over
/// Accessibility, for use as polish reference context.
///
/// Deliberately narrow, because everything here runs against a live foreign
/// process on the user's dictation hot path:
///
/// - **Ghostty only.** `TerminalTargetDetector`'s allowlist answers a different
///   question ("does this app reject AX value writes?") and deliberately spans
///   every terminal plus user-supplied bundles, including Electron apps whose
///   AX tree exposes the user's editor buffer. Reusing it here would read
///   source files out of VS Code / Cursor. This reader keeps its own
///   single-entry allowlist — see `TerminalScreenAllowlist`.
/// - **PID-pinned.** The element is reached from `AXUIElementCreateApplication`
///   for a caller-supplied PID, never from system-wide focus, and the element's
///   own PID is re-read and compared before its value is trusted. A window that
///   changed owners between resolve and read yields nil rather than another
///   app's text.
/// - **`AXTextArea` only.** Ghostty's terminal grid is an `AXTextArea`; its
///   title bar, tab bar, and quick-terminal chrome are not. Requiring the role
///   means a resolve that lands on chrome returns nothing instead of a title.
/// - **Bounded.** Both the app element and the focused element get short AX
///   messaging timeouts, so a wedged or paging terminal cannot stall the
///   session-start path — `AXUIElementCopyAttributeValue` is a synchronous IPC
///   round trip to a process we do not control.
/// - **No `AXVisibleCharacterRange`.** It is a range-valued `AXValue` requiring
///   a follow-up `AXStringForRange` round trip, and Ghostty reports it
///   inconsistently across scrollback states. `AXValue` (the whole screen text)
///   is one read, and the cap below bounds it. No AppleScript either: it needs
///   Automation consent, prompts separately, and is a second scriptable
///   surface to keep honest.
///
/// Only `String`/value types cross this type's boundary — an `AXUIElement` is a
/// live handle into another process and never escapes.
@MainActor
enum TerminalScreenAXReader {
    /// Absolute character cap on a screen read. A tall Ghostty window on a
    /// 6K display is ~200×80 ≈ 16k characters, so this admits the full visible
    /// screen with headroom while bounding both the AX payload we retain and
    /// what a later caller could put in a prompt. Generous on purpose: the
    /// downstream excerpt cap is the prompt-budget decision, this is the
    /// safety ceiling.
    ///
    /// This bounds what a read may return into MEMORY for vocabulary matching,
    /// which is local and free. It is emphatically NOT a prompt budget — a
    /// rendered excerpt rides the grant `PolishContextBudget` allocates across
    /// every context source for one request, which is an order of magnitude
    /// smaller. `nonisolated` so non-isolated callers can compare against it.
    nonisolated static let screenCharacterCap = 24_000

    /// AX messaging timeout for both the app element and the focused element.
    /// `AXUIElementSetMessagingTimeout` is per-element, and the app-element
    /// timeout does NOT inherit to elements copied out of it — hence both.
    ///
    /// This is PER MESSAGE, not per read. A read sends three
    /// (`kAXFocusedUIElement` → `kAXRole` → `kAXValue`; `AXUIElementGetPid` is
    /// local and free), so the worst case is `3 × timeout` against a wedged
    /// Ghostty, and a session pays it twice — once at start, once at stop:
    ///
    ///   0.1 s × 3 messages × 2 reads = 0.6 s worst case per session.
    ///
    /// Both reads are on the main actor (start blocks the socket opening; stop
    /// blocks the commit), so that number is a user-visible stall ceiling, not
    /// background work. 0.1 s is ~100× a healthy round trip (sub-millisecond)
    /// and keeps the total under the ~1 s where a stall stops reading as
    /// "instant". If this ever needs to grow, move the read off the main actor
    /// first.
    static let messagingTimeoutSeconds: Float = 0.1

    /// The sanitized visible text of the Ghostty terminal grid owned by `pid`,
    /// or nil when Accessibility is untrusted, nothing is focused, the focused
    /// element is not a terminal grid, the element's owner PID no longer
    /// matches, or the text is empty/unusable.
    ///
    /// Callers MUST have already cleared the feature gate
    /// (`TerminalScreenContext.shouldAttemptRead`) — this function does not
    /// re-check the setting or the endpoint. Trust is re-checked here anyway
    /// because it can drop between the gate and the read.
    static func readVisibleScreen(applicationPID pid: pid_t) -> String? {
        #if DEBUG
        if let override = debugScreenReadOverride {
            // Canned text takes the same sanitization path as live text, so a
            // test cannot assert against a form production never produces.
            guard let raw = override(pid) else { return nil }
            return sanitizedScreenText(raw)
        }
        // Under XCTest an unpinned read would query whatever the HOST's AX
        // tree happens to hold (the same class of live-state flake that made
        // TerminalTargetDetector's seams default to fixed values). Tests that
        // exercise the decision logic pin the override.
        if TerminalTargetDetector.isRunningUnderXCTest { return nil }
        #endif

        guard AXIsProcessTrusted() else {
            Log.target.info("Terminal screen context skipped: Accessibility not trusted")
            return nil
        }
        guard let raw = copyFocusedTextAreaValue(applicationPID: pid) else { return nil }
        return sanitizedScreenText(raw)
    }

    /// The marker Claude Code wrote into the focused window's title for `pid`,
    /// or nil when there is no window, no title, no marker, or more than one
    /// marker.
    ///
    /// This is the INBOUND half of the focus join (see `ClaudeMarkerPresentation`).
    /// It reads `AXTitle`, not screen content: a title is a few dozen characters
    /// the terminal already advertises, and reading it is what tells us whether
    /// this pane is a Claude session at all. Distinct from `readVisibleScreen`
    /// on purpose — this is the cheap question that gates the expensive answer.
    ///
    /// PID-pinned exactly like the screen read: the window is reached from
    /// `AXUIElementCreateApplication(pid)` and the element's own PID is
    /// re-verified before its title is trusted, so a recycled PID or a window
    /// that changed owners yields nil instead of another app's title.
    ///
    /// Callers must treat nil as "we do not know", never as a cue to guess.
    static func markerInFocusedWindowTitle(applicationPID pid: pid_t) -> ClaudeSessionMarker? {
        #if DEBUG
        if let override = debugWindowTitleOverride {
            return override(pid).flatMap { ClaudeMarkerTitleParser.marker(inTitle: $0) }
        }
        if TerminalTargetDetector.isRunningUnderXCTest { return nil }
        #endif
        guard AXIsProcessTrusted() else { return nil }
        guard let title = copyFocusedWindowTitle(applicationPID: pid) else { return nil }
        return ClaudeMarkerTitleParser.marker(inTitle: title)
    }

    /// The AX round trip for the title. Returns the focused window's `AXTitle`,
    /// only if that window is still owned by `pid`.
    private static func copyFocusedWindowTitle(applicationPID pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)

        var windowObject: AnyObject?
        let windowStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowObject
        )
        guard windowStatus == .success,
              let windowObject,
              CFGetTypeID(windowObject) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let window = unsafeDowncast(windowObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, messagingTimeoutSeconds)

        // Owner cross-check before trusting the value, same as the screen read.
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(window, &elementPID) == .success, elementPID == pid else {
            return nil
        }

        var titleObject: AnyObject?
        let titleStatus = AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleObject
        )
        guard titleStatus == .success, let title = titleObject as? String else { return nil }
        return title
    }

    /// Sanitizes and caps a raw AX string. Split out so tests can exercise the
    /// text rules without any AX involvement, and so the DEBUG seam's canned
    /// text goes through exactly the same path as live text.
    ///
    /// Control scalars are stripped through the shared clipboard sanitizer
    /// (newlines and tabs survive, so the grid's line structure does), then the
    /// head is capped. Returns nil for text that is empty or whitespace-only —
    /// a freshly cleared terminal is not context.
    static func sanitizedScreenText(_ raw: String) -> String? {
        let sanitized = PolishContextClipboardReader.sanitizeControlCharacters(raw)
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return sanitized.count > screenCharacterCap
            ? String(sanitized.prefix(screenCharacterCap))
            : sanitized
    }

    /// The AX round trip. Returns the raw (unsanitized) `AXValue` string of the
    /// focused element, only if that element is an `AXTextArea` still owned by
    /// `pid`.
    private static func copyFocusedTextAreaValue(applicationPID pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        // Bound the app-element round trip before making one.
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)

        var focusedObject: AnyObject?
        let focusStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusStatus == .success,
              let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let element = unsafeDowncast(focusedObject, to: AXUIElement.self)
        // Per-element: the copied element carries the API default, not the app
        // element's timeout.
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)

        // Cross-check the owner BEFORE reading any text: PIDs are recycled, and
        // the app element is just a PID wrapper — if the focused element is not
        // owned by the PID we pinned, its value is some other app's content.
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else {
            return nil
        }

        // Ghostty's grid is an AXTextArea. Anything else (title bar, tab bar,
        // chrome) is not screen content and must not be read.
        var roleObject: AnyObject?
        let roleStatus = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleObject
        )
        guard roleStatus == .success,
              let role = roleObject as? String,
              role == (kAXTextAreaRole as String)
        else {
            return nil
        }

        var valueObject: AnyObject?
        let valueStatus = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObject
        )
        guard valueStatus == .success, let text = valueObject as? String else { return nil }
        return text
    }

    #if DEBUG
    /// Test seam: returns the raw screen text for a PID (pre-sanitization), or
    /// nil to simulate an unreadable target. Live AX is not exercisable from
    /// unit tests; mirrors `TerminalTargetDetector.debugFocusedElementProbeOverride`.
    static var debugScreenReadOverride: ((pid_t) -> String?)?

    /// Test seam for the focused window's raw title. Canned titles take the
    /// same parse path as live ones, so a test cannot assert against a form
    /// production never produces.
    static var debugWindowTitleOverride: ((pid_t) -> String?)?
    #endif
}
