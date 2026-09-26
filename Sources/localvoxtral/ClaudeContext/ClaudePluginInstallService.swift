import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Drives `claude plugin …` on the user's behalf.
///
/// Two rules define this type, and both are deliberate:
///
/// 1. **Install/uninstall goes through Claude Code's own CLI.** We never write
///    `~/.claude/settings.json`, never wrap it, never merge into it. That file
///    is the user's, Claude Code owns its schema, and a third-party app editing
///    it is how you corrupt someone's setup during an unrelated upgrade. The
///    CLI is the supported interface; if it is absent, we do nothing and say so.
/// 2. **Installing is the user's decision.** Only an explicit request installs
///    the plugin. The one call made without a click is the launch-time update
///    of a plugin the user already installed and that is older than the
///    bundled one (`ClaudeIntegrationSettingsModel.updateOutdatedPluginAtLaunch`).
public struct ClaudePluginInstallService: Sendable {
    public enum Action: Sendable, Equatable {
        /// Register the bundled marketplace directory.
        case addMarketplace
        /// Install the plugin from the registered marketplace.
        case install
        /// Update the installed plugin in place from the registered
        /// marketplace. Keeps its userConfig; accepts no `--config`.
        case update
        /// Remove the plugin.
        case uninstall
        /// Deregister the marketplace.
        case removeMarketplace
    }

    /// One CLI invocation.
    public struct Invocation: Sendable, Equatable {
        public var arguments: [String]

        public init(arguments: [String]) {
            self.arguments = arguments
        }
    }

    /// Result of running a command.
    public struct RunResult: Sendable, Equatable {
        public var exitCode: Int32
        /// Trimmed and length-capped. Surfaced in alerts/logs, never in the
        /// menu bar popover (owner rule: no long text there).
        public var message: String

        public init(exitCode: Int32, message: String) {
            self.exitCode = exitCode
            self.message = message
        }

        public var succeeded: Bool { exitCode == 0 }
    }

    public enum ServiceError: Error, Equatable {
        /// `claude` is not on PATH — the user does not have Claude Code, or it
        /// is not exposed to a GUI app's environment.
        case claudeCLINotFound
        /// The bundled marketplace is missing from the app bundle.
        case marketplaceUnavailable
        case commandFailed(action: Action, exitCode: Int32, message: String)
        /// The CLI did not finish inside the timeout and was terminated.
        /// `action` is nil when the runner itself timed out before the service
        /// could attribute the call.
        case commandTimedOut(action: Action?, arguments: [String], seconds: TimeInterval)
        /// The CLI produced more output than `maxCapturedOutputBytes` and was
        /// terminated. Distinct from `commandTimedOut` on purpose: a verbose but
        /// healthy CLI overran the capture cap, it did NOT hang — conflating the
        /// two makes a chatty command look like a wedged one.
        case outputTooLarge(arguments: [String], capBytes: Int)
    }

    /// Ceiling for one `claude plugin …` call. Generous — a marketplace add can
    /// fetch — but finite, so a wedged CLI cannot wedge the app.
    public static let defaultCommandTimeout: TimeInterval = 60

    /// Cap on captured CLI output. We only ever show a short failure summary.
    static let maxCapturedOutputBytes = 64 * 1024

    /// How long a child gets to honour SIGTERM before it is SIGKILLed.
    ///
    /// Bounded because SIGTERM is advisory. A child that installs a handler and
    /// ignores it — or that is blocked writing into a pipe nobody drains any
    /// more, which is exactly what the output cap creates — would otherwise hold
    /// the caller forever on the wait that follows, reinstating the wedge the
    /// timeout exists to prevent.
    public static let terminationGracePeriod: TimeInterval = 2

    /// What it took to stop a child.
    enum TerminationOutcome: Sendable, Equatable {
        /// Exited inside the grace period after SIGTERM. Nothing was killed.
        case exitedOnTerminate
        /// Outlived SIGTERM; SIGKILL ended it and it was reaped.
        case killed
        /// Still not gone after SIGKILL and a second grace period (a child stuck
        /// in an uninterruptible wait). We stop waiting — blocking past this
        /// point is the wedge, and the OS finishes the kill without us.
        case abandonedAfterKill
    }

    /// SIGTERM, bounded wait, SIGKILL, bounded wait. No unbounded wait anywhere.
    ///
    /// Every seam is injected so the TERM-ignoring path is provable without a
    /// real process or a real clock: `waitForExit` returns true when the child
    /// exited inside the window it was given.
    static func terminateBounded(
        gracePeriod: TimeInterval,
        terminate: () -> Void,
        kill: () -> Void,
        waitForExit: (TimeInterval) -> Bool
    ) -> TerminationOutcome {
        terminate()
        if waitForExit(gracePeriod) { return .exitedOnTerminate }
        kill()
        if waitForExit(gracePeriod) { return .killed }
        return .abandonedAfterKill
    }

    /// userConfig key the plugin declares, and the publisher path we pass for
    /// it at install time.
    ///
    /// The shim reads this back as `CLAUDE_PLUGIN_OPTION_PUBLISHER_PATH`. It is
    /// what lets the plugin find a publisher in a non-standard location — an
    /// app in `~/Applications`, a `/Volumes` mount, a dev build — instead of
    /// only the two hardcoded paths the shim can guess at.
    public static let publisherPathConfigKey = "publisher_path"

    /// Injected so tests never spawn a real process.
    public typealias Runner = @Sendable (Invocation) throws -> RunResult

    private let claudeExecutableURL: URL?
    private let marketplaceURL: URL?
    /// The app-owned mirror, and the ONLY path a repair may register. Nil
    /// disables repair rather than letting it fall back to the bundle.
    private let repairMarketplaceURL: URL?
    private let publisherURL: URL?
    private let runner: Runner

    public init(
        claudeExecutableURL: URL?,
        marketplaceURL: URL?,
        repairMarketplaceURL: URL? = nil,
        publisherURL: URL? = nil,
        runner: @escaping Runner
    ) {
        self.claudeExecutableURL = claudeExecutableURL
        self.marketplaceURL = marketplaceURL
        self.repairMarketplaceURL = repairMarketplaceURL
        self.publisherURL = publisherURL
        self.runner = runner
    }

    /// Fully-qualified plugin reference, e.g. `localvoxtral@localvoxtral`.
    public static var pluginReference: String {
        "\(ClaudePluginAssets.pluginName)@\(ClaudePluginAssets.marketplaceName)"
    }

    /// The argv for an action. Pure and public so tests pin the exact commands
    /// — this is the surface where a typo silently uninstalls the wrong thing.
    ///
    /// - Parameter publisherPath: when present, installs pass it as the
    ///   plugin's `publisher_path` userConfig so the shim can find a publisher
    ///   anywhere — not just the two locations it hardcodes.
    public static func arguments(
        for action: Action,
        marketplacePath: String,
        publisherPath: String? = nil
    ) -> [String] {
        switch action {
        case .addMarketplace:
            return ["plugin", "marketplace", "add", marketplacePath]
        case .install:
            return ["plugin", "install", pluginReference] + configArguments(publisherPath: publisherPath)
        case .update:
            return ["plugin", "update", pluginReference]
        case .uninstall:
            return ["plugin", "uninstall", pluginReference]
        case .removeMarketplace:
            return ["plugin", "marketplace", "remove", ClaudePluginAssets.marketplaceName]
        }
    }

    static func configArguments(publisherPath: String?) -> [String] {
        guard let publisherPath, !publisherPath.isEmpty else { return [] }
        return ["--config", "\(publisherPathConfigKey)=\(publisherPath)"]
    }

    @discardableResult
    public func perform(_ action: Action, marketplacePath: String? = nil) throws -> RunResult {
        guard claudeExecutableURL != nil else { throw ServiceError.claudeCLINotFound }
        guard let path = marketplacePath ?? marketplaceURL?.path else {
            throw ServiceError.marketplaceUnavailable
        }

        let invocation = Invocation(
            arguments: Self.arguments(
                for: action,
                marketplacePath: path,
                publisherPath: publisherURL?.path
            )
        )
        let result = try runner(invocation)
        guard result.succeeded else {
            throw ServiceError.commandFailed(
                action: action,
                exitCode: result.exitCode,
                message: result.message
            )
        }
        return result
    }

    /// stdout of `claude plugin marketplace list --json`: where Claude Code
    /// will look for our marketplace at the next session start.
    ///
    /// Read, never assumed. The path Claude Code holds is the path it was
    /// registered with once, which is not necessarily where this app lives now
    /// — that gap is the whole reason the mirror exists.
    public func marketplaceListOutput() throws -> String? {
        guard claudeExecutableURL != nil else { return nil }
        let result = try runner(Invocation(arguments: ["plugin", "marketplace", "list", "--json"]))
        return result.succeeded ? result.message : nil
    }

    /// Invocations whose output is PARSED rather than shown, and which must
    /// therefore reach the caller whole. The display cap exists so a chatty
    /// failure cannot become a wall of text in an alert; applied to JSON it
    /// silently truncates a document into an undecodable one, and every
    /// decision taken from that document quietly stops being taken (review,
    /// 2026-09-21).
    static func isMachineReadable(_ invocation: Invocation) -> Bool {
        invocation.arguments.contains("--json")
    }

    /// Point Claude Code's registration at the marketplace this app ships,
    /// leaving the installed plugin, its userConfig and its cache alone.
    ///
    /// `marketplace add` on a name that is already registered REPLACES its
    /// path and exits 0 (verified against Claude Code 2.1.x on a live install,
    /// with the old path deleted and with it present). No remove first:
    /// `marketplace remove` is the verb that takes the user's installed plugin
    /// with it.
    ///
    /// Registers the MIRROR or nothing. `perform` falls back to the app
    /// bundle when no mirror has materialized, which is a fair bargain for an
    /// install the user asked for — but this call exists to take a rotting
    /// path OFF the registration, and re-pinning it to a bundle inside
    /// `/private/tmp` would recreate the very failure it is repairing
    /// (review, 2026-09-21).
    public func repairMarketplaceRegistration() throws {
        guard let repairMarketplaceURL else { throw ServiceError.marketplaceUnavailable }
        try perform(.addMarketplace, marketplacePath: repairMarketplaceURL.path)
    }

    /// stdout of `claude plugin list --json` for the Integrations pane's
    /// status row.
    ///
    /// Never throws for a listing that ran and failed: that is `.unknown`,
    /// not an action the pane reports. Throws only when the runner itself
    /// fails (timeout, output cap) — the same failures `perform` surfaces.
    public func pluginListOutput() throws -> String? {
        guard claudeExecutableURL != nil else { return nil }
        let result = try runner(Invocation(arguments: ["plugin", "list", "--json"]))
        return result.succeeded ? result.message : nil
    }

    /// The user-facing install: register the marketplace, then install. Both
    /// steps are required and the first is idempotent in Claude Code.
    public func installPlugin() throws {
        try perform(.addMarketplace)
        try perform(.install)
    }

    /// The user-facing uninstall. The marketplace is deregistered too so we
    /// leave nothing of ours behind in the user's Claude Code config.
    public func uninstallPlugin() throws {
        try perform(.uninstall)
        try perform(.removeMarketplace)
    }

    /// The user-facing "Install or Update".
    ///
    /// There is no `plugin update` here because the CLI rejects `--config` on
    /// that verb, and an update that cannot re-pin `publisher_path` strands the
    /// shim on a stale path whenever the app moved — which the try-pr loop does
    /// on every artifact. Uninstall + install refreshes both the plugin files
    /// and the pin. The uninstall is best-effort so the same button serves the
    /// first-ever install (uninstalling a not-installed plugin exits 1).
    public func updatePlugin() throws {
        try perform(.addMarketplace)
        _ = try? perform(.uninstall)
        try perform(.install)
    }

    /// The unattended update at launch: refresh the marketplace, then
    /// `claude plugin update`.
    ///
    /// Never uninstalls, so a failure leaves the old plugin installed and
    /// working. Claude Code keeps the old version's files for sessions
    /// already running, and the saved `publisher_path` carries over. That pin
    /// is not refreshed, which is why the shim tries the app's publisher link
    /// (`ClaudePublisherPointer`) first.
    public func updateInstalledPlugin() throws {
        try perform(.addMarketplace)
        try perform(.update)
    }
}

#if canImport(Darwin) || canImport(Glibc)
public extension ClaudePluginInstallService {
    /// Production wiring: the real `claude`, the bundled marketplace, and a
    /// subprocess runner.
    static func live() -> ClaudePluginInstallService {
        let executable = locateClaudeCLI()
        return ClaudePluginInstallService(
            claudeExecutableURL: executable,
            // The MIRROR, not the bundle: Claude Code stores this path and
            // re-reads it at every session start, so registering a path inside
            // the app bundle pins the plugin to wherever that bundle was the
            // day it was installed (ClaudeMarketplaceMirror). The bundle is
            // the fallback for the launch that has not mirrored yet.
            marketplaceURL: ClaudeMarketplaceMirror.usableURL() ?? ClaudePluginAssets.marketplaceURL(),
            repairMarketplaceURL: ClaudeMarketplaceMirror.usableURL(),
            // Tell the plugin exactly where THIS app's publisher lives, so the
            // shim works from /Applications, ~/Applications, a dev build, or a
            // mounted volume without guessing.
            publisherURL: ClaudePluginAssets.publisherURL(),
            runner: Self.processRunner(executableURL: executable)
        )
    }

    /// Where `claude` might live, in probe order.
    ///
    /// A GUI app's PATH is not the user's shell PATH, so the usual install
    /// locations are probed explicitly rather than relying on `which`. Pure and
    /// separate from the filesystem so the ordering is testable on its own.
    static func claudeCLICandidates(environment: [String: String]) -> [String] {
        var candidates: [String] = []
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append("\(home)/.claude/local/claude")
            candidates.append("\(home)/.local/bin/claude")
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                candidates.append("\(directory)/claude")
            }
        }
        candidates.append("/opt/homebrew/bin/claude")
        candidates.append("/usr/local/bin/claude")
        return candidates
    }

    /// First candidate that is actually executable.
    ///
    /// `isExecutable` is injected so tests can probe the ordering without
    /// depending on whether the host machine happens to have Claude Code
    /// installed — on the build host it does, which would make a
    /// "returns nil when absent" test pass or fail by accident.
    static func locateClaudeCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        for candidate in claudeCLICandidates(environment: environment) where isExecutable(candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Runs the CLI noninteractively: stdin is /dev/null so a command that
    /// would prompt fails fast instead of hanging a GUI app forever, and no
    /// TTY is attached.
    ///
    /// Two things here are load-bearing:
    ///
    /// * **`POSIXPipeRead`, not `readDataToEndOfFile`/`availableData`.** Every
    ///   `FileHandle` read raises an uncatchable ObjC exception on descriptor
    ///   errors and takes the app down with it (field crash, PR #60). The rule
    ///   is repo-wide and has no exception for "but this pipe is well-behaved".
    /// * **A timeout.** `readDataToEndOfFile` blocks until the child closes the
    ///   pipe, and `waitUntilExit()` blocks until it dies. A `claude` that hangs
    ///   — waiting on a network fetch, or on a prompt we did not anticipate —
    ///   would wedge the caller with no way out. The child is terminated and
    ///   the failure reported instead.
    /// * **Every wait is bounded, including the teardown's.** `terminate()` only
    ///   sends SIGTERM, which a child is free to ignore — and one that does,
    ///   while blocked writing into the pipe we stopped draining at the output
    ///   cap, never comes back. So the wait after it is a grace period, not
    ///   `waitUntilExit()`, and SIGKILL follows. Exit is observed through
    ///   `terminationHandler`, so no path here waits without a deadline.
    static func processRunner(
        executableURL: URL?,
        timeout: TimeInterval = defaultCommandTimeout,
        gracePeriod: TimeInterval = terminationGracePeriod
    ) -> Runner {
        { invocation in
            guard let executableURL else { throw ServiceError.claudeCLINotFound }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = invocation.arguments
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            // Armed before run() so the exit can never be missed, and read
            // through a semaphore so every wait below can carry a deadline.
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()

            /// True when the child exited inside `window`.
            func waitForExit(_ window: TimeInterval) -> Bool {
                exited.wait(timeout: .now() + max(window, 0)) == .success
            }

            func stopChild() {
                _ = terminateBounded(
                    gracePeriod: gracePeriod,
                    terminate: { process.terminate() },
                    kill: {
                        // Only signal a child Foundation has not reaped yet:
                        // once reaped, the pid can be recycled onto an innocent
                        // process. isRunning is false only after collection.
                        let pid = process.processIdentifier
                        if pid > 0, process.isRunning { _ = LibC.kill(pid, SIGKILL) }
                    },
                    waitForExit: waitForExit
                )
            }

            // Why the child was torn down, so a verbose-but-healthy CLI is not
            // reported as a hang. Both reasons take the identical teardown; only
            // the error thrown differs.
            enum StopReason { case timedOut, outputTooLarge }

            let descriptor = output.fileHandleForReading.fileDescriptor
            let deadline = Date().addingTimeInterval(timeout)
            var collected = Data()
            var stopReason: StopReason?

            // Drain until EOF. The child holds the only other write end, so EOF
            // arrives when it exits — which is also how we learn it is done.
            //
            // Each read is gated on poll(): `POSIXPipeRead.nextChunk` blocks
            // until bytes arrive, so checking the deadline only between chunks
            // would never fire for the case that matters most — a child that
            // hangs without printing anything.
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    stopReason = .timedOut
                    break
                }
                var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptorPoll, 1, Int32(remaining * 1000))
                if ready < 0 {
                    if errno == EINTR { continue }
                    break // Treat an unusable pipe as EOF, per POSIXPipeRead.
                }
                if ready == 0 {
                    stopReason = .timedOut
                    break
                }
                let chunk = POSIXPipeRead.nextChunk(fromDescriptor: descriptor)
                if chunk.isEmpty { break } // EOF or read error: both mean stop.
                collected.append(chunk)
                if collected.count > maxCapturedOutputBytes {
                    // Stop reading and tear the child down. Nothing drains the
                    // pipe after this, so a child that keeps writing blocks in
                    // the kernel on a full buffer — and if it also ignores
                    // SIGTERM it stays there. Hence the SIGKILL escalation. But
                    // this is an overrun, not a hang — the distinct reason keeps
                    // the two apart at the throw site below.
                    stopReason = .outputTooLarge
                    break
                }
            }

            if stopReason == nil {
                // EOF is not proof of exit — a child can close its pipes and
                // live on — so this wait carries the same deadline as the drain
                // rather than blocking on waitUntilExit().
                if !waitForExit(deadline.timeIntervalSinceNow) { stopReason = .timedOut }
            }

            if let stopReason {
                stopChild()
                switch stopReason {
                case .timedOut:
                    throw ServiceError.commandTimedOut(
                        action: nil, arguments: invocation.arguments, seconds: timeout
                    )
                case .outputTooLarge:
                    throw ServiceError.outputTooLarge(
                        arguments: invocation.arguments, capBytes: maxCapturedOutputBytes
                    )
                }
            }

            let raw = String(decoding: collected, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RunResult(
                exitCode: process.terminationStatus,
                message: isMachineReadable(invocation) ? raw : String(raw.prefix(2_000))
            )
        }
    }
}
#endif
