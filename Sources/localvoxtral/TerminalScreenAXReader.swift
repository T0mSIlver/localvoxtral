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
            guard let raw = override(pid), let text = TerminalScreenText.sanitizedScreenText(raw) else { return nil }
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
              let text = TerminalScreenText.sanitizedScreenText(raw.text)
        else { return nil }
        return VisibleScreenRead(text: text, windowID: raw.windowID)
    }

    /// The identity of `pid`'s focused window, or nil when it cannot be
    /// established.
    ///
    /// Nothing here reads what the window is CALLED. A window title is a
    /// fought-over channel — Claude Code writes its own conversation titles,
    /// herdr and cmux rewrite theirs — and no join arm consults one; this is
    /// purely the identity that pairs a screen capture with the join that
    /// authorized it, so a focus change between those two AX reads cannot pair
    /// one window's screen with another window's session (review F2). Nil
    /// abstains at the authorizer.
    ///
    /// PID-pinned exactly like the screen read: the window is reached from
    /// `AXUIElementCreateApplication(pid)` and the element's own PID is
    /// re-verified, so a recycled PID or a window that changed owners yields
    /// nil instead of another app's identity.
    static func focusedWindowIdentity(applicationPID pid: pid_t) -> CGWindowID? {
        #if DEBUG
        if let override = debugFocusedWindowIDOverride { return override(pid) }
        if TerminalTargetDetector.isRunningUnderXCTest { return nil }
        #endif
        guard AXIsProcessTrusted() else { return nil }
        return copyFocusedWindowIdentity(applicationPID: pid)
    }

    /// The AX round trip for the focused window's identity, only if that
    /// window is still owned by `pid`.
    private static func copyFocusedWindowIdentity(
        applicationPID pid: pid_t
    ) -> CGWindowID? {
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

        // No `kAXTitle` round trip. No JOIN reads a title (the arm that did
        // was removed 2026-09-05), and requiring one here would make identity
        // depend on a string this code does not consult. The one title read
        // left in the app is a different feature on a different gate —
        // `TerminalWorkingDirectoryResolver.windowTitle(forApplicationPID:)`,
        // which mines a terminal title for a git root under
        // `repoVocabularyEnabled` and decides no join.
        // Consequence, stated because it is a change:
        // a focused window with no readable title now yields an identity where
        // it used to abstain. That can only make the authorizer's
        // join-window == capture-window comparison MORE precise — it compares
        // two established ids and never treats an unknown as a match.
        return windowID(ofWindow: window)
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

    /// Window-identity seams, one per read path so a test can script the F2
    /// race: the screen read and the focused-window read landing on DIFFERENT
    /// windows of one process. Defaulting to nil mirrors live identity
    /// failure, which every consumer must treat as "not provably the same
    /// window".
    static var debugScreenWindowIDOverride: ((pid_t) -> CGWindowID?)?
    static var debugFocusedWindowIDOverride: ((pid_t) -> CGWindowID?)?
    #endif
}

extension TerminalScreenAXReader {
    /// `TerminalScreenText`'s cap and sanitizer under their former names, for
    /// `SocketPaneScreenContext` until it calls them there (#591).
    nonisolated static let screenCharacterCap = TerminalScreenText.screenCharacterCap

    static func sanitizedScreenText(_ raw: String) -> String? {
        TerminalScreenText.sanitizedScreenText(raw)
    }
}
