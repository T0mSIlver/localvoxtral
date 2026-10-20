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
        /// Install, update or remove the mod plugin
        /// (`ClaudePluginAssets.modPluginName`). Every flow runs these
        /// best-effort, after or before the plugin's own step: the mod needs a
        /// Claude Code build that loads mods, and its failure must never cost
        /// the context hooks.
        case installMod
        case updateMod
        case uninstallMod
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
    package static let maxCapturedOutputBytes = 64 * 1024

    /// How long a child gets to honour SIGTERM before it is SIGKILLed.
    ///
    /// Bounded because SIGTERM is advisory. A child that installs a handler and
    /// ignores it — or that is blocked writing into a pipe nobody drains any
    /// more, which is exactly what the output cap creates — would otherwise hold
    /// the caller forever on the wait that follows, reinstating the wedge the
    /// timeout exists to prevent.
    public static let terminationGracePeriod: TimeInterval = 2

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

    /// Where a failure the flow goes on past is logged: a mod step, a
    /// listing. Injected so tests read it back. Its lines name a step and an
    /// exit code or a runner failure, never CLI output or arguments.
    public typealias FailureLog = @Sendable (String) -> Void

    private let claudeExecutableURL: URL?
    private let marketplaceURL: URL?
    /// The app-owned mirror, and the ONLY path a repair may register. Nil
    /// disables repair rather than letting it fall back to the bundle.
    private let repairMarketplaceURL: URL?
    private let publisherURL: URL?
    private let runner: Runner
    private let logFailure: FailureLog

    public init(
        claudeExecutableURL: URL?,
        marketplaceURL: URL?,
        repairMarketplaceURL: URL? = nil,
        publisherURL: URL? = nil,
        runner: @escaping Runner,
        logFailure: FailureLog? = nil
    ) {
        self.claudeExecutableURL = claudeExecutableURL
        self.marketplaceURL = marketplaceURL
        self.repairMarketplaceURL = repairMarketplaceURL
        self.publisherURL = publisherURL
        self.runner = runner
        self.logFailure = logFailure ?? { Log.backends.notice("\($0, privacy: .public)") }
    }

    /// Fully-qualified plugin reference, e.g. `localvoxtral@localvoxtral`.
    public static var pluginReference: String {
        "\(ClaudePluginAssets.pluginName)@\(ClaudePluginAssets.marketplaceName)"
    }

    /// `localvoxtral-mod@localvoxtral`.
    public static var modPluginReference: String {
        "\(ClaudePluginAssets.modPluginName)@\(ClaudePluginAssets.marketplaceName)"
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
        case .installMod:
            return ["plugin", "install", modPluginReference] + configArguments(publisherPath: publisherPath)
        case .updateMod:
            return ["plugin", "update", modPluginReference]
        case .uninstallMod:
            return ["plugin", "uninstall", modPluginReference]
        }
    }

    package static func configArguments(publisherPath: String?) -> [String] {
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
        try listing("marketplace list", arguments: ["plugin", "marketplace", "list", "--json"])
    }

    /// Invocations whose output is PARSED rather than shown, and which must
    /// therefore reach the caller whole. The display cap exists so a chatty
    /// failure cannot become a wall of text in an alert; applied to JSON it
    /// silently truncates a document into an undecodable one, and every
    /// decision taken from that document quietly stops being taken (review,
    /// 2026-09-21).
    package static func isMachineReadable(_ invocation: Invocation) -> Bool {
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
        try listing("plugin list", arguments: ["plugin", "list", "--json"])
    }

    /// A listing's stdout, nil when it ran and failed. Either failure is
    /// logged: the callers turn both into an unknown status (#1690).
    private func listing(_ name: String, arguments: [String]) throws -> String? {
        guard claudeExecutableURL != nil else { return nil }
        let result: RunResult
        do {
            result = try runner(Invocation(arguments: arguments))
        } catch {
            logFailure("Claude plugin: `\(name)` failed (\(Self.describe(error))); status unknown")
            throw error
        }
        guard result.succeeded else {
            logFailure("Claude plugin: `\(name)` exited \(result.exitCode); status unknown")
            return nil
        }
        return result.message
    }

    /// A mod step: best-effort, so its failure never fails the flow, but
    /// logged, so a missing mod has a reason in the log (#1689).
    private func performModStep(_ action: Action) {
        do {
            try perform(action)
        } catch {
            logFailure("Claude plugin: mod step \(action) failed (\(Self.describe(error))); the context hooks are unaffected")
        }
    }

    /// A failure as an exit code or a kind of runner failure: never the
    /// CLI's output or arguments.
    private static func describe(_ error: Error) -> String {
        switch error as? ServiceError {
        case .commandFailed(_, let exitCode, _): "exit \(exitCode)"
        case .commandTimedOut(_, _, let seconds): "timed out after \(Int(seconds)) s"
        case .outputTooLarge: "output over the cap"
        case .claudeCLINotFound: "claude not found"
        case .marketplaceUnavailable: "marketplace missing"
        case nil: "\(type(of: error))"
        }
    }

    /// The user-facing install: register the marketplace, then install. Both
    /// steps are required and the first is idempotent in Claude Code.
    public func installPlugin() throws {
        try perform(.addMarketplace)
        try perform(.install)
        performModStep(.installMod)
    }

    /// The user-facing uninstall. The marketplace is deregistered too so we
    /// leave nothing of ours behind in the user's Claude Code config.
    public func uninstallPlugin() throws {
        performModStep(.uninstallMod)
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
        performModStep(.uninstallMod)
        performModStep(.installMod)
    }

    /// The unattended update at launch: refresh the marketplace, then
    /// `claude plugin update`.
    ///
    /// Never uninstalls, so a failure leaves the old plugin installed and
    /// working. Claude Code keeps the old version's files for sessions
    /// already running, and the saved `publisher_path` carries over. That pin
    /// is not refreshed, which is why the shim tries the app's publisher link
    /// (`ClaudePublisherPointer`) first.
    ///
    /// The mod is updated only where it is installed: `plugin update` on a
    /// plugin that is not installed fails, and that failure is only logged,
    /// so the unattended path never installs it.
    public func updateInstalledPlugin() throws {
        try perform(.addMarketplace)
        try perform(.update)
        performModStep(.updateMod)
    }
}

#if canImport(Darwin) || canImport(Glibc)
public extension ClaudePluginInstallService {
    /// Production wiring: the real `claude`, the bundled marketplace, and a
    /// subprocess runner.
    package static func live() -> ClaudePluginInstallService {
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
    package static func claudeCLICandidates(environment: [String: String]) -> [String] {
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
    package static func locateClaudeCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        for candidate in claudeCLICandidates(environment: environment) where isExecutable(candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Runs the CLI noninteractively through `BoundedProcess`: stdin is
    /// /dev/null so a command that would prompt fails fast instead of hanging
    /// a GUI app, no TTY is attached, and stderr joins stdout so a failure
    /// says why.
    package static func processRunner(
        executableURL: URL?,
        timeout: TimeInterval = defaultCommandTimeout,
        gracePeriod: TimeInterval = terminationGracePeriod,
        children: BoundedProcessChildren = .shared
    ) -> Runner {
        { invocation in
            guard let executableURL else { throw ServiceError.claudeCLINotFound }
            let output = try BoundedProcess.runSynchronously(
                executableURL: executableURL,
                arguments: invocation.arguments,
                environment: nil,
                mergingStandardError: true,
                timeoutSeconds: timeout,
                maxBytes: maxCapturedOutputBytes,
                gracePeriod: gracePeriod,
                label: "claude CLI",
                children: children
            )
            // Distinct on purpose: a verbose but healthy CLI overran the cap,
            // it did not hang.
            if output.timedOut {
                throw ServiceError.commandTimedOut(
                    action: nil, arguments: invocation.arguments, seconds: timeout
                )
            }
            if output.capped {
                throw ServiceError.outputTooLarge(
                    arguments: invocation.arguments, capBytes: maxCapturedOutputBytes
                )
            }
            let raw = String(decoding: output.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RunResult(
                exitCode: output.exitCode,
                message: isMachineReadable(invocation) ? raw : String(raw.prefix(2_000))
            )
        }
    }
}
#endif
