import AppKit
import ApplicationServices
import ClaudeContextWire
import Darwin
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
///   source files out of VS Code / Cursor. This reader reads only the
///   AX-verified subset of `TerminalScreenAllowlist`
///   (`axCaptureBundleIDs` — Ghostty); iTerm2/Terminal.app are captured over
///   AppleScript instead (`TerminalScreenAppleScriptReader`), never AX.
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
    /// One screen read: the sanitized text plus the identity of the WINDOW the
    /// focused grid belonged to.
    ///
    /// The window identity exists because `TerminalScreenTarget` (pid + bundle
    /// ID) cannot tell two windows of one Ghostty process apart, and the screen
    /// capture and the Claude-session join are two separate AX reads — a window
    /// switch between them would otherwise pair one window's SCREEN with
    /// another window's AUTHORIZATION (review F2). Nil means the identity could
    /// not be established; consumers treat that as "not the same window".
    struct VisibleScreenRead: Sendable, Equatable {
        let text: String
        let windowID: CGWindowID?
    }

    /// One focused-window title read: the parsed marker plus the identity of
    /// the window the title was read from. Same rationale as
    /// `VisibleScreenRead.windowID`.
    struct FocusedWindowMarkerRead: Sendable, Equatable {
        let marker: ClaudeSessionMarker
        let windowID: CGWindowID?
    }
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
    /// This is PER MESSAGE, not per read. A read sends four
    /// (`kAXFocusedUIElement` → `kAXRole` → `kAXValue` → `kAXWindow` for the
    /// window identity; `AXUIElementGetPid` and `_AXUIElementGetWindow` are
    /// local and free), so the worst case is `4 × timeout` against a wedged
    /// Ghostty, and a session pays it twice — once at start, once at stop:
    ///
    ///   0.1 s × 4 messages × 2 reads = 0.8 s worst case per session.
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
    static func readVisibleScreen(applicationPID pid: pid_t) -> VisibleScreenRead? {
        #if DEBUG
        if let override = debugScreenReadOverride {
            // Canned text takes the same sanitization path as live text, so a
            // test cannot assert against a form production never produces.
            guard let raw = override(pid), let text = sanitizedScreenText(raw) else { return nil }
            return VisibleScreenRead(text: text, windowID: debugScreenWindowIDOverride?(pid))
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
        guard let raw = copyFocusedTextAreaValue(applicationPID: pid),
              let text = sanitizedScreenText(raw.text)
        else { return nil }
        return VisibleScreenRead(text: text, windowID: raw.windowID)
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
    static func markerInFocusedWindowTitle(applicationPID pid: pid_t) -> FocusedWindowMarkerRead? {
        #if DEBUG
        if let override = debugWindowTitleOverride {
            guard let marker = override(pid).flatMap({ ClaudeMarkerTitleParser.marker(inTitle: $0) })
            else { return nil }
            return FocusedWindowMarkerRead(
                marker: marker, windowID: debugTitleWindowIDOverride?(pid)
            )
        }
        if TerminalTargetDetector.isRunningUnderXCTest { return nil }
        #endif
        guard AXIsProcessTrusted() else { return nil }
        guard let read = copyFocusedWindowTitle(applicationPID: pid),
              let marker = ClaudeMarkerTitleParser.marker(inTitle: read.title)
        else { return nil }
        return FocusedWindowMarkerRead(marker: marker, windowID: read.windowID)
    }

    /// The identity of `pid`'s focused window, or nil when it cannot be
    /// established.
    ///
    /// This exists for the TTY join: the marker read reports the window it
    /// parsed the marker from, but a tty-resolved join never touches the
    /// marker — the title has typically been clobbered by Claude Code's own
    /// conversation title — so the window the user was focused on is
    /// identified by this separate bounded AX read. Nil abstains at the
    /// authorizer, exactly like a nil marker-read identity (review F2).
    static func focusedWindowIdentity(applicationPID pid: pid_t) -> CGWindowID? {
        #if DEBUG
        if let override = debugTitleWindowIDOverride { return override(pid) }
        if TerminalTargetDetector.isRunningUnderXCTest { return nil }
        #endif
        guard AXIsProcessTrusted() else { return nil }
        return copyFocusedWindowTitle(applicationPID: pid)?.windowID
    }

    /// The AX round trip for the title. Returns the focused window's `AXTitle`
    /// and window identity, only if that window is still owned by `pid`.
    private static func copyFocusedWindowTitle(
        applicationPID pid: pid_t
    ) -> (title: String, windowID: CGWindowID?)? {
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
        return (title: title, windowID: windowID(ofWindow: window))
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
        // Chrome stripping needs trailing-trimmed lines to match, and can
        // leave a blank run where the frame stood — hence compaction on both
        // sides. Both passes are deterministic, so identical screens still
        // sanitize identically (the reconcile comparison depends on that).
        let sanitized = compactedGridWhitespace(
            strippedIdleInputChrome(
                compactedGridWhitespace(
                    PolishContextClipboardReader.sanitizeControlCharacters(raw)
                )
            )
        )
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return sanitized.count > screenCharacterCap
            ? String(sanitized.prefix(screenCharacterCap))
            : sanitized
    }

    /// Claude Code's idle input frame: a box-drawing separator row, a bare `❯`
    /// prompt, a second separator, and optionally the shortcut-hint row under
    /// it (`⏵⏵ auto mode on …`). With the input EMPTY the frame is pure
    /// chrome — no term to ground, the hint row is the pane's one perpetually
    /// animating line, and rendered into a prompt it reads as stray dividers
    /// (field report 2026-07-21). A frame with typed text (`❯ fix the bug`)
    /// is content and is kept. Lone separator rows are also kept: Claude Code
    /// uses the same rule between conversation turns, and only the exact
    /// empty-input triple is chrome. The match is STRUCTURAL, not semantic:
    /// content that reproduces the exact triple (a heredoc or pasted mock of
    /// this very UI) is stripped too — accepted, it is indistinguishable by
    /// construction. The hint row is matched by its `\u{23F5}\u{23F5}` prefix
    /// because its text varies with the mode cycle.
    static func strippedIdleInputChrome(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var index = 0
        while index < lines.count {
            if index + 2 < lines.count,
               isInputFrameSeparator(lines[index]),
               lines[index + 1] == "❯",
               isInputFrameSeparator(lines[index + 2])
            {
                index += 3
                if index < lines.count,
                   lines[index].drop(while: { $0 == " " }).hasPrefix("⏵⏵")
                {
                    index += 1
                }
                continue
            }
            kept.append(lines[index])
            index += 1
        }
        return kept.joined(separator: "\n")
    }

    private static func isInputFrameSeparator(_ line: Substring) -> Bool {
        line.count >= 10 && line.allSatisfy { $0 == "─" }
    }

    /// The AX grid pads rows toward the pane width and reports every blank
    /// viewport row, so a mostly-empty pane arrives as kilobytes of spaces
    /// (field report 2026-07-20: an idle pane rendered ~40 blank padded lines
    /// into the polish prompt). Trailing whitespace carries no term to ground
    /// and a run of blank rows no structure worth more than one line, so both
    /// are compacted — and BEFORE the cap, where padding could otherwise evict
    /// real text from the capped head. Applied at the single sanitization seam
    /// so matching, start/stop comparison, and the rendered excerpt all see
    /// the same form (compaction is deterministic: identical screens stay
    /// identical).
    static func compactedGridWhitespace(_ text: String) -> String {
        var lines: [Substring] = []
        var pendingBlank = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var trimmed = line
            // Every trailing whitespace scalar except newline is padding: plain
            // space/tab, NBSP (U+00A0, which grids use for padding that must not
            // wrap), and the wider Unicode space separators (U+2000–U+200A,
            // U+3000) a terminal may emit. `isWhitespace` minus newline is that
            // class — we split on "\n" already, so a line-internal newline is
            // out of scope and preserved. A line that is ALL such whitespace
            // trims to empty and is treated as blank below, so blank-line
            // detection widens with the trim, at no extra cost.
            while let last = trimmed.last, last.isWhitespace, !last.isNewline {
                trimmed = trimmed.dropLast()
            }
            if trimmed.isEmpty {
                // Leading and trailing blank runs vanish entirely (pending is
                // only flushed when a later non-blank line arrives).
                pendingBlank = !lines.isEmpty
            } else {
                if pendingBlank {
                    lines.append("")
                    pendingBlank = false
                }
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The AX round trip. Returns the raw (unsanitized) `AXValue` string of the
    /// focused element plus the identity of the window containing it, only if
    /// that element is an `AXTextArea` still owned by `pid`.
    private static func copyFocusedTextAreaValue(
        applicationPID pid: pid_t
    ) -> (text: String, windowID: CGWindowID?)? {
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
        return (text: text, windowID: windowID(containing: element))
    }

    // MARK: - Window identity

    /// `_AXUIElementGetWindow`, resolved at runtime. It is the only stable
    /// VALUE identity for a window macOS exposes over AX (there is no public
    /// AXWindowNumber attribute), it has been unchanged for over a decade, and
    /// resolving via `dlsym` means a macOS that finally drops it degrades this
    /// feature to "window identity unknown" instead of failing to launch.
    /// "Unknown" is safe by construction downstream: every consumer refuses raw
    /// attachment rather than assuming two unknowns are the same window.
    private static let getWindowIDFunction: (@convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> AXError)? = {
        guard let symbol = dlsym(
            dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow"
        ) else { return nil }
        return unsafeBitCast(
            symbol,
            to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self
        )
    }()

    /// The `CGWindowID` of a window element, or nil when it cannot be
    /// established. Local call, no AX message.
    private static func windowID(ofWindow window: AXUIElement) -> CGWindowID? {
        guard let function = getWindowIDFunction else { return nil }
        var id: CGWindowID = 0
        guard function(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The `CGWindowID` of the window containing `element`: one extra bounded
    /// AX message (`kAXWindowAttribute`) plus the local ID lookup. The screen
    /// read is therefore four messages, not three — the timeout math on
    /// `messagingTimeoutSeconds` still holds at 0.1 s × 4 × 2 = 0.8 s worst
    /// case per session.
    private static func windowID(containing element: AXUIElement) -> CGWindowID? {
        var windowObject: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &windowObject
        )
        guard status == .success,
              let windowObject,
              CFGetTypeID(windowObject) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return windowID(ofWindow: unsafeDowncast(windowObject, to: AXUIElement.self))
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

    /// Window-identity seams, one per read path so a test can script the F2
    /// race: the screen read and the title read landing on DIFFERENT windows
    /// of one process. Defaulting to nil mirrors live identity failure, which
    /// every consumer must treat as "not provably the same window".
    static var debugScreenWindowIDOverride: ((pid_t) -> CGWindowID?)?
    static var debugTitleWindowIDOverride: ((pid_t) -> CGWindowID?)?
    #endif
}
