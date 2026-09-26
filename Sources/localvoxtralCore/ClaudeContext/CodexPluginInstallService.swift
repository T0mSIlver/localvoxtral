import Foundation

/// Installs the localvoxtral Codex plugin through Codex's own CLI.
///
/// A plugin rather than an entry in `~/.codex/hooks.json`, for the trust gate.
/// Codex runs a hook only after the user trusts it, and records that trust
/// under a key and a hash (measured on 0.156.0, `hooks/src/engine/discovery.rs`):
///
/// * the key of a `hooks.json` entry is the file path plus the entry's
///   POSITION (`…/hooks.json:session_start:1:0`). herdr writes that file too,
///   so any edit that moves our entry would silently untrust it. A plugin's
///   key is `localvoxtral@localvoxtral:hooks/hooks.json:<event>:0:0`, which
///   nothing else can shift.
/// * the hash covers the event, matcher and handler as declared (command
///   string before `$PLUGIN_ROOT` expands, timeout), not the script the
///   command runs. So a new plugin version with the same `hooks.json` keeps
///   its trust (measured: 0.0.1 → 0.0.2 with a changed shim stayed trusted),
///   and a changed `hooks.json` asks again. Keep `hooks/hooks.json`
///   byte-stable unless the hooks themselves must change.
///
/// Like `ClaudePluginInstallService`, this never writes Codex's files itself:
/// the CLI does, and only when the user asks.
public struct CodexPluginInstallService: Sendable {
    public typealias Invocation = ClaudePluginInstallService.Invocation
    public typealias RunResult = ClaudePluginInstallService.RunResult
    public typealias Runner = ClaudePluginInstallService.Runner

    public static let pluginName = "localvoxtral"
    public static let marketplaceName = "localvoxtral"
    public static var pluginReference: String { "\(pluginName)@\(marketplaceName)" }

    public enum Status: Sendable, Equatable {
        /// The CLI is missing, or its listing failed.
        case unknown
        case notInstalled
        /// Installed but turned off in Codex.
        case disabled
        case installed
        /// Installed at another version than this build's.
        case updateAvailable
    }

    public enum ServiceError: Error, Equatable, CustomStringConvertible {
        case codexCLINotFound
        case marketplaceUnavailable
        case commandFailed(arguments: [String], exitCode: Int32, message: String)

        public var description: String {
            switch self {
            case .codexCLINotFound:
                return "Codex was not found. Install the Codex CLI, then try again."
            case .marketplaceUnavailable:
                return "This build's Codex plugin files are missing."
            case .commandFailed(let arguments, let exitCode, let message):
                let command = (["codex"] + arguments).joined(separator: " ")
                return "`\(command)` exited with \(exitCode). \(message)"
            }
        }
    }

    private let codexExecutableURL: URL?
    private let marketplaceURL: URL?
    private let runner: Runner

    public init(codexExecutableURL: URL?, marketplaceURL: URL?, runner: @escaping Runner) {
        self.codexExecutableURL = codexExecutableURL
        self.marketplaceURL = marketplaceURL
        self.runner = runner
    }

    // MARK: - Status

    public func status(bundledVersion: String?) -> Status {
        guard codexExecutableURL != nil,
              let result = try? runner(Invocation(arguments: Self.listArguments)),
              result.succeeded
        else { return .unknown }
        return Self.status(listOutput: result.message, bundledVersion: bundledVersion)
    }

    static let listArguments = ["plugin", "list", "--json", "--marketplace", marketplaceName]

    /// Reads `codex plugin list --json`: `{"installed": [{"pluginId", "version",
    /// "installed", "enabled", …}], …}` (0.156.0).
    package static func status(listOutput: String, bundledVersion: String?) -> Status {
        guard let object = try? JSONSerialization.jsonObject(with: Data(listOutput.utf8)),
              let listing = object as? [String: Any],
              let installed = listing["installed"] as? [[String: Any]]
        else { return .unknown }
        guard let entry = installed.first(where: { $0["pluginId"] as? String == pluginReference }),
              entry["installed"] as? Bool != false
        else { return .notInstalled }
        if entry["enabled"] as? Bool == false { return .disabled }
        if let bundledVersion, let version = entry["version"] as? String, version != bundledVersion {
            return .updateAvailable
        }
        return .installed
    }

    // MARK: - Mutations (the user's explicit request)

    /// Register the marketplace, then install or refresh the plugin. The same
    /// call updates: `plugin add` over an installed plugin installs this
    /// build's version.
    ///
    /// `marketplace add` refuses a name already registered from another path
    /// ("remove it before adding this source"), which is where an install from
    /// a dev build or an older bundle leaves it. Removing the marketplace
    /// keeps the installed plugin and its trust, so it is removed and added
    /// again from here.
    public func install() throws {
        guard codexExecutableURL != nil else { throw ServiceError.codexCLINotFound }
        guard let marketplaceURL else { throw ServiceError.marketplaceUnavailable }
        let add = ["plugin", "marketplace", "add", marketplaceURL.path]
        let first = try runner(Invocation(arguments: add))
        if !first.succeeded {
            guard first.message.contains(Self.otherSourceRefusal) else {
                throw ServiceError.commandFailed(arguments: add, exitCode: first.exitCode, message: first.message)
            }
            try run(["plugin", "marketplace", "remove", Self.marketplaceName])
            try run(add)
        }
        try run(["plugin", "add", Self.pluginReference])
        Log.claudeContext.info("Codex plugin install completed")
    }

    /// What `marketplace add` prints, with exit 1, for a name registered
    /// from another path (0.156.0).
    static let otherSourceRefusal = "already added from a different source"

    /// Remove the plugin, then the marketplace. Codex keeps the hooks' trust
    /// records, so a later install of the same hooks runs without asking.
    public func remove() throws {
        guard codexExecutableURL != nil else { throw ServiceError.codexCLINotFound }
        try run(["plugin", "remove", Self.pluginReference])
        try run(["plugin", "marketplace", "remove", Self.marketplaceName])
        Log.claudeContext.info("Codex plugin remove completed")
    }

    private func run(_ arguments: [String]) throws {
        let result = try runner(Invocation(arguments: arguments))
        guard result.succeeded else {
            Log.claudeContext.error(
                "Codex CLI failed: \(arguments.joined(separator: " "), privacy: .public) exited \(result.exitCode, privacy: .public)"
            )
            throw ServiceError.commandFailed(arguments: arguments, exitCode: result.exitCode, message: result.message)
        }
    }
}

#if canImport(Darwin) || canImport(Glibc)
public extension CodexPluginInstallService {
    /// Production wiring: the real `codex`, the app-owned marketplace mirror
    /// (the bundle only before the first launch has mirrored it), and the
    /// same bounded subprocess runner the Claude Code plugin uses.
    package static func live() -> CodexPluginInstallService {
        let executable = locateCodexCLI()
        return CodexPluginInstallService(
            codexExecutableURL: executable,
            marketplaceURL: CodexPluginAssets.usableMirrorURL() ?? CodexPluginAssets.marketplaceURL(),
            runner: ClaudePluginInstallService.processRunner(executableURL: executable)
        )
    }

    /// Where `codex` might live, in probe order. A GUI app's PATH is not the
    /// user's shell PATH, so the usual install locations come first: the
    /// standalone installer's `~/.local/bin`, Homebrew, then npm's prefixes.
    package static func codexCLICandidates(environment: [String: String]) -> [String] {
        var candidates: [String] = []
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append("\(home)/.local/bin/codex")
            candidates.append("\(home)/.npm-global/bin/codex")
        }
        candidates.append("/opt/homebrew/bin/codex")
        candidates.append("/usr/local/bin/codex")
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                candidates.append("\(directory)/codex")
            }
        }
        return candidates
    }

    package static func locateCodexCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        codexCLICandidates(environment: environment).first(where: isExecutable).map {
            URL(fileURLWithPath: $0)
        }
    }
}
#endif

/// Locates the bundled Codex marketplace (`integrations/codex` in the repo,
/// `Contents/Resources/codex-marketplace` in the app) and its mirror.
///
/// Codex reads a local marketplace IN PLACE from the path it was added with,
/// so registering the app bundle would pin the plugin to wherever that bundle
/// was on install day, the failure `ClaudeMarketplaceMirror` exists for. The
/// app copies the bundled tree to a fixed path on every launch and registers
/// that.
public enum CodexPluginAssets {
    public static let packagedDirectoryName = "codex-marketplace"
    public static let repositoryRelativePath = "integrations/codex"
    public static let mirrorHomeRelativePath = "Library/Application Support/localvoxtral/codex/marketplace"

    public static func marketplaceURL(resourcesURL: URL? = Bundle.main.resourceURL) -> URL? {
        if let resourcesURL {
            let packaged = resourcesURL.appendingPathComponent(packagedDirectoryName)
            if isMarketplace(packaged) { return packaged }
        }
        let development = ClaudePluginAssets.repositoryRootURL(sourceFile: ClaudePluginAssets.assetsSourceFile)?
            .appendingPathComponent(repositoryRelativePath)
        if let development, isMarketplace(development) { return development }
        return nil
    }

    public static func isMarketplace(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".agents/plugins/marketplace.json").path
        )
    }

    public static func mirrorURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(mirrorHomeRelativePath)
    }

    public static func usableMirrorURL(mirrorURL: URL = mirrorURL()) -> URL? {
        isMarketplace(mirrorURL) ? mirrorURL : nil
    }

    /// The bundled plugin's `version`, which `codex plugin list --json` names
    /// for an install.
    public static func bundledPluginVersion(marketplaceURL: URL? = marketplaceURL()) -> String? {
        guard let marketplaceURL,
              let data = try? Data(contentsOf: marketplaceURL.appendingPathComponent(
                  "plugins/\(CodexPluginInstallService.pluginName)/.codex-plugin/plugin.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = manifest["version"] as? String, !version.isEmpty
        else { return nil }
        return version
    }
}

// MARK: - The Integrations row

extension CodexPluginInstallService.Status {
    /// The row's one status sentence. An installed plugin proves nothing
    /// until a hook runs: Codex skips an untrusted hook silently, so until
    /// `hookHeard` the sentence says the one thing left to do.
    public func sentence(hookHeard: Bool) -> String {
        switch self {
        case .unknown: return "Codex was not found."
        case .notInstalled: return "Not installed."
        case .disabled: return "Turned off in Codex's plugin list."
        case .installed, .updateAvailable:
            guard hookHeard else { return "Installed; trust its hooks when Codex next starts." }
            return self == .installed ? "Installed." : "Update available."
        }
    }

    /// Install or Update, or nil when neither would change anything.
    /// `.unknown` offers Install: the action names a missing CLI in its alert.
    public var primaryActionTitle: String? {
        switch self {
        case .unknown, .notInstalled: return "Install"
        case .updateAvailable: return "Update"
        case .installed, .disabled: return nil
        }
    }

    public var offersRemove: Bool {
        switch self {
        case .installed, .updateAvailable, .disabled: return true
        case .unknown, .notInstalled: return false
        }
    }

    /// Whether dictation joins Codex sessions: installed AND a hook ran.
    public func joins(hookHeard: Bool) -> Bool {
        hookHeard && (self == .installed || self == .updateAvailable)
    }
}

/// Whether a Codex hook has ever reached this app since the plugin was last
/// installed. The registry knows since launch; the flag carries it across
/// launches, because a user who trusted the hooks yesterday must not be told
/// to trust them again today.
public struct CodexHookHeardMemory: Sendable {
    private let registry: ClaudeSessionRegistry?
    private let load: @Sendable () -> Bool
    private let save: @Sendable (Bool) -> Void

    public init(
        registry: ClaudeSessionRegistry?,
        load: @escaping @Sendable () -> Bool,
        save: @escaping @Sendable (Bool) -> Void
    ) {
        self.registry = registry
        self.load = load
        self.save = save
    }

    public static let defaultsKey = "codexHookEventHeard"

    public func hasHeard() -> Bool {
        if registry?.hasHeard(localAgent: .codex) == true {
            if !load() { save(true) }
            return true
        }
        return load()
    }

    /// After an install or a removal: only a hook of the new install counts.
    public func reset() {
        registry?.forgetHeard(localAgent: .codex)
        save(false)
    }
}
