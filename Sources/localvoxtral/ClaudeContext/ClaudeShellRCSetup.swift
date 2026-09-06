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
/// a user's startup file without showing the exact text first and being told
/// yes.
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

    /// Is our block already in this text?
    public static func containsBlock(_ existing: String) -> Bool {
        if case .present = locateBlock(in: splitLines(existing)) { return true }
        return false
    }

    /// Does this text carry an unpaired begin marker?
    public static func hasDamagedBlock(_ existing: String) -> Bool {
        locateBlock(in: splitLines(existing)) == .damaged
    }

    /// Lines, plus the terminator the file actually uses.
    ///
    /// A CRLF file spliced with LF comes back mixed (review finding m3), and
    /// "mostly CRLF with one LF region" is a file we damaged in a way the user
    /// will notice in their editor. The whole file is never normalized either —
    /// that would be the same crime in the other direction.
    static func lineTerminator(of text: String) -> String {
        text.contains("\r\n") ? "\r\n" : "\n"
    }

    /// Split on LF and strip a trailing CR, so a CRLF file's lines compare and
    /// rejoin like any other.
    static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    /// Insert or REPLACE the block, leaving everything else byte for byte.
    ///
    /// Idempotent by delimiter, like the ssh-config writer and for a sharper
    /// reason: an rc file with two copies of this block is not merely untidy,
    /// it would run `tty` twice per shell start forever.
    /// - Returns: nil when the file's markers do not pair — the caller must
    ///   refuse rather than write.
    public static func apply(to existing: String, snippet: String) -> String? {
        let terminator = lineTerminator(of: existing)
        let lines = splitLines(existing)
        switch locateBlock(in: lines) {
        case .damaged:
            return nil
        case .absent:
            var prefix = existing
            if !prefix.isEmpty, !prefix.hasSuffix(terminator) { prefix += terminator }
            if !prefix.isEmpty, !prefix.hasSuffix(terminator + terminator) {
                prefix += terminator
            }
            let body = snippet.components(separatedBy: "\n").joined(separator: terminator)
            return prefix + body + terminator
        case .present(let ranges):
            // Replace the FIRST block in place and drop the rest, so a file
            // that was hand-duplicated converges to one.
            var result: [String] = []
            var cursor = 0
            for (offset, range) in ranges.enumerated() {
                result.append(contentsOf: lines[cursor..<range.lowerBound])
                if offset == 0 {
                    result.append(contentsOf: snippet.components(separatedBy: "\n"))
                }
                cursor = range.upperBound + 1
            }
            result.append(contentsOf: lines[cursor...])
            return result.joined(separator: terminator)
        }
    }

    /// Remove the block, leaving everything else untouched.
    /// - Returns: nil for the same unpaired-marker case as `apply`.
    public static func remove(from existing: String) -> String? {
        let terminator = lineTerminator(of: existing)
        let lines = splitLines(existing)
        switch locateBlock(in: lines) {
        case .damaged:
            return nil
        case .absent:
            return existing
        case .present(let ranges):
            var result: [String] = []
            var cursor = 0
            for range in ranges {
                var start = range.lowerBound
                // Take back the blank line `apply` inserted as a separator, so
                // apply-then-remove is byte-identical to the original rather
                // than leaving a growing gap behind (review finding m1). Only
                // ONE, and only when it is a blank line we would have added.
                if start > cursor, lines[start - 1].isEmpty { start -= 1 }
                result.append(contentsOf: lines[cursor..<start])
                cursor = range.upperBound + 1
            }
            result.append(contentsOf: lines[cursor...])
            return result.joined(separator: terminator)
        }
    }

    /// Every complete block, in order; or `.damaged` when the markers do not
    /// nest and pair the way we wrote them.
    ///
    /// `.damaged` is not fussiness, and it took two review rounds to get its
    /// definition right. A begin with NO end lets an append leave two begins
    /// and one end, and the next apply then replaces everything between the
    /// first begin and that single end. A begin followed by ANOTHER begin
    /// before any end is the same wound already open: taking the first begin
    /// and the first end after it spans the user's lines in between and
    /// deletes them (review finding M1). Both are hand-edit shapes — delete an
    /// end marker, re-paste the README block to "fix" it — and refusing to
    /// touch such a file is the only answer that cannot lose content.
    ///
    /// SEVERAL complete pairs are not damage but they are not one block
    /// either: `apply` replaces the first and would leave the rest forever,
    /// which is the duplicate the idempotency claim exists to prevent. All of
    /// them are replaced (review finding m2).
    static func locateBlock(in lines: [String]) -> BlockLocation {
        var ranges: [ClosedRange<Int>] = []
        var openedAt: Int?
        for (index, line) in lines.enumerated() {
            if isMarker(line, markerBegin) {
                guard openedAt == nil else { return .damaged }
                openedAt = index
                continue
            }
            if isMarker(line, markerEnd) {
                guard let begin = openedAt else {
                    // An end with no begin: also not a shape we wrote.
                    return .damaged
                }
                ranges.append(begin...index)
                openedAt = nil
            }
        }
        if openedAt != nil { return .damaged }
        return ranges.isEmpty ? .absent : .present(ranges)
    }

    public enum BlockLocation: Equatable {
        case absent
        /// One or more complete blocks, in file order.
        case present([ClosedRange<Int>])
        /// Markers that do not pair — a hand-edit we will not write past.
        case damaged
    }

    /// Trimmed of whitespace AND newlines, so an indented copy counts and a
    /// CRLF file's `…(begin)\r` is still our marker. `.whitespaces` alone is
    /// space and tab only, and a dotfile synced from a Windows-touched repo
    /// would have looked marker-free — which means appending a duplicate.
    private static func isMarker(_ line: String, _ marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == marker
    }
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
        guard let fileSystem, let state = try? fileSystem.readState() else { return nil }
        guard let data = state.data, let text = String(data: data, encoding: .utf8) else {
            return state.fileExists ? nil : false
        }
        // Damaged markers are not "applied": the writer will refuse, and the
        // row must not offer Remove as though there were a clean block.
        if ClaudeShellRCSetup.hasDamagedBlock(text) { return nil }
        return ClaudeShellRCSetup.containsBlock(text)
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
