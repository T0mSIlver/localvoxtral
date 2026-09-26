import Foundation

/// The login shells this app will write an rc block for.
///
/// Three, because three is what macOS ships and what the block has to be
/// written in: `zsh` (the default since Catalina), `bash` (still the login
/// shell on upgraded accounts), and `fish` (whose syntax shares nothing with
/// the other two). Anything else gets the copy-paste path — guessing at a
/// shell's syntax is how a setup step corrupts someone's startup file.
public enum ClaudeShellKind: String, Sendable, CaseIterable {
    case zsh
    case bash
    case fish

    /// The shell behind a login-shell PATH, or nil for one we will not write.
    ///
    /// By BASENAME, and exactly: `/bin/zsh`, `/opt/homebrew/bin/fish` and
    /// `/usr/local/bin/bash` are all real answers from `dscl`. A path we do not
    /// recognise is not a shell we may append POSIX to.
    public static func detect(loginShellPath: String?) -> ClaudeShellKind? {
        guard let loginShellPath, loginShellPath.hasPrefix("/") else { return nil }
        let name = (loginShellPath as NSString).lastPathComponent
        return ClaudeShellKind(rawValue: name)
    }
}

/// Where the block goes, what it says, and how it is replaced or removed.
///
/// The whole file is PURE: it turns a shell and some existing text into new
/// text. Deciding to write anything is the caller's, exactly as it is for
/// `ClaudeRemoteEnrollmentService.applySSHConfigSnippet` — this app never edits
/// a user's startup file without naming the file and obtaining consent first.
/// The exact text belongs in the linked documentation, not Settings.
public enum ClaudeShellRCSetup {
    /// The delimiters. Idempotency and removal both ride on them, so they are
    /// content-free and must never carry a host, a path or a version: a marker
    /// that changes cannot find the block it wrote last time.
    public static let markerBegin = "# localvoxtral plain-ssh join (begin)"
    public static let markerEnd = "# localvoxtral plain-ssh join (end)"

    /// The rc file this app will write for a shell, relative to `$HOME`.
    ///
    /// - `zsh` → `.zshrc`. Read by every interactive zsh, login or not, which
    ///   is what a terminal window runs.
    /// - `bash` → `.bash_profile` when it exists, else `.bashrc` when THAT
    ///   exists, else `.bash_profile`. macOS terminals run bash as a LOGIN
    ///   shell, which reads `.bash_profile` and not `.bashrc`; but an account
    ///   that already keeps everything in `.bashrc` is invariably sourcing it
    ///   from `.bash_profile`, and appending to the file the user actually
    ///   edits is likelier to survive their next dotfile change.
    /// - `fish` → `.config/fish/conf.d/localvoxtral.fish`. fish sources every
    ///   file in `conf.d`, so this is the one shell where the app can own its
    ///   own file instead of appending to the user's.
    ///
    /// - Parameter fileExists: injected so the bash rule is testable without a
    ///   home directory.
    public static func relativeRCPath(
        for shell: ClaudeShellKind,
        fileExists: (String) -> Bool
    ) -> String {
        switch shell {
        case .zsh:
            return ".zshrc"
        case .bash:
            if fileExists(".bash_profile") { return ".bash_profile" }
            if fileExists(".bashrc") { return ".bashrc" }
            return ".bash_profile"
        case .fish:
            return ".config/fish/conf.d/localvoxtral.fish"
        }
    }

    /// The marked block, in that shell's own syntax.
    ///
    /// Every guard in it was measured rather than assumed (2026-09-06):
    ///
    /// * `$SSH_TTY` unset — export only on THIS Mac. The same rc file on a
    ///   remote host would otherwise replace the Mac's tty with the remote pts
    ///   and nothing would ever match.
    /// * `$LC_LVX_TTY` unset — never overwrite what was sent to us, for the
    ///   same reason.
    /// * `/dev/*` — in a shell with no terminal `tty` prints `not a tty`, and
    ///   exporting that poisons the guard above for every shell downstream.
    /// * an `if` block rather than an `&&` chain — the chain's status becomes
    ///   the rc file's status, and `bash --norc -c 'set -e; source rc; echo
    ///   SURVIVED'` printed nothing and exited 1. bash sources `~/.bashrc`
    ///   non-interactively for shells it believes sshd started, so the chain
    ///   version could break `ssh host script` for anyone syncing dotfiles.
    public static func snippet(for shell: ClaudeShellKind) -> String {
        let body: String
        switch shell {
        case .zsh, .bash:
            body = """
            if [ -z "${LC_LVX_TTY:-}" ] && [ -z "${SSH_TTY:-}" ]; then
              case "$(tty 2>/dev/null)" in /dev/*) LC_LVX_TTY="$(tty)"; export LC_LVX_TTY ;; esac
            fi
            """
        case .fish:
            // fish has no `case`/`$(...)`, and `set -q` is its "is it set".
            body = """
            if not set -q LC_LVX_TTY; and not set -q SSH_TTY
                set -l __lvx_tty (tty 2>/dev/null)
                if string match -q -- '/dev/*' "$__lvx_tty"
                    set -gx LC_LVX_TTY "$__lvx_tty"
                end
            end
            """
        }
        return """
        \(markerBegin)
        # Publishes this terminal's tty so localvoxtral can tell which window a
        # Claude Code session over ssh belongs to. Remove this block in
        # Settings, or by hand.
        \(body)
        \(markerEnd)
        """
    }

    /// The block rules live in `MarkedTextBlock`; these bind them to the rc
    /// markers.
    package static let block = MarkedTextBlock(markerBegin: markerBegin, markerEnd: markerEnd)

    public static func containsBlock(_ existing: String) -> Bool { block.containsBlock(existing) }

    public static func containsCurrentBlock(_ existing: String, snippet: String) -> Bool {
        block.containsCurrentBlock(existing, snippet: snippet)
    }

    public static func hasDamagedBlock(_ existing: String) -> Bool { block.hasDamagedBlock(existing) }

    /// - Returns: nil when the file's markers do not pair — the caller must
    ///   refuse rather than write.
    public static func apply(to existing: String, snippet: String) -> String? {
        block.apply(to: existing, snippet: snippet)
    }

    /// - Returns: nil for the same unpaired-marker case as `apply`.
    public static func remove(from existing: String) -> String? { block.remove(from: existing) }

    public typealias BlockLocation = MarkedTextBlock.Location

    package static func locateBlock(in lines: [String]) -> BlockLocation { block.locateBlock(in: lines) }

    package static func splitLines(_ text: String) -> [String] { block.splitLines(text) }

    package static func lineTerminator(of text: String) -> String { block.lineTerminator(of: text) }
}

/// What the app can see about one rc file before deciding to write it.
public struct ClaudeShellRCState: Sendable, Equatable {
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

/// The file operations the writer needs, injected so every rule above is
/// testable without a home directory.
public protocol ClaudeShellRCFileSystem: Sendable {
    func readState() throws -> ClaudeShellRCState
    func createDirectory(permissions: UInt16) throws
    func atomicWrite(_ data: Data, permissions: UInt16) throws
}

public enum ClaudeShellRCError: Error, Equatable {
    /// The rc file — or a directory on the way to it — is a symlink.
    ///
    /// Refused rather than followed, and this is the case a dotfiles user
    /// actually hits: `~/.zshrc` is very often a link into a repo, and an
    /// atomic write REPLACES the link with a regular file, silently detaching
    /// their dotfiles. Refusing costs them a copy-paste; writing costs them
    /// their setup.
    case isSymlink
    case invalidEncoding
    case notConfigured
    /// The file EXISTS and could not be read. Never treated as empty: doing so
    /// made a confirmed setup overwrite an unreadable `~/.zshrc` with
    /// snippet-only bytes — total content loss, silently (review finding M2).
    case unreadable
    /// A begin marker with no end. Writing past it would let the NEXT apply
    /// swallow whatever the user put in between.
    case markersDoNotPair
}

/// Applies or removes the block in the user's rc file.
public struct ClaudeShellRCWriter: Sendable {
    private let fileSystem: (any ClaudeShellRCFileSystem)?

    public init(fileSystem: (any ClaudeShellRCFileSystem)? = nil) {
        self.fileSystem = fileSystem
    }

    /// Is the block present right now? Nil when the file cannot be read at all,
    /// which the UI reports as unknown rather than as absent.
    public func isApplied() -> Bool? {
        statusText()?.text.map(ClaudeShellRCSetup.containsBlock)
    }

    public enum BlockState: Sendable, Equatable {
        case absent
        /// This build's text for the shell, exactly once.
        case current
        /// A block `apply` would rewrite: older text, or several copies.
        case outdated
    }

    public struct Reading: Sendable, Equatable {
        /// Nil when the file cannot be read. A symlinked file is never read
        /// through, so its block is always nil.
        public var block: BlockState?
        /// The file or a directory on the way to it is a symlink: every
        /// write refuses.
        public var isSymlinked: Bool
    }

    /// Absent, current or outdated from ONE read of the file, so a save
    /// landing between two reads cannot mix their answers.
    public func reading(shell: ClaudeShellKind) -> Reading {
        guard let read = statusText() else { return Reading(block: nil, isSymlinked: false) }
        let block = read.text.map { text -> BlockState in
            if ClaudeShellRCSetup.containsCurrentBlock(
                text, snippet: ClaudeShellRCSetup.snippet(for: shell)
            ) { return .current }
            return ClaudeShellRCSetup.containsBlock(text) ? .outdated : .absent
        }
        return Reading(block: block, isSymlinked: read.isSymlinked)
    }

    /// Nil exactly when `isApplied()` is nil.
    public func blockState(shell: ClaudeShellKind) -> BlockState? {
        reading(shell: shell).block
    }

    /// Is the block present AND this build's text for `shell`?
    public func isCurrent(shell: ClaudeShellKind) -> Bool? {
        blockState(shell: shell).map { $0 == .current }
    }

    /// The rc file's text for a status read: "" when it does not exist, nil
    /// text when it cannot be read. Nil overall when no state could be read.
    private func statusText() -> (text: String?, isSymlinked: Bool)? {
        guard let fileSystem, let state = try? fileSystem.readState() else { return nil }
        let isSymlinked = state.fileIsSymlink || state.directoryIsSymlink
        guard let data = state.data, let text = String(data: data, encoding: .utf8) else {
            return (state.fileExists ? nil : "", isSymlinked)
        }
        // Damaged markers are not "applied": the writer will refuse, and the
        // row must not offer Remove as though there were a clean block.
        if ClaudeShellRCSetup.hasDamagedBlock(text) { return (nil, isSymlinked) }
        return (text, isSymlinked)
    }

    public func apply(shell: ClaudeShellKind) throws {
        try write { existing in
            ClaudeShellRCSetup.apply(
                to: existing, snippet: ClaudeShellRCSetup.snippet(for: shell)
            )
        }
    }

    public func remove() throws {
        try write(ClaudeShellRCSetup.remove(from:))
    }

    private func write(_ transform: (String) -> String?) throws {
        Log.claudeContext.info("Claude shell rc edit requested")
        guard let fileSystem else {
            Log.claudeContext.error("Claude shell rc edit failed: editing not configured")
            throw ClaudeShellRCError.notConfigured
        }
        do {
            let state = try fileSystem.readState()
            guard !state.fileIsSymlink, !state.directoryIsSymlink else {
                throw ClaudeShellRCError.isSymlink
            }
            let existing: String
            if let data = state.data {
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw ClaudeShellRCError.invalidEncoding
                }
                existing = decoded
            } else if state.fileExists {
                // A file we can see but not read is NOT an empty file. The ssh
                // config reader beside this one propagates its read error; this
                // one used `try?` and mapped mode-000 to "", which turned
                // "confirm setup" into "delete my ~/.zshrc".
                throw ClaudeShellRCError.unreadable
            } else {
                existing = ""
            }
            if !state.directoryExists {
                try fileSystem.createDirectory(permissions: 0o700)
            }
            // Preserve what the file already had; a file WE create gets 0600.
            // Never widen: an rc file is executed by the user's shell, so its
            // mode is a security property, and 0600 is the tightest mode that
            // still works.
            guard let updated = transform(existing) else {
                throw ClaudeShellRCError.markersDoNotPair
            }
            try fileSystem.atomicWrite(
                Data(updated.utf8),
                permissions: state.permissions ?? 0o600
            )
            Log.claudeContext.info("Claude shell rc edit completed")
        } catch {
            Log.claudeContext.error(
                "Claude shell rc edit failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }
}
