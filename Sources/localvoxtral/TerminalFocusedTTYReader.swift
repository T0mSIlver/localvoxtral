import AppKit
import Foundation
import Observation

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
    func focusedTerminalTTY(bundleID: String) async -> String?
}

/// The live reader: one bounded AppleScript question to Ghostty.
@MainActor
struct GhosttyFocusedTerminalTTYReader: TerminalFocusedTTYReading {
    enum ExecutionResult: Sendable {
        case success(String?)
        case failure(code: Int)
    }

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

    /// Owns both the serial execution context and the compiled script cache.
    /// `NSAppleScript` is not thread-safe, so it is constructed, compiled, and
    /// executed only inside this queue. Only `ExecutionResult` crosses back to
    /// the caller.
    private final class SerialExecutor: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.localvoxtral.ghostty-tty-applescript")
        private let source: String
        private let executeOverride: (@Sendable () -> ExecutionResult)?
        private var cachedScript: NSAppleScript?

        init(
            source: String,
            executeOverride: (@Sendable () -> ExecutionResult)? = nil
        ) {
            self.source = source
            self.executeOverride = executeOverride
        }

        func execute() async -> ExecutionResult {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(returning: executeOnQueue())
                }
            }
        }

        private func executeOnQueue() -> ExecutionResult {
            if let executeOverride { return executeOverride() }
            guard let script = compiledScriptOnQueue() else { return .failure(code: 0) }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                return .failure(code: (error[NSAppleScript.errorNumber] as? Int) ?? 0)
            }
            return .success(result.stringValue)
        }

        private func compiledScriptOnQueue() -> NSAppleScript? {
            if let cachedScript { return cachedScript }
            guard let script = NSAppleScript(source: source)
            else { return nil }
            // Compile eagerly so later executes reuse the compiled form; a
            // compile error is reported by executeAndReturnError either way.
            script.compileAndReturnError(nil)
            cachedScript = script
            return script
        }
    }

    private let executor: SerialExecutor

    init(
        executeScript: (@Sendable () -> ExecutionResult)? = nil
    ) {
        executor = SerialExecutor(source: Self.source, executeOverride: executeScript)
    }

    func focusedTerminalTTY(bundleID: String) async -> String? {
        // Ghostty-only, exact match: the script is Ghostty's dictionary, and
        // sending it anywhere else is at best an error and at worst a prompt
        // to automate an app the user never pointed us at.
        guard bundleID == TerminalScreenAllowlist.ghosttyBundleID else { return nil }
        switch await executor.execute() {
        case .failure(let code):
            // Code only, never the message — AppleScript error strings can
            // quote window titles, and a title is content.
            // -1700: `tty` not in the dictionary (Ghostty < 1.4).
            // -1743: the user declined the Automation prompt.
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
        case .success(let rawTTY):
            return Self.validatedTTY(rawTTY)
        }
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

/// Owns the Observation subscription that mirrors the two settings which can
/// need a focused-pane join. AppDelegate retains one for the app run.
@MainActor
final class GhosttyAutomationConsentPrewarmSettingsObserver {
    private let settings: SettingsStore
    private let prewarm: @MainActor @Sendable () -> Void
    private var started = false
    private var wasEnabled = false

    init(
        settings: SettingsStore,
        prewarm: @escaping @MainActor @Sendable () -> Void
    ) {
        self.settings = settings
        self.prewarm = prewarm
    }

    func start() {
        guard !started else { return }
        started = true
        wasEnabled = isEnabled
        if wasEnabled {
            prewarm()
        }
        observeSettings()
    }

    private var isEnabled: Bool {
        settings.terminalScreenContextEnabled || settings.claudeRepoContextEnabled
    }

    /// Observation's onChange fires once, immediately before a tracked value
    /// mutates. Re-read and re-arm on the next main-actor turn, matching the
    /// app's existing status-observation discipline.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.terminalScreenContextEnabled
            _ = settings.claudeRepoContextEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let enabled = self.isEnabled
                if !self.wasEnabled, enabled {
                    self.prewarm()
                }
                self.wasEnabled = enabled
                self.observeSettings()
            }
        }
    }
}

/// One-shot Automation consent pre-warm for the Ghostty tty read.
///
/// The first Apple event this app ever sends to Ghostty raises the TCC
/// Automation consent sheet, and the send BLOCKS until the user answers — the
/// script's `with timeout` bounds Ghostty's reply, not TCC. Left to happen
/// naturally, that block lands in the middle of the user's first dictation
/// into a Claude pane. So the app fires the same read once, at launch, when a
/// relevant setting is enabled, or as soon as Ghostty launches, with the result
/// discarded: the sheet appears at a moment when nothing is in flight, and
/// every later per-start read finds consent already settled.
///
/// Fires at most once per app run, and only when Ghostty is actually running —
/// `tell application id` would otherwise LAUNCH Ghostty, which a background
/// pre-warm must never do. The caller gates on the context features being
/// enabled, so an opted-out user is never prompted.
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
        execute: @escaping @MainActor @Sendable () async -> Void = {
            _ = await GhosttyFocusedTerminalTTYReader().focusedTerminalTTY(
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

    private static func fire(
        _ execute: @escaping @MainActor @Sendable () async -> Void
    ) {
        fired = true
        // A Task, not an inline call: the pre-warm can park in the consent
        // sheet, and the caller (broker startup) must not wait on that.
        Task { @MainActor in
            Log.claudeContext.info("Pre-warming Ghostty Automation consent (result discarded)")
            await execute()
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
