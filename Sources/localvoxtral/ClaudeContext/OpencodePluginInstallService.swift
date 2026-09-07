import Foundation

/// Installs the opencode plugin: copies the bundled `localvoxtral.js` into
/// opencode's global plugin directory and lists it in `tui.json`.
///
/// Two steps because opencode has two loaders: it auto-discovers
/// `plugins/*.js` for its server half, but the TUI half — which publishes
/// which session the pane displays, the half a join needs — loads only what
/// `tui.json` lists (verified on opencode 1.17.12; see the plugin README).
/// Skipping the second step leaves panes undeclared and joins impossible.
///
/// File discipline mirrors `ClaudeShellRCWriter`: preview the exact text
/// (the UI shows the `tui.json` entry), write only on explicit consent,
/// refuse symlinks at every path component, refuse unreadable files, keep an
/// existing file's mode (0600 for a new one), write atomically, and stay
/// idempotent (re-installing writes byte-identical bytes).
///
/// The plugin FILE itself is fully owned (a fixed path we manage): install
/// always writes the bundled bytes, remove always deletes it. Only
/// `tui.json` is shared with the user, and there this service touches only
/// its own `plugin` entry — every other key, and every other entry in the
/// list, round-trips untouched.
///
/// JSON choice, stated once (same as the statusline service): edits
/// round-trip through `JSONSerialization`, written pretty-printed with sorted
/// keys. Formatting normalizes; content outside our entry is preserved.
public struct OpencodePluginInstallService: Sendable {
    /// The entry this service owns inside `tui.json`'s `plugin` list, exactly
    /// as the plugin README documents it.
    public static let tuiPluginEntry = "./plugins/localvoxtral.js"
    static let tuiPluginKey = "plugin"

    /// Bundled plugin bytes. Injected so tests never touch the app bundle.
    private let bundledPluginData: @Sendable () -> Data?
    private let fileSystem: (any OpencodePluginFileSystem)?

    public init(
        bundledPluginData: @escaping @Sendable () -> Data? = { nil },
        fileSystem: (any OpencodePluginFileSystem)? = nil
    ) {
        self.bundledPluginData = bundledPluginData
        self.fileSystem = fileSystem
    }

    // MARK: - Read-only status

    public enum Status: Sendable, Equatable {
        /// No plugin file. Offers Install.
        case notInstalled
        /// The file is there but `tui.json` does not list it: content flows,
        /// panes stay undeclared, joins stay impossible.
        case installedUnlisted
        /// File copied and listed. Offers Remove (and re-Install).
        case installed
        /// A file exists but cannot be read, or `tui.json` is unparseable.
        /// Reported, never treated as absent.
        case unknown
    }

    /// The row's one status sentence. Never restates the label.
    public static func sentence(for status: Status) -> String {
        switch status {
        case .notInstalled: return "Not installed."
        case .installedUnlisted: return "Installed, not listed in tui.json."
        case .installed: return "Installed."
        case .unknown: return "Could not read your opencode config."
        }
    }

    public func status() -> Status {
        guard let fileSystem, let state = try? fileSystem.readState() else { return .unknown }
        guard state.pluginData != nil || !state.pluginFileExists else { return .unknown }
        guard state.pluginFileExists else { return .notInstalled }
        guard let tuiData = state.tuiData else {
            // No tui.json at all: listed nowhere.
            if state.tuiFileExists { return .unknown }
            return .installedUnlisted
        }
        switch Self.tuiListsPlugin(in: tuiData) {
        case .listed: return .installed
        case .notListed: return .installedUnlisted
        case .unparseable: return .unknown
        }
    }

    public enum TUIListing: Sendable, Equatable {
        case listed
        case notListed
        /// Not JSON, or `plugin` is present but not an array of strings.
        /// Refused, never "fixed": reshaping a key whose shape we do not
        /// understand is how a setup step eats a user's config.
        case unparseable
    }

    /// Pure derivation over `tui.json` bytes, so fixtures pin every shape.
    /// An ABSENT file (nil) is `.notListed`, not unparseable: creating it is
    /// exactly what install does.
    public static func tuiListsPlugin(in data: Data?) -> TUIListing {
        guard let data else { return .notListed }
        guard
            let json = try? JSONSerialization.jsonObject(with: data),
            let tui = json as? [String: Any]
        else { return .unparseable }
        guard let entries = tui[tuiPluginKey] else { return .notListed }
        // m1: `null` means unset, not misshapen — a shape JSON configs
        // routinely use, and one opencode itself could plausibly write.
        if entries is NSNull { return .notListed }
        guard let list = entries as? [String] else { return .unparseable }
        return list.contains(tuiPluginEntry) ? .listed : .notListed
    }

    /// `tui.json` bytes with our entry added, preserving every other key and
    /// entry. Nil when the existing content refuses (present-but-unparseable,
    /// or a `plugin` key of an unexpected shape).
    public static func tuiByAddingPlugin(to existing: Data?) -> Data? {
        var tui: [String: Any] = [:]
        if let existing {
            guard
                let json = try? JSONSerialization.jsonObject(with: existing),
                let parsed = json as? [String: Any]
            else { return nil }
            tui = parsed
            if let entries = tui[tuiPluginKey],
               !(entries is NSNull), !(entries is [String]) { return nil }
        }
        var list = (tui[tuiPluginKey] as? [String]) ?? []
        if !list.contains(tuiPluginEntry) { list.append(tuiPluginEntry) }
        tui[tuiPluginKey] = list
        return renderTUI(tui)
    }

    /// `tui.json` bytes with our entry removed, or `.deleteFile` when nothing
    /// would remain. Nil when the existing content refuses. Removing our
    /// entry from a file that never had one rewrites it unchanged — callers
    /// that need a no-op check `tuiListsPlugin` first.
    public enum TUIRemoval: Sendable, Equatable {
        case deleteFile
        case rewrite(Data)
    }

    public static func tuiByRemovingPlugin(from existing: Data) -> TUIRemoval? {
        guard
            let json = try? JSONSerialization.jsonObject(with: existing),
            let tui = json as? [String: Any]
        else { return nil }
        guard let entries = tui[tuiPluginKey] else { return .rewrite(existing) }
        // m1: a null entry is "no entry" — drop the key, preserving the rest.
        if entries is NSNull {
            var remaining = tui
            remaining.removeValue(forKey: tuiPluginKey)
            guard !remaining.isEmpty else { return .deleteFile }
            guard let rewritten = renderTUI(remaining) else { return nil }
            return .rewrite(rewritten)
        }
        guard let list = entries as? [String] else { return nil }
        var remaining = tui
        let kept = list.filter { $0 != tuiPluginEntry }
        if kept.isEmpty {
            remaining.removeValue(forKey: tuiPluginKey)
        } else {
            remaining[tuiPluginKey] = kept
        }
        // An empty object holds no user content; absence and `{}` mean the
        // same to opencode, and leaving a file we emptied behind would make
        // remove-then-status report a config where there is none.
        guard !remaining.isEmpty else { return .deleteFile }
        guard let rewritten = renderTUI(remaining) else { return nil }
        return .rewrite(rewritten)
    }

    // MARK: - Mutations (consent-gated by the caller)

    public enum ServiceError: Error, Equatable {
        case notConfigured
        case bundledPluginUnavailable
        case isSymlink
        case unreadable
        case refused
    }

    /// Copy the bundled file and list it in `tui.json` (creating that file
    /// when absent). Re-installing writes byte-identical bytes.
    public func install() throws {
        guard let bundled = bundledPluginData() else {
            throw ServiceError.bundledPluginUnavailable
        }
        guard let fileSystem else { throw ServiceError.notConfigured }
        let state = try readStateOrThrow(fileSystem)
        guard !state.pluginFileIsSymlink, !state.pluginsDirIsSymlink else {
            throw ServiceError.isSymlink
        }
        if state.pluginFileExists, state.pluginData == nil { throw ServiceError.unreadable }
        guard !state.tuiFileIsSymlink, !state.configDirIsSymlink else {
            throw ServiceError.isSymlink
        }
        if state.tuiFileExists, state.tuiData == nil { throw ServiceError.unreadable }
        guard let updatedTUI = Self.tuiByAddingPlugin(to: state.tuiData) else {
            throw ServiceError.refused
        }
        if !state.pluginsDirExists {
            try fileSystem.createPluginsDirectory(permissions: 0o700)
        }
        try fileSystem.atomicWritePlugin(bundled, permissions: state.pluginPermissions ?? 0o600)
        if !state.configDirExists {
            try fileSystem.createConfigDirectory(permissions: 0o700)
        }
        try fileSystem.atomicWriteTUI(updatedTUI, permissions: state.tuiPermissions ?? 0o600)
        Log.claudeContext.info("opencode plugin install completed")
    }

    /// Delete the plugin file and drop our `tui.json` entry. A `tui.json`
    /// that would be left empty is deleted instead; a foreign or unparseable
    /// one is untouched.
    public func remove() throws {
        guard let fileSystem else { throw ServiceError.notConfigured }
        let state = try readStateOrThrow(fileSystem)
        guard !state.pluginFileIsSymlink, !state.pluginsDirIsSymlink else {
            throw ServiceError.isSymlink
        }
        guard !state.tuiFileIsSymlink, !state.configDirIsSymlink else {
            throw ServiceError.isSymlink
        }
        if state.tuiFileExists {
            guard let tuiData = state.tuiData else { throw ServiceError.unreadable }
            guard let removal = Self.tuiByRemovingPlugin(from: tuiData) else {
                throw ServiceError.refused
            }
            switch removal {
            case .deleteFile: try fileSystem.deleteTUI()
            case .rewrite(let data):
                try fileSystem.atomicWriteTUI(data, permissions: state.tuiPermissions ?? 0o600)
            }
        }
        if state.pluginFileExists {
            try fileSystem.deletePlugin()
        }
        Log.claudeContext.info("opencode plugin remove completed")
    }

    private func readStateOrThrow(_ fileSystem: any OpencodePluginFileSystem) throws -> OpencodePluginState {
        do {
            return try fileSystem.readState()
        } catch {
            Log.claudeContext.error(
                "opencode plugin edit failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Rendering

    static func renderTUI(_ tui: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: tui, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        var bytes = data
        if bytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }
        return bytes
    }
}

/// What the service can see about the opencode config before deciding.
public struct OpencodePluginState: Sendable, Equatable {
    public var pluginFileExists: Bool
    public var pluginFileIsSymlink: Bool
    public var pluginData: Data?
    public var pluginPermissions: UInt16?
    public var pluginsDirExists: Bool
    public var pluginsDirIsSymlink: Bool
    public var tuiFileExists: Bool
    public var tuiFileIsSymlink: Bool
    public var tuiData: Data?
    public var tuiPermissions: UInt16?
    public var configDirExists: Bool
    public var configDirIsSymlink: Bool

    public init(
        pluginFileExists: Bool = false,
        pluginFileIsSymlink: Bool = false,
        pluginData: Data? = nil,
        pluginPermissions: UInt16? = nil,
        pluginsDirExists: Bool = true,
        pluginsDirIsSymlink: Bool = false,
        tuiFileExists: Bool = false,
        tuiFileIsSymlink: Bool = false,
        tuiData: Data? = nil,
        tuiPermissions: UInt16? = nil,
        configDirExists: Bool = true,
        configDirIsSymlink: Bool = false
    ) {
        self.pluginFileExists = pluginFileExists
        self.pluginFileIsSymlink = pluginFileIsSymlink
        self.pluginData = pluginData
        self.pluginPermissions = pluginPermissions
        self.pluginsDirExists = pluginsDirExists
        self.pluginsDirIsSymlink = pluginsDirIsSymlink
        self.tuiFileExists = tuiFileExists
        self.tuiFileIsSymlink = tuiFileIsSymlink
        self.tuiData = tuiData
        self.tuiPermissions = tuiPermissions
        self.configDirExists = configDirExists
        self.configDirIsSymlink = configDirIsSymlink
    }
}

/// File operations the service needs, injected so every rule is testable
/// without a home directory.
public protocol OpencodePluginFileSystem: Sendable {
    func readState() throws -> OpencodePluginState
    func createPluginsDirectory(permissions: UInt16) throws
    func createConfigDirectory(permissions: UInt16) throws
    func atomicWritePlugin(_ data: Data, permissions: UInt16) throws
    func atomicWriteTUI(_ data: Data, permissions: UInt16) throws
    func deletePlugin() throws
    func deleteTUI() throws
}
