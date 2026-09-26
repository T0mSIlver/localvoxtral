import Foundation

/// Installs the opt-in Claude Code status line that shows whether
/// localvoxtral is connected to the session.
///
/// Unlike the plugin itself, a status line has no CLI: Claude Code owns
/// `~/.claude/settings.json` and its schema, so this service edits exactly
/// one key (`statusLine`) and nothing else. It never overwrites a status line
/// it did not write: Combine points a foreign entry at a script that runs the
/// user's command and ours, keeps their command in that script, and Remove
/// writes it back.
///
/// File discipline mirrors `ClaudeShellRCWriter`: write only on explicit
/// consent, refuse symlinks at every path component,
/// refuse an unreadable file (never treat it as empty), keep an existing
/// file's mode (0600 for a new one), write atomically, and stay idempotent
/// (re-applying writes byte-identical bytes).
///
/// JSON choice, stated once: edits round-trip through `JSONSerialization` and
/// are written pretty-printed with sorted keys. That normalizes the file's
/// formatting (whitespace, key order) while preserving every key and value
/// the user had. A text-level splice would preserve bytes but could not
/// survive the shapes a hand-edited settings file actually takes.
///
/// Known limitation, shared with the reference writers: edits are
/// read-modify-write with no interlock, so a hand-edit landing between our
/// read and our rename loses to our stale snapshot (last-writer-wins).
public struct ClaudeStatuslineInstallService: Sendable {
    /// The one key this service owns inside `~/.claude/settings.json`.
    public static let settingsKey = "statusLine"
    /// `statusLine.type` for a hook command.
    package static let commandType = "command"
    /// The hook flag that identifies OUR status line command. Matched as an
    /// exact shell word alongside the publisher binary's basename, so a
    /// wrapper script that merely mentions the binary is never mistaken for
    /// ours.
    public static let statuslineFlag = "--statusline"

    public static let consentSentence =
        "localvoxtral will edit ~/.claude/settings.json on this Mac."
    public static let combineConsentSentence =
        "localvoxtral will write ~/.claude/localvoxtral-statusline.sh and point "
        + "~/.claude/settings.json at it on this Mac."
    public static let combinedUpdateConsentSentence =
        "localvoxtral will rewrite ~/.claude/localvoxtral-statusline.sh on this Mac."

    /// The consent sentence for the row's setup button in `status`.
    public static func consentSentence(for status: Status) -> String {
        switch status {
        case .foreign: return combineConsentSentence
        case .combinedOutdated: return combinedUpdateConsentSentence
        default: return consentSentence
        }
    }

    private let fileSystem: (any ClaudeStatuslineFileSystem)?
    /// `~/.claude/localvoxtral-statusline.sh`, the script Combine writes.
    private let scriptFileSystem: (any ClaudeStatuslineFileSystem)?
    /// Whether an invoked path resolves to an existing executable. Injected
    /// so tests pin stale-path behaviour without touching the filesystem.
    private let isExecutableFile: @Sendable (String) -> Bool

    public init(
        fileSystem: (any ClaudeStatuslineFileSystem)? = nil,
        scriptFileSystem: (any ClaudeStatuslineFileSystem)? = nil,
        isExecutableFile: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.fileSystem = fileSystem
        self.scriptFileSystem = scriptFileSystem
        self.isExecutableFile = isExecutableFile
    }

    // MARK: - Read-only status

    public enum Status: Sendable, Equatable {
        /// No `statusLine` key at all. The only state that offers Install.
        case notConfigured
        /// Our command, pointing at THIS copy of the app. Offers Remove only:
        /// Update would write the same command back.
        case installed
        /// Our command, pointing at another copy of the app that still runs
        /// (an old install, a `try-pr` build in /tmp). Offers Update, which
        /// points it at this copy.
        case otherCopy
        /// Our command, but its path no longer resolves to an executable
        /// (the app moved). Offers Update, which rewrites the path.
        case stalePath
        /// Ours, edited by the user (extra flags, a pipe). Destructive ops
        /// refuse: deletion cannot be undone from our side.
        case edited
        /// A `statusLine` that is not ours. Never overwritten; offers Combine,
        /// which wraps it in a script that also runs our indicator.
        case foreign
        /// A foreign entry Combine cannot wrap: not a command, or a file this
        /// app did not write already sits where the script goes. Docs link only.
        case foreignNotCombinable
        /// Combined: the entry runs our script, which runs the user's command
        /// and this copy's indicator. Offers Remove, which restores the
        /// user's command.
        case combined
        /// Combined, but the script calls another copy of the app or lost
        /// its execute bit. Offers Update, which rewrites the script.
        case combinedOutdated
        /// The entry runs our script, but the script is missing or was
        /// edited, so the user's command cannot be read back. No button.
        case combinedBroken
        /// The file exists but cannot be read or parsed. Reported, not
        /// treated as absent: an unparseable file must never be replaced
        /// with a clean one.
        case unknown
    }

    /// The row's one status sentence. Never restates the label.
    public static func sentence(for status: Status) -> String {
        switch status {
        case .notConfigured: return "Not installed."
        case .installed: return "Installed."
        case .stalePath: return "The installed path moved; update the status line."
        case .otherCopy: return "Points at another copy of localvoxtral."
        case .edited: return "Edited in settings.json; remove it there."
        case .foreign: return "Your own status line is configured."
        case .foreignNotCombinable: return "Your own status line; combine it by hand."
        case .combined: return "Combined with your status line."
        case .combinedOutdated: return "Combined; the script needs an update."
        case .combinedBroken: return "The combined script is missing or edited."
        case .unknown: return "Could not read your Claude settings."
        }
    }

    /// - Parameter currentHookCommand: the command this copy of the app
    ///   writes. Nil when it cannot tell, and then any runnable entry of ours
    ///   reads as installed.
    public func status(currentHookCommand: String? = nil) -> Status {
        guard let fileSystem, let state = try? fileSystem.readState() else { return .unknown }
        guard let data = state.data else {
            // Absent file: nothing configured. An EXISTING but unreadable
            // file is unknown — see the rc writer's M2.
            return state.fileExists ? .unknown : .notConfigured
        }
        let derived = Self.deriveStatus(settingsData: data)
        let current = currentHookCommand.flatMap { Self.shellWords($0).first }
        if derived == .combined { return combinedStatus(currentHookPath: current) }
        if derived == .foreign { return combinable(settingsData: data) ? .foreign : .foreignNotCombinable }
        guard derived == .installed else { return derived }
        // "Installed." only when the configured path resolves: an entry
        // pointing at a moved/deleted app must surface, not claim health.
        // Bare names (no "/") cannot be checked against the filesystem here;
        // they resolve via PATH at runtime (see below).
        guard
            let command = Self.deriveCommand(settingsData: data),
            Self.isCanonical(command: command)
        else { return derived }
        let argv = Self.shellWords(command)
        guard let invoked = argv.first, invoked.contains("/") else {
            // A bare name resolves through Claude Code's PATH, which this app
            // cannot see. Not known to be this copy, so Update… stays.
            return current == nil ? .installed : .otherCopy
        }
        guard isExecutableFile(invoked) else { return .stalePath }
        // A runnable path is not proof it is this app: a moved app leaves the
        // old copy behind more often than not.
        guard let current else { return .installed }
        return Self.samePath(invoked, current) ? .installed : .otherCopy
    }

    private func combinedStatus(currentHookPath: String?) -> Status {
        guard let script = readScript(), let parsed = ClaudeStatuslineCombine.parse(script.text) else {
            return .combinedBroken
        }
        // Claude Code runs the script directly, so without its execute bit it
        // prints nothing. Update rewrites it at 0700.
        if let permissions = script.permissions, permissions & 0o100 == 0 { return .combinedOutdated }
        guard let currentHookPath else { return .combined }
        return Self.samePath(parsed.hookPath, currentHookPath) ? .combined : .combinedOutdated
    }

    /// Whether Combine would succeed: the entry is a command, and no file
    /// this app did not write sits where the script goes.
    private func combinable(settingsData: Data) -> Bool {
        guard let command = Self.deriveCommand(settingsData: settingsData),
              command != ClaudeStatuslineCombine.settingsCommand,
              !Self.isOurs(command: command)
        else { return false }
        guard let scriptFileSystem, let state = try? scriptFileSystem.readState() else { return false }
        if state.fileIsSymlink || state.directoryIsSymlink { return false }
        guard state.fileExists else { return true }
        return readScript().flatMap { ClaudeStatuslineCombine.parse($0.text) } != nil
    }

    /// The script's text and mode, or nil when it is absent, unreadable, or
    /// a symlink.
    private func readScript() -> (text: String, permissions: UInt16?)? {
        guard let scriptFileSystem,
              let state = try? scriptFileSystem.readState(),
              !state.fileIsSymlink, !state.directoryIsSymlink,
              let data = state.data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return (text, state.permissions)
    }

    /// The row's setup button, or nil: none while the entry is this app's
    /// (writing it again changes nothing), and none where we cannot write.
    public static func setupButtonTitle(for status: Status) -> String? {
        switch status {
        case .notConfigured: return "Set up…"
        case .stalePath, .otherCopy, .combinedOutdated: return "Update…"
        case .foreign: return "Combine…"
        case .installed, .combined, .combinedBroken, .foreignNotCombinable, .edited, .unknown:
            return nil
        }
    }

    /// Remove is offered only for an entry that is ours, unedited.
    public static func offersRemove(for status: Status) -> Bool {
        switch status {
        case .installed, .stalePath, .otherCopy, .combined, .combinedOutdated: return true
        case .notConfigured, .edited, .foreign, .foreignNotCombinable, .combinedBroken, .unknown:
            return false
        }
    }

    /// Whether two paths name the same file, through symlinks and `..`
    /// (`/Applications` is a symlink on some setups; a dev build prints its
    /// path through one).
    package static func samePath(_ a: String, _ b: String) -> Bool {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return canonical(a) == canonical(b)
    }

    /// The configured command string when the file holds a command-shaped
    /// `statusLine`, nil otherwise. Lets `status()` refine `.installed`
    /// without re-parsing at the call site.
    package static func deriveCommand(settingsData: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: settingsData),
            let settings = json as? [String: Any],
            let entry = settings[settingsKey]
        else { return nil }
        return statuslineCommand(from: entry)
    }

    /// Pure derivation over file bytes, so fixtures pin every shape.
    public static func deriveStatus(settingsData: Data) -> Status {
        guard
            let json = try? JSONSerialization.jsonObject(with: settingsData),
            let settings = json as? [String: Any]
        else { return .unknown }
        guard let entry = settings[settingsKey] else { return .notConfigured }
        if statuslineCommand(from: entry) == ClaudeStatuslineCombine.settingsCommand {
            return .combined
        }
        guard
            let command = statuslineCommand(from: entry),
            isOurs(command: command)
        else { return .foreign }
        // Ours but user-edited (a pipe, extra flags): not canonical, so not
        // writable — reported distinctly, never deleted.
        guard isCanonical(command: command) else { return .edited }
        return .installed
    }

    /// The command string when `statusLine` is the `{type: command, command}`
    /// shape, nil for anything else (a string shorthand, a missing command).
    /// Only that shape is ours; anything else is foreign by definition.
    public static func statuslineCommand(from entry: Any) -> String? {
        guard let dict = entry as? [String: Any] else { return nil }
        guard (dict["type"] as? String) == commandType else { return nil }
        guard let command = dict["command"] as? String, !command.isEmpty else { return nil }
        return command
    }

    /// Ours when the command invokes THIS app's publisher in statusline mode.
    /// Tokenized, never substring: the README's composition recipe wraps the
    /// binary inside the user's own script, and that script is theirs, not
    /// ours. `argv[0]`'s basename must equal our executable name AND one argv
    /// token must equal `--statusline` exactly, so `--statusline-compat`, a
    /// wrapper binary containing our name, or a command merely mentioning
    /// both strings stays foreign.
    public static func isOurs(
        command: String,
        executableName: String = ClaudePluginAssets.publisherExecutableName
    ) -> Bool {
        let argv = shellWords(command)
        guard let invoked = argv.first else { return false }
        guard URL(fileURLWithPath: invoked).lastPathComponent == executableName else {
            return false
        }
        return argv.contains(statuslineFlag)
    }

    /// Structurally ours with no extras: exactly `[hook, --statusline]`.
    /// A user-edited formerly-ours command (extra flags, a pipe) still
    /// matches `isOurs` but is NOT canonical: destructive ops require the
    /// canonical shape, and stale-path detection only applies to it.
    public static func isCanonical(
        command: String,
        executableName: String = ClaudePluginAssets.publisherExecutableName
    ) -> Bool {
        let argv = shellWords(command)
        guard argv.count == 2 else { return false }
        guard URL(fileURLWithPath: argv[0]).lastPathComponent == executableName else {
            return false
        }
        return argv[1] == statuslineFlag
    }

    /// Split a shell command into words, respecting single/double quotes and
    /// backslash escapes. Minimal on purpose: enough to find `argv[0]` and
    /// exact flag tokens without substring false positives.
    package static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in command {
            if escaped {
                current.append(ch)
                escaped = false
                inWord = true
                continue
            }
            if ch == "\\", quote != "'" {
                escaped = true
                inWord = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                inWord = true
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                inWord = true
                continue
            }
            if ch.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
                continue
            }
            current.append(ch)
            inWord = true
        }
        if escaped { current.append("\\") }
        if inWord { words.append(current) }
        return words
    }

    // MARK: - Preview

    /// The exact `statusLine` object the apply would write, rendered as the
    /// sheet shows it. Nil when the hook binary cannot be located.
    public static func preview(
        hookCommand: String?,
        newline: String = "\n"
    ) -> String? {
        guard let hookCommand else { return nil }
        let entry: [String: Any] = [commandTypeKey: commandType, commandKey: hookCommand]
        return render(entry: entry)
    }

    /// The full file bytes an apply would write for this existing content.
    /// Nil when the existing content refuses (symlink/unreadable cases are
    /// enforced by the writer; here: unparseable JSON, or a foreign entry we
    /// will not overwrite).
    public static func updatedSettingsData(
        existing: Data?,
        hookCommand: String
    ) -> Data? {
        var settings: [String: Any] = [:]
        if let existing {
            guard
                let json = try? JSONSerialization.jsonObject(with: existing),
                let parsed = json as? [String: Any]
            else { return nil }
            settings = parsed
            // Canonical only: a user-edited formerly-ours command is no
            // longer ours to overwrite.
            if let entry = settings[settingsKey],
               !(statuslineCommand(from: entry).map { isCanonical(command: $0) } ?? false) {
                return nil
            }
        }
        // M1: preserve every other key on the user's entry (`padding` and
        // any future Claude Code key) — only `type`/`command` are ours to set.
        var entry: [String: Any] = [:]
        if let existingEntry = settings[settingsKey] as? [String: Any] {
            entry = existingEntry
        }
        entry[commandTypeKey] = commandType
        entry[commandKey] = hookCommand
        settings[settingsKey] = entry
        return renderSettings(settings)
    }

    /// Full file bytes a remove would write, or `.deleteFile` when nothing
    /// would remain. Nil when the entry is foreign (untouched) or the file
    /// is unparseable (refused).
    public enum Removal: Sendable, Equatable {
        case deleteFile
        case rewrite(Data)
        /// Nothing of ours is present: the caller must not touch the file
        /// (no mtime churn, no last-writer-wins window).
        case noChange
    }

    public static func removalSettingsData(existing: Data) -> Removal? {
        guard
            let json = try? JSONSerialization.jsonObject(with: existing),
            let settings = json as? [String: Any]
        else { return nil }
        guard let entry = settings[settingsKey] else { return .noChange }
        guard
            let command = statuslineCommand(from: entry),
            Self.isCanonical(command: command)
        else { return nil }
        var remaining = settings
        remaining.removeValue(forKey: settingsKey)
        guard !remaining.isEmpty else { return .deleteFile }
        guard let rewritten = renderSettings(remaining) else { return nil }
        return .rewrite(rewritten)
    }

    // MARK: - Mutations (consent-gated by the caller)

    public func apply(hookCommand: String) throws {
        try write { existing in
            guard let updated = Self.updatedSettingsData(existing: existing, hookCommand: hookCommand) else {
                throw ClaudeStatuslineError.refused
            }
            return .rewrite(updated)
        }
    }

    // MARK: - Combine

    /// Wrap the user's own status line in our script and point the entry at
    /// it. Script first: if the settings write then fails, a stray script
    /// runs nothing.
    public func combine(hookCommand: String) throws {
        guard let hookPath = Self.shellWords(hookCommand).first else {
            throw ClaudeStatuslineError.refused
        }
        guard let fileSystem, let scriptFileSystem else { throw ClaudeStatuslineError.notConfigured }
        let settings = try Self.readSettings(fileSystem)
        guard
            let entry = settings[Self.settingsKey],
            let original = Self.statuslineCommand(from: entry),
            original != ClaudeStatuslineCombine.settingsCommand,
            !Self.isOurs(command: original)
        else { throw ClaudeStatuslineError.refused }
        try writeScript(
            ClaudeStatuslineCombine.script(original: original, hookPath: hookPath),
            to: scriptFileSystem
        )
        try write { _ in
            .rewrite(try Self.settingsData(settings, command: ClaudeStatuslineCombine.settingsCommand))
        }
    }

    /// Point a combined script at this copy of the app, keeping the user's
    /// command.
    public func updateCombined(hookCommand: String) throws {
        guard let hookPath = Self.shellWords(hookCommand).first else {
            throw ClaudeStatuslineError.refused
        }
        guard let scriptFileSystem else { throw ClaudeStatuslineError.notConfigured }
        guard let parsed = readScript().flatMap({ ClaudeStatuslineCombine.parse($0.text) }) else {
            throw ClaudeStatuslineError.refused
        }
        try writeScript(
            ClaudeStatuslineCombine.script(original: parsed.original, hookPath: hookPath),
            to: scriptFileSystem
        )
    }

    /// Put the user's command back in the entry, then delete the script.
    /// Refuses when the script cannot be read back: the command lives only
    /// there.
    private func removeCombined() throws {
        guard let fileSystem, let scriptFileSystem else { throw ClaudeStatuslineError.notConfigured }
        guard let parsed = readScript().flatMap({ ClaudeStatuslineCombine.parse($0.text) }) else {
            throw ClaudeStatuslineError.refused
        }
        let settings = try Self.readSettings(fileSystem)
        try write { _ in .rewrite(try Self.settingsData(settings, command: parsed.original)) }
        try scriptFileSystem.deleteFile()
        Log.claudeContext.info("Claude status line combine removed")
    }

    /// The settings file's JSON object, refusing what `write` refuses.
    private static func readSettings(_ fileSystem: any ClaudeStatuslineFileSystem) throws -> [String: Any] {
        let state = try fileSystem.readState()
        guard !state.fileIsSymlink, !state.directoryIsSymlink else { throw ClaudeStatuslineError.isSymlink }
        guard let data = state.data else {
            throw state.fileExists ? ClaudeStatuslineError.unreadable : ClaudeStatuslineError.refused
        }
        guard let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatuslineError.refused
        }
        return settings
    }

    /// `settings` with the entry's command replaced, every other key kept.
    private static func settingsData(_ settings: [String: Any], command: String) throws -> Data {
        var settings = settings
        var entry = (settings[settingsKey] as? [String: Any]) ?? [:]
        entry[commandTypeKey] = commandType
        entry[commandKey] = command
        settings[settingsKey] = entry
        guard let data = renderSettings(settings) else { throw ClaudeStatuslineError.refused }
        return data
    }

    /// Write the script, owner-only and executable. Never over a symlink, and
    /// never over a file this app did not write.
    private func writeScript(_ text: String, to scriptFileSystem: any ClaudeStatuslineFileSystem) throws {
        let state = try scriptFileSystem.readState()
        guard !state.fileIsSymlink, !state.directoryIsSymlink else { throw ClaudeStatuslineError.isSymlink }
        if state.fileExists {
            guard let data = state.data,
                  String(data: data, encoding: .utf8).flatMap(ClaudeStatuslineCombine.parse) != nil
            else { throw ClaudeStatuslineError.refused }
        }
        if !state.directoryExists { try scriptFileSystem.createDirectory(permissions: 0o700) }
        try scriptFileSystem.atomicWrite(Data(text.utf8), permissions: 0o700)
        Log.claudeContext.info("Claude status line combine script written")
    }

    public func remove() throws {
        if let fileSystem,
           let data = try? fileSystem.readState().data,
           Self.deriveStatus(settingsData: data) == .combined {
            try removeCombined()
            return
        }
        try write { existing in
            guard let existing else { return .rewrite(nil) }
            guard let removal = Self.removalSettingsData(existing: existing) else {
                throw ClaudeStatuslineError.refused
            }
            switch removal {
            case .deleteFile: return .delete
            case .rewrite(let data): return .rewrite(data)
            case .noChange: return .noChange
            }
        }
    }

    private enum WriteOutcome {
        /// Write these bytes (nil = file already in the desired state).
        case rewrite(Data?)
        case delete
        case noChange
    }

    private func write(_ transform: (Data?) throws -> WriteOutcome) throws {
        Log.claudeContext.info("Claude status line edit requested")
        guard let fileSystem else {
            Log.claudeContext.error("Claude status line edit failed: editing not configured")
            throw ClaudeStatuslineError.notConfigured
        }
        do {
            let state = try fileSystem.readState()
            guard !state.fileIsSymlink, !state.directoryIsSymlink else {
                throw ClaudeStatuslineError.isSymlink
            }
            let existing: Data?
            if let data = state.data {
                existing = data
            } else if state.fileExists {
                throw ClaudeStatuslineError.unreadable
            } else {
                existing = nil
            }
            if !state.directoryExists {
                try fileSystem.createDirectory(permissions: 0o700)
            }
            switch try transform(existing) {
            case .rewrite(let data):
                guard let data else { return }
                try fileSystem.atomicWrite(data, permissions: state.permissions ?? 0o600)
            case .delete:
                try fileSystem.deleteFile()
            case .noChange:
                return
            }
            Log.claudeContext.info("Claude status line edit completed")
        } catch {
            Log.claudeContext.error(
                "Claude status line edit failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Rendering

    package static let commandTypeKey = "type"
    package static let commandKey = "command"

    package static func render(entry: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    package static func renderSettings(_ settings: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        // Exactly one trailing newline: a settings file is a POSIX text file,
        // and re-applying over our own output must be byte-identical.
        var bytes = data
        if bytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }
        return bytes
    }
}

/// What the service can see about `~/.claude/settings.json` before deciding.
public struct ClaudeStatuslineState: Sendable, Equatable {
    public var fileExists: Bool
    public var fileIsSymlink: Bool
    public var directoryExists: Bool
    public var directoryIsSymlink: Bool
    public var data: Data?
    public var permissions: UInt16?

    public init(
        fileExists: Bool = false,
        fileIsSymlink: Bool = false,
        directoryExists: Bool = true,
        directoryIsSymlink: Bool = false,
        data: Data? = nil,
        permissions: UInt16? = nil
    ) {
        self.fileExists = fileExists
        self.fileIsSymlink = fileIsSymlink
        self.directoryExists = directoryExists
        self.directoryIsSymlink = directoryIsSymlink
        self.data = data
        self.permissions = permissions
    }
}

/// File operations the writer needs, injected so every rule is testable
/// without a home directory.
public protocol ClaudeStatuslineFileSystem: Sendable {
    func readState() throws -> ClaudeStatuslineState
    func createDirectory(permissions: UInt16) throws
    func atomicWrite(_ data: Data, permissions: UInt16) throws
    func deleteFile() throws
}

public enum ClaudeStatuslineError: Error, Equatable {
    /// The settings file — or a directory on the way to it — is a symlink.
    case isSymlink
    case invalidEncoding
    case notConfigured
    /// The file EXISTS and could not be read. Never treated as absent.
    case unreadable
    /// The file holds a foreign status line, or JSON this writer will not
    /// reshape. Untouched.
    case refused
}
