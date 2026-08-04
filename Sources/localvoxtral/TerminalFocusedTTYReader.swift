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
    /// reader's per-message timeouts. It ALSO bounds the life of the TCC
    /// Automation consent sheet: macOS tears the sheet down the moment the
    /// pending Apple event times out (field bug 2026-07-22 — iTerm2's prompt
    /// vanished after ~1 s, before the user could answer). Consent must
    /// therefore be settled by `TerminalAutomationConsentPrewarm`, whose probe
    /// sends the same question under `consentPrewarmScriptSource` — a timeout
    /// long enough for a human to answer the sheet — so by the time a session
    /// start runs this read, consent has already been decided.
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
        script(forBundleID: bundleID, timeoutSeconds: 1)
    }

    /// The consent pre-warm's variant of the same question: identical property
    /// chain, but the Apple event must outlive a human reading and answering
    /// the Automation consent sheet — the sheet is dismissed when the event
    /// times out, so a 1 s probe presents a 1 s prompt.
    static func consentPrewarmScriptSource(forBundleID bundleID: String) -> String? {
        script(forBundleID: bundleID, timeoutSeconds: 600)
    }

    private static func script(forBundleID bundleID: String, timeoutSeconds: Int) -> String? {
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
        let timeout = timeoutSeconds == 1 ? "1 second" : "\(timeoutSeconds) seconds"
        return """
        with timeout of \(timeout)
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
    private let disarm: @MainActor @Sendable () -> Void
    private let enablement: @MainActor @Sendable (SettingsStore) -> Bool
    private var started = false
    private var wasEnabled = false

    /// - Parameter enablement: which settings make this pre-warm relevant.
    ///   Defaults to the terminal pair (either context feature can want a
    ///   focused-pane join). The BROWSER pre-warm passes a narrower one: a
    ///   browser join can only ever produce session/repo context, so a user who
    ///   enabled screen context alone must never be asked to let us automate
    ///   their browser. One observer per predicate, so enabling the second
    ///   feature later still fires its own pre-warm.
    /// - Parameter disarm: cancels pre-warms this observer armed but that have
    ///   not fired, called when the enabling setting goes OFF. Without it an
    ///   armed launch observer outlives the feature and raises a consent sheet
    ///   for something the user has since switched off.
    init(
        settings: SettingsStore,
        prewarm: @escaping @MainActor @Sendable () -> Void,
        disarm: @escaping @MainActor @Sendable () -> Void = {},
        enablement: @escaping @MainActor @Sendable (SettingsStore) -> Bool = {
            $0.terminalScreenContextEnabled || $0.claudeRepoContextEnabled
        }
    ) {
        self.settings = settings
        self.prewarm = prewarm
        self.disarm = disarm
        self.enablement = enablement
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

    private var isEnabled: Bool { enablement(settings) }

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
                } else if self.wasEnabled, !enabled {
                    // Consent is only ever asked for a feature that is ON.
                    self.disarm()
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
/// Automation consent sheet, and the sheet lives exactly as long as that
/// pending event: macOS dismisses it when the event times out (field bug
/// 2026-07-22 — the iTerm2 prompt vanished after the read script's 1 s
/// timeout, before the user could answer). So the probe sent here uses
/// `consentPrewarmScriptSource` — the same focused-pane question under a
/// timeout long enough for a human to answer — on its OWN serial executor,
/// so a sheet parked for minutes never queues behind-the-scenes dictation
/// reads (which abstain unaided until consent exists anyway). It fires once
/// per terminal, at launch, when a relevant setting is enabled, or as soon as
/// that terminal launches, with the result discarded: the sheet appears at a
/// moment when nothing is in flight, and every later per-start read finds
/// consent already settled.
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
    private static var probeExecutors: [String: TerminalAppleScriptSerialExecutor] = [:]

    /// Sends the long-timeout consent probe for `bundleID` on a dedicated
    /// executor and logs how consent settled. Result text is discarded — this
    /// exists only to park in the sheet so the user can answer it.
    static func performConsentProbe(bundleID: String) async {
        // The probe is the app's REAL question under a human-answerable
        // timeout, so it is looked up from the same tables the dictation path
        // uses: the focused-pane tty for a terminal, the focused tab's URL for
        // a browser. The two allowlists are disjoint, so at most one answers.
        guard
            let source = AppleScriptTerminalTTYReader.consentPrewarmScriptSource(
                forBundleID: bundleID
            ) ?? AppleScriptFocusedBrowserTabURLReader.consentPrewarmScriptSource(
                forBundleID: bundleID
            )
        else { return }
        let executor: TerminalAppleScriptSerialExecutor
        if let existing = probeExecutors[bundleID] {
            executor = existing
        } else {
            executor = TerminalAppleScriptSerialExecutor(
                source: source,
                queueLabel: "com.localvoxtral.terminal-consent-prewarm.\(bundleID)"
            )
            probeExecutors[bundleID] = executor
        }
        switch await executor.execute() {
        case .failure(let code) where code == -1743:
            Log.claudeContext.info(
                "Automation consent declined for \(bundleID, privacy: .public) — grant localvoxtral in System Settings > Privacy > Automation"
            )
        case .failure(let code):
            Log.claudeContext.info(
                "Consent pre-warm probe for \(bundleID, privacy: .public) ended without a grant decision (AppleScript error \(code, privacy: .public))"
            )
        case .success:
            Log.claudeContext.info(
                "Automation consent settled for \(bundleID, privacy: .public)"
            )
        }
    }

    /// Fires the pre-warm now when `bundleID`'s app is running, otherwise arms
    /// a one-shot launch observer that fires it when the app appears.
    ///
    /// `isTerminalRunning`/`execute` default to the live checks for
    /// `bundleID`; tests always inject both (a defaulted execute sends a real
    /// Apple event).
    ///
    /// - Parameter isStillEnabled: re-read at FIRE time, not just at arm time.
    ///   A pending launch observer outlives the setting that armed it — enable
    ///   a context feature while the browser is closed, turn it back off, open
    ///   the browser — and the sheet it would raise is for a feature the user
    ///   has switched off (review finding, codex on PR #218). The app also
    ///   cancels pending observers on disable (`cancelPendingPrewarm`); this is
    ///   the second, independent defence, because a notification already in
    ///   flight cannot be cancelled.
    static func fireOnceWhenTerminalIsAvailable(
        bundleID: String,
        isTerminalRunning: (@MainActor @Sendable () -> Bool)? = nil,
        isStillEnabled: (@MainActor @Sendable () -> Bool)? = nil,
        execute: (@MainActor @Sendable () async -> Void)? = nil,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        let isRunning = isTerminalRunning ?? {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).isEmpty
        }
        let isEnabled = isStillEnabled ?? { true }
        let execute = execute ?? {
            await performConsentProbe(bundleID: bundleID)
        }
        guard !firedBundleIDs.contains(bundleID), launchObservers[bundleID] == nil else { return }
        if isRunning() {
            fire(bundleID: bundleID, isRunning: isRunning, isEnabled: isEnabled, execute)
            return
        }
        observedCenters[bundleID] = notificationCenter
        launchObservers[bundleID] = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !firedBundleIDs.contains(bundleID), isEnabled(), isRunning() else { return }
                removeObserver(bundleID: bundleID)
                fire(bundleID: bundleID, isRunning: isRunning, isEnabled: isEnabled, execute)
            }
        }
    }

    /// Disarms a pre-warm that is waiting for `bundleID` to launch.
    ///
    /// Called when the setting that armed it goes off. Deliberately does NOT
    /// mark the bundle as fired: cancelling is not "already consented", so
    /// re-enabling the feature in the same app run can arm it again.
    static func cancelPendingPrewarm(bundleID: String) {
        guard launchObservers[bundleID] != nil else { return }
        removeObserver(bundleID: bundleID)
        Log.claudeContext.info(
            "Automation consent pre-warm for \(bundleID, privacy: .public) disarmed (feature turned off)"
        )
    }

    private static func fire(
        bundleID: String,
        isRunning: @escaping @MainActor @Sendable () -> Bool,
        isEnabled: @escaping @MainActor @Sendable () -> Bool,
        _ execute: @escaping @MainActor @Sendable () async -> Void
    ) {
        firedBundleIDs.insert(bundleID)
        // A Task, not an inline call: the pre-warm can park in the consent
        // sheet, and the caller (broker startup) must not wait on that.
        Task { @MainActor in
            // Both conditions are re-read here, as late as this code can read
            // them, because the arming checks are separated from the Apple
            // event by an actor hop:
            // * the setting can have been switched off in between;
            // * the app can have QUIT in between, and `tell application id`
            //   LAUNCHES a non-running app — the one thing a background
            //   pre-warm must never do.
            // Residual window: the hop from here into the executor's queue is
            // still not atomic with the app's lifetime, so a quit inside those
            // microseconds can still relaunch it. NSAppleScript has no
            // "address this pid only" mode, so that last gap cannot be closed
            // from this side; it is narrowed from "arbitrarily long wait for a
            // launch notification" to one queue hop.
            guard isEnabled(), isRunning() else {
                // Not fired after all: un-mark it so a later launch (or a
                // re-enable) can still pre-warm this app in this run.
                firedBundleIDs.remove(bundleID)
                Log.claudeContext.info(
                    "Automation consent pre-warm for \(bundleID, privacy: .public) skipped (app or feature no longer available)"
                )
                return
            }
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
