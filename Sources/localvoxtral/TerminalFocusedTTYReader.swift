import AppKit
import Foundation

/// Reads the controlling TTY of the FOCUSED terminal pane, so the Claude join
/// can resolve from the process table instead of the window title.
///
/// The title is a fought-over channel: Claude Code writes its own
/// conversation-derived titles and clobbers the `lvx-` marker whenever it is
/// responding (field finding, 2026-07-17), so a title read mid-turn abstains
/// even though the session is right there. A pane's TTY has no such war: the
/// hook publisher already reports the session's controlling TTY
/// (`ClaudeHookProcessInfo.tty`), Ghostty ≥ 1.4 exposes the focused pane's TTY
/// over AppleScript (ghostty-org/ghostty#11922), and equality is exact — two
/// sessions in the same repo sit on different TTYs, which is precisely the case
/// the workspace lookup abstains on. The marker join stays as the fallback for
/// older Ghostty and as the ONLY join for SSH-remote sessions, whose TTY names
/// a device on another machine.
@MainActor
protocol TerminalFocusedTTYReading {
    /// The `/dev/ttysNNN` path of the focused pane of `bundleID`'s frontmost
    /// window, or nil when the app is unsupported, too old to expose `tty`,
    /// Automation is denied, or the read failed. Nil means "fall back to the
    /// marker", never "guess".
    func focusedTerminalTTY(bundleID: String) -> String?
}

/// The live reader: one bounded AppleScript question to Ghostty.
@MainActor
struct GhosttyFocusedTerminalTTYReader: TerminalFocusedTTYReading {
    /// `with timeout` bounds GHOSTTY'S REPLY, so a wedged terminal cannot hold
    /// dictation start hostage — the same budget discipline as the AX reader's
    /// per-message timeouts. It does NOT bound TCC: the first Apple event ever
    /// sent to Ghostty parks in the Automation consent sheet for as long as
    /// the user leaves it open, timeout or no timeout. That first-run freeze
    /// belongs at app launch, not mid-dictation, which is what
    /// `GhosttyAutomationConsentPrewarm` exists for — by the time a session
    /// start runs this read, the sheet has already come and gone.
    /// `tell application id` of the frontmost app never launches anything: the
    /// caller only asks about an app it just observed as frontmost.
    private static let source = """
    with timeout of 1 second
        tell application id "\(TerminalScreenAllowlist.ghosttyBundleID)"
            get tty of focused terminal of selected tab of front window
        end tell
    end timeout
    """

    /// Compiled once, reused for every session start. A fresh `NSAppleScript`
    /// recompiles the (constant) source on each call — avoidable milliseconds
    /// on the dictation-start hot path. The per-start call itself stays
    /// synchronous-but-bounded by design: a true off-main hop would make the
    /// join resolution async and restructure session start, so it is
    /// deliberately deferred.
    private static var cachedScript: NSAppleScript?

    private static func compiledScript() -> NSAppleScript? {
        if let cachedScript { return cachedScript }
        guard let script = NSAppleScript(source: source) else { return nil }
        // Compile eagerly so later executes reuse the compiled form; a compile
        // error is reported by executeAndReturnError below either way.
        script.compileAndReturnError(nil)
        cachedScript = script
        return script
    }

    func focusedTerminalTTY(bundleID: String) -> String? {
        // Ghostty-only, exact match: the script is Ghostty's dictionary, and
        // sending it anywhere else is at best an error and at worst a prompt
        // to automate an app the user never pointed us at.
        guard bundleID == TerminalScreenAllowlist.ghosttyBundleID else { return nil }
        guard let script = Self.compiledScript() else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // Code only, never the message — AppleScript error strings can
            // quote window titles, and a title is content.
            // -1700: `tty` not in the dictionary (Ghostty < 1.4).
            // -1743: the user declined the Automation prompt.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 {
                Log.claudeContext.info(
                    "Automation permission denied — grant localvoxtral → Ghostty in System Settings > Privacy > Automation"
                )
            } else {
                Log.claudeContext.info(
                    "Focused-pane tty unavailable (AppleScript error \(code, privacy: .public))"
                )
            }
            return nil
        }
        return Self.validatedTTY(result.stringValue)
    }

    /// Accepts only a plausible pty device path. The value crosses from another
    /// process into a registry lookup; a reply that is not shaped like
    /// `/dev/tty…` (empty, a title, an injection attempt via a renamed app)
    /// must read as "no answer", not as a key.
    static func validatedTTY(_ raw: String?) -> String? {
        guard let raw,
              raw.hasPrefix("/dev/tty"),
              raw.count <= 64,
              raw.allSatisfy({ $0.isASCII && !$0.isWhitespace })
        else { return nil }
        return raw
    }
}

/// One-shot Automation consent pre-warm for the Ghostty tty read.
///
/// The first Apple event this app ever sends to Ghostty raises the TCC
/// Automation consent sheet, and the send BLOCKS until the user answers — the
/// script's `with timeout` bounds Ghostty's reply, not TCC. Left to happen
/// naturally, that block lands in the middle of the user's first dictation
/// into a Claude pane. So the app fires the same read once, at launch (or as
/// soon as Ghostty launches), with the result discarded: the sheet appears at
/// a moment when nothing is in flight, and every later per-start read finds
/// consent already settled.
///
/// Fires at most once per app run, and only when Ghostty is actually running —
/// `tell application id` would otherwise LAUNCH Ghostty, which a background
/// pre-warm must never do. The caller gates on the context features being
/// enabled, so an opted-out user is never prompted; a user who enables the
/// feature mid-run gets pre-warmed on the next launch (a Settings-toggle
/// pre-warm is deferred until someone hits it).
@MainActor
enum GhosttyAutomationConsentPrewarm {
    private static var fired = false
    private static var launchObserver: (any NSObjectProtocol)?
    private static var observedCenter: NotificationCenter?

    /// Fires the pre-warm now when Ghostty is running, otherwise arms a
    /// one-shot launch observer that fires it when Ghostty appears.
    static func fireOnceWhenGhosttyIsAvailable(
        isGhosttyRunning: @escaping @MainActor @Sendable () -> Bool = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: TerminalScreenAllowlist.ghosttyBundleID
            ).isEmpty
        },
        execute: @escaping @MainActor @Sendable () -> Void = {
            _ = GhosttyFocusedTerminalTTYReader().focusedTerminalTTY(
                bundleID: TerminalScreenAllowlist.ghosttyBundleID
            )
        },
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        guard !fired, launchObserver == nil else { return }
        if isGhosttyRunning() {
            fire(execute)
            return
        }
        observedCenter = notificationCenter
        launchObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !fired, isGhosttyRunning() else { return }
                removeObserver()
                fire(execute)
            }
        }
    }

    private static func fire(_ execute: @escaping @MainActor @Sendable () -> Void) {
        fired = true
        // A Task, not an inline call: the pre-warm can park in the consent
        // sheet, and the caller (broker startup) must not wait on that.
        Task { @MainActor in
            Log.claudeContext.info("Pre-warming Ghostty Automation consent (result discarded)")
            execute()
        }
    }

    private static func removeObserver() {
        if let launchObserver, let observedCenter {
            observedCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
        observedCenter = nil
    }

    #if DEBUG
    /// Test-only: restore the untouched state so each test observes its own
    /// one-shot semantics.
    static func debugReset() {
        removeObserver()
        fired = false
    }
    #endif
}
