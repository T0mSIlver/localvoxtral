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
/// (`ClaudeHookProcessInfo.tty`), the supported terminals expose the focused
/// pane's TTY over AppleScript (Ghostty ≥ 1.4 via ghostty-org/ghostty#11922;
/// iTerm2 sessions and Terminal.app tabs natively), and equality is exact —
/// two sessions in the same repo sit on different TTYs, which is precisely the
/// case the workspace lookup abstains on. The marker join stays as the
/// fallback for older Ghostty and as the ONLY join for SSH-remote sessions,
/// whose TTY names a device on another machine.
@MainActor
protocol TerminalFocusedTTYReading {
    /// The `/dev/ttysNNN` path of the focused pane of `bundleID`'s frontmost
    /// window, or nil when the app is unsupported, too old to expose `tty`,
    /// Automation is denied, or the read failed. Nil means "fall back to the
    /// marker", never "guess".
    func focusedTerminalTTY(bundleID: String) async -> String?
}

/// Owns a compiled-script cache and the serial execution context for ONE
/// AppleScript source. `NSAppleScript` is not thread-safe, so it is
/// constructed, compiled, and executed only inside this queue. Only
/// `AppleScriptTerminalTTYReader.ExecutionResult` crosses back to the caller.
final class TerminalAppleScriptSerialExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let source: String
    private let executeOverride: (@Sendable () -> AppleScriptTerminalTTYReader.ExecutionResult)?
    private var cachedScript: NSAppleScript?

    init(
        source: String,
        queueLabel: String,
        executeOverride: (@Sendable () -> AppleScriptTerminalTTYReader.ExecutionResult)? = nil
    ) {
        queue = DispatchQueue(label: queueLabel)
        self.source = source
        self.executeOverride = executeOverride
    }

    func execute() async -> AppleScriptTerminalTTYReader.ExecutionResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: executeOnQueue())
            }
        }
    }

    private func executeOnQueue() -> AppleScriptTerminalTTYReader.ExecutionResult {
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

/// The live reader: one bounded AppleScript question, addressed per terminal.
///
/// One type for all three supported terminals rather than one per app, because
/// the only thing that differs is the object chain naming the focused pane —
/// the timeout discipline, the reply validation, and the abstain-on-anything
/// behavior must not drift apart per terminal.
@MainActor
struct AppleScriptTerminalTTYReader: TerminalFocusedTTYReading {
    enum ExecutionResult: Sendable {
        case success(String?)
        case failure(code: Int)
    }

    /// `with timeout` bounds THE TERMINAL'S REPLY, so a wedged terminal cannot
    /// hold dictation start hostage — the same budget discipline as the AX
    /// reader's per-message timeouts. It does NOT bound TCC: the first Apple
    /// event ever sent to a terminal parks in the Automation consent sheet for
    /// as long as the user leaves it open, timeout or no timeout. That
    /// first-run freeze belongs at app launch, not mid-dictation, which is
    /// what `TerminalAutomationConsentPrewarm` exists for — by the time a
    /// session start runs this read, the sheet has already come and gone.
    /// `tell application id` of the frontmost app never launches anything: the
    /// caller only asks about an app it just observed as frontmost.
    ///
    /// Per-terminal chains, each naming the FOCUSED pane:
    /// - Ghostty ≥ 1.4: the selected tab's focused split.
    /// - iTerm2: `current session` is the focused split pane of the `current
    ///   window` (key window). Chain per iTerm2's scripting documentation;
    ///   encoded defensively — any AppleScript error abstains.
    /// - Terminal.app: `selected tab of front window` (`tty` confirmed in its
    ///   sdef, code `ttty`; Terminal has no split panes).
    static func scriptSource(forBundleID bundleID: String) -> String? {
        let propertyChain: String
        switch bundleID {
        case TerminalScreenAllowlist.ghosttyBundleID:
            propertyChain = "tty of focused terminal of selected tab of front window"
        case TerminalScreenAllowlist.iterm2BundleID:
            propertyChain = "tty of current session of current window"
        case TerminalScreenAllowlist.appleTerminalBundleID:
            propertyChain = "tty of selected tab of front window"
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

    /// One executor (queue + compiled-script cache) per supported terminal,
    /// built up front so `focusedTerminalTTY` is a pure lookup.
    private let executors: [String: TerminalAppleScriptSerialExecutor]

    /// `executeScript` is the test seam: it receives the bundle id being asked
    /// about and replaces the live AppleScript execution. Unit tests must
    /// never send real Apple events (the first one raises the Automation
    /// consent sheet).
    init(
        executeScript: (@Sendable (String) -> ExecutionResult)? = nil
    ) {
        var executors: [String: TerminalAppleScriptSerialExecutor] = [:]
        for bundleID in TerminalScreenAllowlist.supportedBundleIDs {
            guard let source = Self.scriptSource(forBundleID: bundleID) else { continue }
            let executeOverride: (@Sendable () -> ExecutionResult)?
            if let executeScript {
                executeOverride = { executeScript(bundleID) }
            } else {
                executeOverride = nil
            }
            executors[bundleID] = TerminalAppleScriptSerialExecutor(
                source: source,
                queueLabel: "com.localvoxtral.terminal-tty-applescript.\(bundleID)",
                executeOverride: executeOverride
            )
        }
        self.executors = executors
    }

    func focusedTerminalTTY(bundleID: String) async -> String? {
        // Allowlisted terminals only, exact match: each script is that app's
        // dictionary, and sending one anywhere else is at best an error and at
        // worst a prompt to automate an app the user never pointed us at.
        guard let executor = executors[bundleID] else { return nil }
        switch await executor.execute() {
        case .failure(let code):
            // Code only, never the message — AppleScript error strings can
            // quote window titles, and a title is content.
            // -1700/-1728: the property chain is not in the dictionary
            // (Ghostty < 1.4, or a terminal build without it).
            // -1743: the user declined the Automation prompt.
            if code == -1743 {
                Log.claudeContext.info(
                    "Automation permission denied — grant localvoxtral → \(bundleID, privacy: .public) in System Settings > Privacy > Automation"
                )
            } else {
                Log.claudeContext.info(
                    "Focused-pane tty unavailable for \(bundleID, privacy: .public) (AppleScript error \(code, privacy: .public))"
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
final class TerminalAutomationConsentPrewarmSettingsObserver {
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

/// One-shot-per-terminal Automation consent pre-warm for the AppleScript reads
/// (the focused-pane tty question, and — for iTerm2/Terminal.app — the
/// focused session/tab contents read; one Automation grant covers both, since
/// TCC consent is per target app, not per property).
///
/// The first Apple event this app ever sends to a terminal raises the TCC
/// Automation consent sheet, and the send BLOCKS until the user answers — the
/// script's `with timeout` bounds the terminal's reply, not TCC. Left to
/// happen naturally, that block lands in the middle of the user's first
/// dictation into a Claude pane. So the app fires the same read once per
/// terminal, at launch, when a relevant setting is enabled, or as soon as that
/// terminal launches, with the result discarded: the sheet appears at a moment
/// when nothing is in flight, and every later per-start read finds consent
/// already settled.
///
/// Fires at most once per terminal per app run, and only when that terminal is
/// actually running — `tell application id` would otherwise LAUNCH it, which a
/// background pre-warm must never do. The caller gates on the context features
/// being enabled, so an opted-out user is never prompted.
@MainActor
enum TerminalAutomationConsentPrewarm {
    private static var firedBundleIDs: Set<String> = []
    private static var launchObservers: [String: any NSObjectProtocol] = [:]
    private static var observedCenters: [String: NotificationCenter] = [:]

    /// Fires the pre-warm now when `bundleID`'s app is running, otherwise arms
    /// a one-shot launch observer that fires it when the app appears.
    ///
    /// `isTerminalRunning`/`execute` default to the live checks for
    /// `bundleID`; tests always inject both (a defaulted execute sends a real
    /// Apple event).
    static func fireOnceWhenTerminalIsAvailable(
        bundleID: String,
        isTerminalRunning: (@MainActor @Sendable () -> Bool)? = nil,
        execute: (@MainActor @Sendable () async -> Void)? = nil,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        let isRunning = isTerminalRunning ?? {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).isEmpty
        }
        let execute = execute ?? {
            _ = await AppleScriptTerminalTTYReader().focusedTerminalTTY(bundleID: bundleID)
        }
        guard !firedBundleIDs.contains(bundleID), launchObservers[bundleID] == nil else { return }
        if isRunning() {
            fire(bundleID: bundleID, execute)
            return
        }
        observedCenters[bundleID] = notificationCenter
        launchObservers[bundleID] = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !firedBundleIDs.contains(bundleID), isRunning() else { return }
                removeObserver(bundleID: bundleID)
                fire(bundleID: bundleID, execute)
            }
        }
    }

    private static func fire(
        bundleID: String,
        _ execute: @escaping @MainActor @Sendable () async -> Void
    ) {
        firedBundleIDs.insert(bundleID)
        // A Task, not an inline call: the pre-warm can park in the consent
        // sheet, and the caller (broker startup) must not wait on that.
        Task { @MainActor in
            Log.claudeContext.info(
                "Pre-warming Automation consent for \(bundleID, privacy: .public) (result discarded)"
            )
            await execute()
        }
    }

    private static func removeObserver(bundleID: String) {
        if let observer = launchObservers[bundleID], let center = observedCenters[bundleID] {
            center.removeObserver(observer)
        }
        launchObservers[bundleID] = nil
        observedCenters[bundleID] = nil
    }

    #if DEBUG
    /// Test-only: restore the untouched state so each test observes its own
    /// one-shot semantics.
    static func debugReset() {
        for bundleID in Array(launchObservers.keys) {
            removeObserver(bundleID: bundleID)
        }
        firedBundleIDs = []
    }
    #endif
}
