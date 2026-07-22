import AppKit
import Foundation

/// Reads the visible contents of the FOCUSED iTerm2 session / Terminal.app tab
/// over AppleScript, for use as polish reference context.
///
/// This is the AppleScript sibling of `TerminalScreenAXReader`, for the
/// terminals whose AX trees are NOT verified single-grid surfaces
/// (`TerminalScreenAllowlist.appleScriptCaptureBundleIDs`): iTerm2's AX tree
/// is ambiguous across split panes, and Terminal.app's is unverified. Their
/// scripting dictionaries, by contrast, name the focused pane exactly:
///
/// - iTerm2: `contents of current session of current window` — the focused
///   split pane of the key window, per iTerm2's scripting documentation.
/// - Terminal.app: `contents of selected tab of front window` — sdef-confirmed
///   ("The currently visible contents of the tab", code `pcnt`). NOT
///   `history`, which is the entire scrollback buffer; the capture must be
///   what the user could see while speaking, nothing more.
///
/// The answer comes from the terminal process itself over an Apple event —
/// the same trust class as the focused-TTY read that powers the Claude join —
/// and is per-pane clean by construction: no neighboring split's text can ride
/// along, unlike a composite AX capture.
///
/// Discipline mirrors the AX reader:
///
/// - **Bounded.** The script's `with timeout of 1 second` bounds the
///   terminal's reply, so a wedged terminal costs at most ~1 s per read, twice
///   per session (start + stop) — the same order as the AX reader's documented
///   0.8 s ceiling. It does NOT bound TCC: the first Apple event parks in the
///   Automation consent sheet, which is why `TerminalAutomationConsentPrewarm`
///   fires at launch. The STOP read can never park: it only runs when the
///   START read succeeded, which proves consent was already granted.
/// - **Abstain on everything.** Automation denied, no front window, a missing
///   property, an empty or oversized reply — all return nil, never a guess.
///   Error codes only are logged, never AppleScript error strings (they can
///   quote window titles, and a title is content); text is logged as char
///   counts only.
/// - **Same pipeline.** The raw reply goes through
///   `TerminalScreenAXReader.sanitizedScreenText` — identical control-scalar
///   stripping, chrome stripping, whitespace compaction, and the same
///   `screenCharacterCap` — so matching, start/stop comparison, and excerpt
///   rendering see exactly the form AX text takes.
/// - **Never launches.** Callers only ask about an app they just resolved as
///   running (`frontmostTarget()` / `target(forPID:)`), so `tell application
///   id` cannot launch anything.
///
/// Synchronous on the main actor, deliberately: the stop-time re-read runs
/// inside the synchronous commit path exactly like the AX read, and the two
/// capture routes must share one lifecycle. If the ~1 s worst case ever needs
/// to shrink, move BOTH readers off the main actor together.
@MainActor
enum TerminalScreenAppleScriptReader {
    /// Absolute ceiling on the RAW AppleScript reply, checked before
    /// sanitization. A visible screen is ~16k characters on a 6K display; a
    /// reply beyond this is not a screen (a scrollback property answered by a
    /// renamed app, a runaway build) and is refused outright — abstain, never
    /// truncate, because truncating an implausible reply would still retain
    /// content we cannot account for. Distinct from
    /// `TerminalScreenAXReader.screenCharacterCap`, which caps the SANITIZED
    /// head for matching.
    nonisolated static let rawReplyCharacterCeiling = 200_000

    /// The AppleScript source naming the focused pane's visible contents, or
    /// nil for a bundle without a verified contents chain.
    static func scriptSource(forBundleID bundleID: String) -> String? {
        let propertyChain: String
        switch bundleID {
        case TerminalScreenAllowlist.iterm2BundleID:
            propertyChain = "contents of current session of current window"
        case TerminalScreenAllowlist.appleTerminalBundleID:
            propertyChain = "contents of selected tab of front window"
        default:
            return nil
        }
        return """
        with timeout of 1 second
            tell application id "\(bundleID)"
                get \(propertyChain)
            end tell
        end timeout
        """
    }

    /// Compiled-script cache, one per bundle. Compilation binds the app's
    /// scripting terminology once; later reads reuse the compiled form.
    private static var cachedScripts: [String: NSAppleScript] = [:]

    /// The sanitized visible contents of the focused session/tab of `target`,
    /// or nil when the bundle has no AppleScript capture route, Automation is
    /// denied, the app has no front window, the reply is missing/empty/
    /// oversized, or sanitization leaves nothing.
    ///
    /// Callers MUST have already cleared the feature gate
    /// (`TerminalScreenContext.shouldAttemptRead`) — this function does not
    /// re-check the setting or the endpoint.
    ///
    /// The window identity rides along for the same reason as the AX read's:
    /// pid + bundle ID cannot tell two windows of one terminal process apart,
    /// and raw attachment is authorized per window (review F2). It comes from
    /// the shared PID-pinned AX focused-window read — one bounded AX message —
    /// because the capture must be paired with the same identity namespace the
    /// join uses. Nil means unknown, which never authorizes.
    static func readVisibleScreen(
        target: TerminalScreenTarget
    ) -> TerminalScreenAXReader.VisibleScreenRead? {
        guard TerminalScreenAllowlist.isAppleScriptCaptureSupported(target.bundleID) else {
            return nil
        }
        #if DEBUG
        if let override = debugContentsReadOverride {
            // Canned text takes the same validation + sanitization path as a
            // live reply, so a test cannot assert against a form production
            // never produces.
            guard let raw = validatedRawContents(override(target.pid, target.bundleID)),
                  let text = TerminalScreenAXReader.sanitizedScreenText(raw)
            else { return nil }
            return TerminalScreenAXReader.VisibleScreenRead(
                text: text,
                windowID: TerminalScreenAXReader.debugScreenWindowIDOverride?(target.pid)
            )
        }
        // Under XCTest an unpinned read would send a REAL Apple event to
        // whatever terminal the host happens to run (and raise the Automation
        // consent sheet). Tests pin the override.
        if TerminalTargetDetector.isRunningUnderXCTest { return nil }
        #endif

        guard let script = compiledScript(forBundleID: target.bundleID) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // Code only, never the message — AppleScript error strings can
            // quote window titles, and a title is content.
            if code == -1743 {
                Log.target.info(
                    "Automation permission denied — grant localvoxtral → \(target.bundleID, privacy: .public) in System Settings > Privacy > Automation"
                )
            } else {
                Log.target.info(
                    "Terminal screen contents unavailable for \(target.bundleID, privacy: .public) (AppleScript error \(code, privacy: .public))"
                )
            }
            return nil
        }
        guard let raw = validatedRawContents(result.stringValue) else {
            Log.target.info(
                "Terminal screen contents refused for \(target.bundleID, privacy: .public): \(result.stringValue?.count ?? 0, privacy: .public)ch reply"
            )
            return nil
        }
        guard let text = TerminalScreenAXReader.sanitizedScreenText(raw) else { return nil }
        return TerminalScreenAXReader.VisibleScreenRead(
            text: text,
            windowID: TerminalScreenAXReader.focusedWindowIdentity(applicationPID: target.pid)
        )
    }

    /// Accepts only a plausible visible-screen reply: non-nil, non-empty, and
    /// under the raw ceiling. Split out so tests exercise the bounds without
    /// AppleScript.
    static func validatedRawContents(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= rawReplyCharacterCeiling else { return nil }
        return raw
    }

    private static func compiledScript(forBundleID bundleID: String) -> NSAppleScript? {
        if let cached = cachedScripts[bundleID] { return cached }
        guard let source = scriptSource(forBundleID: bundleID),
              let script = NSAppleScript(source: source)
        else { return nil }
        script.compileAndReturnError(nil)
        cachedScripts[bundleID] = script
        return script
    }

    #if DEBUG
    /// Test seam: returns the raw focused-pane contents for (pid, bundleID)
    /// pre-sanitization, or nil to simulate an unreadable target. Live
    /// AppleScript is not exercisable from unit tests; mirrors
    /// `TerminalScreenAXReader.debugScreenReadOverride`. The window identity
    /// reuses `TerminalScreenAXReader.debugScreenWindowIDOverride` so
    /// reconcile tests script one identity namespace across both routes.
    static var debugContentsReadOverride: ((pid_t, String) -> String?)?
    #endif
}
