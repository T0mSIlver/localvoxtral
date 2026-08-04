import Foundation

public struct ClaudeRemoteSSHConfigState: Sendable, Equatable {
    public var directoryExists: Bool
    public var configData: Data?
    public var configPermissions: UInt16?
    /// lstat-derived trust facts. The live filesystem fills them so the pure
    /// service can refuse to write through a path another principal controls;
    /// the defaults describe the trustworthy case so existing fakes stay valid.
    public var directoryIsSymlink: Bool
    public var directoryOwnedByCurrentUser: Bool
    public var directoryPermissions: UInt16?
    public var configIsSymlink: Bool

    public init(
        directoryExists: Bool,
        configData: Data?,
        configPermissions: UInt16?,
        directoryIsSymlink: Bool = false,
        directoryOwnedByCurrentUser: Bool = true,
        directoryPermissions: UInt16? = nil,
        configIsSymlink: Bool = false
    ) {
        self.directoryExists = directoryExists
        self.configData = configData
        self.configPermissions = configPermissions
        self.directoryIsSymlink = directoryIsSymlink
        self.directoryOwnedByCurrentUser = directoryOwnedByCurrentUser
        self.directoryPermissions = directoryPermissions
        self.configIsSymlink = configIsSymlink
    }
}

/// Filesystem seam for the one local file the enrollment flow may edit.
public protocol ClaudeRemoteSSHConfigFileSystem: Sendable {
    func readState() throws -> ClaudeRemoteSSHConfigState
    func createSSHDirectory(permissions: UInt16) throws
    func atomicWriteConfig(_ data: Data, permissions: UInt16) throws
}

/// Generates and, after a separate UI confirmation, applies the setup for a
/// remote Claude Code host. Both mutation paths are injected so tests cannot
/// reach the real home directory or a real SSH host.
public struct ClaudeRemoteEnrollmentService: Sendable {
    /// Everything the user needs, in the order they need it.
    public struct SetupPlan: Sendable, Equatable {
        /// Idempotent `~/.ssh/config` block. Contains NO token — the credential
        /// belongs to the Claude plugin's userConfig on the remote host, not to
        /// a file that gets copied between machines and pasted into issues.
        public var sshConfigSnippet: String
        /// Run on the REMOTE host, once.
        public var remoteCommands: [String]
        /// Run to check the setup without changing it.
        public var verifyCommands: [String]
        /// Bring an already-enrolled host to the plugin version this app ships.
        /// Carries no token: `claude plugin update` keeps the config the install
        /// already stored.
        public var updateCommands: [String]
        /// Undo, in order: remote first, then local revocation.
        public var uninstallCommands: [String]
        /// Caveats worth reading before the first surprise.
        public var notes: [String]
    }

    public struct RunResult: Sendable, Equatable {
        public var exitCode: Int32
        public var message: String

        public init(exitCode: Int32, message: String) {
            self.exitCode = exitCode
            self.message = message
        }

        public var succeeded: Bool { exitCode == 0 }
    }

    public struct Invocation: Sendable, Equatable {
        /// Complete argv, including `ssh`, so a fake can prove no token reached
        /// any process argument.
        public var argv: [String]
        public var standardInput: Data
        public var timeout: TimeInterval

        public init(argv: [String], standardInput: Data, timeout: TimeInterval) {
            self.argv = argv
            self.standardInput = standardInput
            self.timeout = timeout
        }
    }

    public struct ExecutionStep: Sendable, Equatable {
        public var index: Int
        /// Redacted; kept for diagnostics — the sheet renders only per-step
        /// status text plus `message`.
        public var command: String
        public var message: String

        public init(index: Int, command: String, message: String) {
            self.index = index
            self.command = command
            self.message = message
        }
    }

    /// Errors thrown by a runner before it can return an exit status. They are
    /// caught and redacted by `executeRemoteSetup`; callers never receive one.
    public enum RunnerFailure: Error, Equatable {
        case timedOut(seconds: TimeInterval, message: String)
        case outputTooLarge(capBytes: Int, message: String)
    }

    public enum ServiceError: Error, Equatable {
        /// No runner was injected, which is the default. Executing setup is an
        /// opt-in a caller makes deliberately, never a fallback this type
        /// reaches for.
        case executionNotConfigured
        case sshConfigEditingNotConfigured
        case invalidSSHConfigEncoding
        /// `~/.ssh/config` (or `~/.ssh` itself) is a symlink. A rename-based
        /// atomic write would replace the link with a regular file and silently
        /// desync a dotfiles-managed setup, so the app refuses and leaves the
        /// copy path — which mutates nothing — as the way in.
        case sshConfigIsSymlink
        /// `~/.ssh` exists but is not exclusively the user's to write (wrong
        /// owner, or group/world-writable). Report, never repair.
        case sshDirectoryNotTrusted
        /// `command` and `message` are REDACTED (`ClaudeRemoteTokenRedaction`)
        /// before they reach this case. An `Error` is the single most-copied
        /// string in any app: it lands in alerts, in `Log`, in the user's bug
        /// report, and — because `localizedDescription` is free — in places
        /// nobody audited. A token that reaches an error is a token that leaks,
        /// so it never reaches one.
        case commandFailed(step: Int, command: String, exitCode: Int32, message: String)
        case commandTimedOut(step: Int, command: String, seconds: TimeInterval, message: String)
        case runnerFailed(step: Int, command: String, message: String)
        case invalidHostAlias
    }

    /// Invocation in, result out. The stdin field is load-bearing: the bearer
    /// token must never be placed in argv.
    public typealias Runner = @Sendable (Invocation) throws -> RunResult

    public static let defaultRemoteSetupTimeout: TimeInterval = 60
    static let maxCapturedOutputBytes = 64 * 1024

    /// Marketplace reference for a remote host, which has no app bundle to
    /// register a local directory from. `claude plugin marketplace add` accepts
    /// an `owner/repo` shorthand, and the repo root carries a
    /// `.claude-plugin/marketplace.json` listing both plugins for exactly this.
    public static let repositoryMarketplaceReference = "T0mSIlver/localvoxtral"

    /// The plugin's sensitive userConfig key. Claude Code exposes it to the
    /// plugin's COMMAND-hook shim as `CLAUDE_PLUGIN_OPTION_TOKEN`; the shim
    /// hands it to curl through a private header file, never an argv. (It is
    /// NOT available to declarative http hooks — Claude Code expands their
    /// header `${VAR}`s from the process environment only, which is why the
    /// plugin uses a command shim at all; verified on 2.1.220.)
    public static let tokenConfigKey = "token"

    /// The plugin's non-sensitive userConfig key: which loopback port on the
    /// REMOTE host the shim posts to. Reaches the shim as
    /// `CLAUDE_PLUGIN_OPTION_PORT` exactly like the token does (both are
    /// command-hook environment; verified end to end on Claude Code 2.1.220 —
    /// a hook run with `--config port=28777` dialed 127.0.0.1:28777).
    ///
    /// It must equal the listen port of this Mac's `RemoteForward`. The plan
    /// always emits both halves together for that reason; changing one alone
    /// fails open, which looks exactly like nothing happening.
    public static let portConfigKey = "port"

    private let runner: Runner?
    private let sshConfigFileSystem: (any ClaudeRemoteSSHConfigFileSystem)?

    public init(
        runner: Runner? = nil,
        sshConfigFileSystem: (any ClaudeRemoteSSHConfigFileSystem)? = nil
    ) {
        self.runner = runner
        self.sshConfigFileSystem = sshConfigFileSystem
    }

    public static var remotePluginReference: String {
        "\(ClaudePluginAssets.remotePluginName)@\(ClaudePluginAssets.marketplaceName)"
    }

    // MARK: - Plan

    /// Build the setup for one enrolled host.
    ///
    /// - Parameters:
    ///   - sshHostAlias: the `Host` stanza name in `~/.ssh/config`. Validated,
    ///     not escaped — an alias is a bare token and anything else is a mistake
    ///     we should surface rather than quietly rewrite.
    ///   - token: the plaintext used to generate the copyable command and, after
    ///     confirmation, its SSH stdin script. Not stored or logged.
    ///   - listenerPort: the port the app listens on, HERE, on this Mac. The
    ///     forward's target.
    ///   - remoteForwardPort: the port the forward binds THERE, on the remote
    ///     host — this Mac's per-install allocation
    ///     (`ClaudeRemoteForwardPort`), which is what keeps two Macs from
    ///     contending for one bind (issue #215). Defaults to the legacy shared
    ///     port so every existing caller and fixture describes the pre-#215
    ///     setup, which still works.
    public static func plan(
        host: ClaudeRemoteHost,
        sshHostAlias: String,
        token: String,
        listenerPort: UInt16 = ClaudeRemoteListenerLimits.default.port,
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort
    ) throws -> SetupPlan {
        guard isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }

        return SetupPlan(
            sshConfigSnippet: sshConfigSnippet(
                host: host,
                sshHostAlias: sshHostAlias,
                listenerPort: listenerPort,
                remoteForwardPort: remoteForwardPort
            ),
            remoteCommands: remoteCommands(token: token, remoteForwardPort: remoteForwardPort),
            verifyCommands: verifyCommands(
                sshHostAlias: sshHostAlias, remoteForwardPort: remoteForwardPort
            ),
            updateCommands: updateCommands(
                sshHostAlias: sshHostAlias, remoteForwardPort: remoteForwardPort
            ),
            uninstallCommands: uninstallCommands(host: host, sshHostAlias: sshHostAlias),
            notes: notes(listenerPort: listenerPort, remoteForwardPort: remoteForwardPort)
        )
    }

    /// An SSH host alias, as `~/.ssh/config` understands one.
    ///
    /// Deliberately narrow: no whitespace (which would split the `Host` line
    /// into two patterns), no `#` (which would comment out the rest of our
    /// block), no quotes. This is the only user-supplied string that reaches the
    /// generated config, so it is checked rather than escaped — an alias that
    /// needs escaping is not an alias.
    ///
    /// A leading `-` is refused separately from the charset, because `-` is
    /// legal INSIDE a hostname and fatal in front of one: an alias of `-V`
    /// reaches `ssh`'s argv as an option, and OpenSSH then prints its version
    /// and exits 0 without connecting — every step reports success while
    /// nothing ran on any host (review finding, PR #197). Argv termination in
    /// `execute` is the second layer; this is the first, and it is the one that
    /// also covers the commands the user pastes by hand.
    public static func isValidHostAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 128 else { return false }
        guard !alias.hasPrefix("-") else { return false }
        // "." and ".." would name a directory, not a host, and an all-dot alias
        // resolves to nothing anyone meant.
        guard alias.contains(where: { $0 != "." }) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return alias.allSatisfy { allowed.contains($0) }
    }

    static func blockBegin(hostID: String) -> String {
        "# BEGIN localvoxtral claude context (\(hostID))"
    }

    static func blockEnd(hostID: String) -> String {
        "# END localvoxtral claude context (\(hostID))"
    }

    /// The marked ssh-config block for one host. Token-free by construction,
    /// which is what lets the plugin-update path regenerate it for a host whose
    /// one-time token is long gone.
    public static func sshConfigSnippet(
        host: ClaudeRemoteHost,
        sshHostAlias: String,
        listenerPort: UInt16,
        remoteForwardPort: UInt16
    ) -> String {
        """
        \(blockBegin(hostID: host.id))
        Host \(sshHostAlias)
            # \(remoteForwardPort) is THIS Mac's allocated port on the remote host, and
            # it must match the plugin's `port` option there. Another Mac gets a
            # different one, so the two can never fight over one bind — the fight
            # nobody wins twice: the first connection keeps the forward and the
            # second delivers this host's events, and its token, to the wrong Mac.
            RemoteForward \(remoteForwardPort) 127.0.0.1:\(listenerPort)
            # ExitOnForwardFailure no (the default) is deliberate: if the remote
            # already has \(remoteForwardPort) bound — now only by another session from
            # this same Mac — `yes` would refuse to open the SSH session at all.
            # A dictation nicety must never cost you the shell. The cost of `no`
            # is that a failed forward is silent: the hooks get connection
            # refused, fail open, and you simply get no context. The verify step
            # below is how you check.
            ExitOnForwardFailure no
        \(blockEnd(hostID: host.id))
        """
    }

    /// The first-time setup pair.
    ///
    /// Both are idempotent, but only in the weak sense: on a host that already
    /// has them, `marketplace add` exits 0 without refreshing the clone and
    /// `plugin install` exits 0 without changing the installed version (verified
    /// on Claude Code 2.1.220). `install` DOES apply a new `--config token=`,
    /// which is why rotation reuses this exact command — and why shipping a new
    /// plugin version needs `updateCommands` instead.
    /// `--config` is repeatable and MERGES per key on an already-installed
    /// plugin: verified on Claude Code 2.1.220 (`--help` documents "repeatable";
    /// a second install with only `--config port=` kept the stored token and
    /// replaced only the port). That is what makes the port migratable without
    /// ever re-sending a credential.
    static func remoteCommands(token: String, remoteForwardPort: UInt16) -> [String] {
        [
            "claude plugin marketplace add \(repositoryMarketplaceReference)",
            // Leading space: with HISTCONTROL=ignorespace (bash) or
            // HIST_IGNORE_SPACE (zsh) the token stays out of the remote shell
            // history. See `notes` — it is a habit, not a guarantee.
            " claude plugin install \(remotePluginReference) --config '\(tokenConfigKey)=\(token)'"
                + " --config '\(portConfigKey)=\(remoteForwardPort)'",
        ]
    }

    /// The comments are part of the deliverable: these commands are run by a
    /// person, and the field failure was a person reading healthy output as
    /// broken — a forward "failure" that just means another session already
    /// holds the tunnel, and a 401 that is the success signal. Say so in the
    /// output they are pasting, not in a note they have scrolled past.
    static func verifyCommands(sshHostAlias: String, remoteForwardPort: UInt16) -> [String] {
        [
            // -v because a failed RemoteForward is otherwise invisible when
            // ExitOnForwardFailure is `no`. The `grep -q … && echo` shape is
            // deliberate: a person pasting this must be told the FIX, not handed
            // an OpenSSH debug line to interpret. The message is deliberately
            // apostrophe-free so it survives single-quoted shell.
            "# Forward check — does this Mac actually own port \(remoteForwardPort) over there?",
            "# THREE outcomes, not two. A one-line grep for the forwarding warning",
            "# gets both edges wrong, which was measured rather than assumed",
            "# (2026-08-04, OpenSSH 10.0p2 against a live sshd):",
            "#   * your own live session to this host already holds the port, so a",
            "#     fresh probe requesting it fails to bind — a healthy setup that a",
            "#     grep reports as contention (ssh still exits 0),",
            "#   * an unreachable host, bad key or host-key change never gets far",
            "#     enough to request a forward, so the grep finds nothing and a",
            "#     naive check calls it clean (ssh exits 255).",
            "# So: exit status first, warning second.",
            "out=$(ssh -v \(sshHostAlias) true 2>&1); rc=$?; "
                + "if [ $rc -ne 0 ]; then "
                + "echo \"localvoxtral: could not reach \(sshHostAlias) at all (ssh exit $rc) — fix the connection first; "
                + "this says nothing about the port.\"; "
                + "elif echo \"$out\" | grep -q '\(ClaudeRemoteForwardPort.forwardFailureSignature)'; then "
                + "echo \"localvoxtral: port \(remoteForwardPort) is already bound on \(sshHostAlias). "
                + "If you have another session open to \(sshHostAlias) from THIS Mac, that is expected and healthy — "
                + "the first one keeps the forward. If you do not, "
                + "\(ClaudeRemoteForwardPort.contentionMessage(port: remoteForwardPort, host: sshHostAlias)) "
                + "and this Mac is getting no context from it.\"; "
                + "else echo \"localvoxtral: port \(remoteForwardPort) forwards cleanly to this Mac.\"; fi",
            "# Non-interactive SSH skips your shell rc, so claude can be off PATH",
            "# here even though it runs fine when you are logged in.",
            "ssh \(sshHostAlias) '\(nonInteractiveClaudePathPrefix)claude plugin list'",
            "# 401 = SUCCESS: the tunnel is up and localvoxtral answered (an",
            "# unauthenticated probe must be refused). A connection error means",
            "# no live session holds the forward right now.",
            "ssh \(sshHostAlias) 'curl -s -o /dev/null -w \"%{http_code}\\n\" -X POST "
                + "-H \"Content-Type: application/json\" -d \"{}\" http://127.0.0.1:\(remoteForwardPort)/v1/hook/SessionStart'",
        ]
    }

    /// PATH prefix for a `claude` invocation inside `ssh <host> '<command>'`.
    ///
    /// Non-interactive SSH skips the login rc, so `claude` is routinely off PATH
    /// there on a host where it works fine interactively. The stdin script has
    /// its own resolver (`claudePathResolverPreamble`); this is the one-liner
    /// equivalent for the commands a person pastes.
    static let nonInteractiveClaudePathPrefix =
        "PATH=\"$HOME/.claude/local:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" "

    /// The remote-side commands, in order, with nothing wrapped around them.
    /// Execution sends these through the SSH stdin script;
    /// `updateCommands(sshHostAlias:remoteForwardPort:)` is the same set written
    /// for a person to paste from this Mac.
    ///
    /// The third command is the port MIGRATION, and it is why update takes a
    /// port at all: a host enrolled before #215 has no `port` option, so its
    /// shim posts to the legacy 8473 while this Mac has moved its forward to an
    /// allocated one — two halves that disagree, failing open in silence.
    /// `plugin update` has no `--config` (Claude Code 2.1.220), and `install`
    /// on an installed plugin merges config per key without touching the stored
    /// token, so this line is both the only way and a token-free one.
    static func remotePluginUpdateCommands(remoteForwardPort: UInt16) -> [String] {
        [
            "claude plugin marketplace update \(ClaudePluginAssets.marketplaceName)",
            "claude plugin update \(remotePluginReference)",
            "claude plugin install \(remotePluginReference) --config '\(portConfigKey)=\(remoteForwardPort)'",
        ]
    }

    /// Bring an enrolled host to the plugin version this app ships.
    ///
    /// The comments are part of the deliverable, as in `verifyCommands`: nothing
    /// else in the product tells the user that re-running setup is not an
    /// update, and a host silently left on an old plugin fails open — i.e. it
    /// looks like nothing at all.
    static func updateCommands(sshHostAlias: String, remoteForwardPort: UInt16) -> [String] {
        let commands = remotePluginUpdateCommands(remoteForwardPort: remoteForwardPort)
        return [
            "# Run after updating localvoxtral on this Mac. This set is the ONLY",
            "# way a plugin fix reaches a host that is already enrolled: on Claude",
            "# Code 2.1.220, re-running `plugin install` exits 0 with \"already",
            "# installed\" and leaves the old version in place, and `marketplace",
            "# add` does not refresh a clone it already has. Your token is kept —",
            "# `plugin update` preserves the stored config, and the third command",
            "# below sets only the port (install merges config per key).",
            "ssh \(sshHostAlias) '\(nonInteractiveClaudePathPrefix)\(commands[0])'",
            "ssh \(sshHostAlias) '\(nonInteractiveClaudePathPrefix)\(commands[1])'",
            "# Point this host at THIS Mac's allocated port \(remoteForwardPort). Required once",
            "# for a host enrolled before per-Mac ports; harmless every time after.",
            "ssh \(sshHostAlias) '\(nonInteractiveClaudePathPrefix)\(commands[2])'",
        ]
    }

    static func uninstallCommands(host: ClaudeRemoteHost, sshHostAlias: String) -> [String] {
        [
            "ssh \(sshHostAlias) 'claude plugin uninstall \(remotePluginReference)'",
            "ssh \(sshHostAlias) 'claude plugin marketplace remove \(ClaudePluginAssets.marketplaceName)'",
            "# then remove the \(blockBegin(hostID: host.id)) block from ~/.ssh/config",
            "# and revoke \(host.id) in localvoxtral — revocation is what actually",
            "# stops the host: the token dies here, not on the remote.",
        ]
    }

    static func notes(listenerPort: UInt16, remoteForwardPort: UInt16) -> [String] {
        [
            "This Mac forwards port \(remoteForwardPort) on the remote host to localvoxtral on "
                + "127.0.0.1:\(listenerPort) here. The ssh-config block and the plugin's `port` option "
                + "must name the same \(remoteForwardPort): change one without the other and the hooks "
                + "post into a port nothing forwards — which fails open, i.e. looks like nothing at "
                + "all. The setup commands always carry both halves.",
            "The port is allocated per Mac, so a second Mac enrolled against this same host gets a "
                + "different one and the two can never contend for one bind. What they still share is "
                + "the host: one Claude Code install stores one `port`, so the most recently installed "
                + "config is the Mac that receives events. The other simply sees no traffic — no "
                + "longer someone else's events, and never someone else's token.",
            "The token authorizes remote context only. A host that presents it can never "
                + "make localvoxtral read a local file: the listener tags every session it accepts "
                + "as remote regardless of what the payload says, and a remote cwd cannot be turned "
                + "into a local path.",
            "Revoking the host in localvoxtral is the real off switch and takes effect immediately. "
                + "Uninstalling the remote plugin only stops it asking.",
            "The copied install command puts the token in the remote shell's history unless your shell is "
                + "set to ignore space-prefixed commands (HISTCONTROL=ignorespace / setopt "
                + "HIST_IGNORE_SPACE). If it landed there, rotate the token — that is what rotation "
                + "is for.",
            "tmux/screen: a multiplexer owns the window title, so the OSC 2 marker the hook writes "
                + "does not reach Ghostty by default and the pane stays unjoined. `set -g "
                + "set-titles on` in ~/.tmux.conf lets tmux pass the title through. Without it you "
                + "still get the off-screen context (prompt, cwd, files) — you just do not get the "
                + "screen join.",
            "Plain `ssh` with no enrollment keeps working exactly as before: no tunnel, no token, no "
                + "hooks, and the pane stays screen-only and unjoined.",
            "The plugin needs only POSIX `sh` and `curl` on the remote host — no localvoxtral binary. "
                + "Its hooks fail open silently when either is missing, the tunnel is down, or the app "
                + "is not answering: you simply get no context, never a blocked Claude turn.",
            "While a session holds the tunnel and localvoxtral is not running, ssh itself — on this "
                + "Mac — prints `connect_to 127.0.0.1 port \(listenerPort): failed.` into the remote "
                + "terminal on every dial; the plugin cannot silence another process. So after a "
                + "failed dial its hooks back off for five minutes; prompt submits still try, so "
                + "context returns with your first prompt once the app is back.",
            "A second concurrent SSH session from this Mac to the same host will fail to bind "
                + "\(remoteForwardPort) on the remote and — because ExitOnForwardFailure is `no` — will "
                + "connect anyway with no tunnel. The first session keeps the forward, and the verify "
                + "step above is how you tell that apart from a broken setup.",
            "Hook events only reach this Mac while something holds the tunnel — normally one of "
                + "your own SSH sessions. Sessions a harness starts on the host (t3 code, "
                + "`claude remote-control` services, any headless runner) have no such terminal, so "
                + "their context goes nowhere. Turn on \"Keep the tunnel open\" in this host's row "
                + "and the app holds the forward itself, reconnecting as needed.",
            "One-click setup connects with forwarding disabled (the tunnel belongs to your real "
                + "sessions, not setup) and first resolves `claude` from common install locations — "
                + "non-interactive SSH shells often lack the user-local PATH entries an interactive "
                + "login has.",
        ]
    }

    // MARK: - SSH config editing

    /// Insert or replace this host's block in an ssh config's text.
    ///
    /// Idempotent by delimiter: applying the same snippet twice yields the same
    /// text, because the second application finds and replaces the first block
    /// rather than appending a duplicate `Host` stanza (which OpenSSH would
    /// resolve as first-match-wins, so a stale duplicate above a fresh one would
    /// silently win).
    ///
    /// Everything outside the delimited block is preserved byte for byte. This
    /// function is the whole reason a UI could ever offer to make the edit —
    /// but it is still the caller's decision to write the result anywhere.
    public static func applySSHConfigSnippet(
        to existing: String,
        snippet: String,
        hostID: String
    ) -> String {
        let begin = blockBegin(hostID: hostID)
        let end = blockEnd(hostID: hostID)
        let lines = existing.components(separatedBy: "\n")

        guard let beginIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }),
              let endIndex = lines[beginIndex...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == end
              })
        else {
            // No block yet: append after a blank line, so our `Host` stanza can
            // never fuse onto the end of someone else's (an indented keyword
            // under the wrong `Host` is a config change they did not ask for).
            //
            // The exact spacing matters for idempotency, not for looks: the
            // replace branch above reproduces this layout byte for byte, so a
            // second apply is a no-op.
            var prefix = existing
            if !prefix.isEmpty, !prefix.hasSuffix("\n") { prefix += "\n" }
            if !prefix.isEmpty, !prefix.hasSuffix("\n\n") { prefix += "\n" }
            return prefix + snippet + "\n"
        }

        var result = Array(lines[..<beginIndex])
        result.append(contentsOf: snippet.components(separatedBy: "\n"))
        result.append(contentsOf: lines[(endIndex + 1)...])
        return result.joined(separator: "\n")
    }

    /// Remove this host's block, leaving everything else untouched.
    public static func removeSSHConfigSnippet(from existing: String, hostID: String) -> String {
        let begin = blockBegin(hostID: hostID)
        let end = blockEnd(hostID: hostID)
        let lines = existing.components(separatedBy: "\n")
        guard let beginIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }),
              let endIndex = lines[beginIndex...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == end
              })
        else {
            return existing
        }
        var result = Array(lines[..<beginIndex])
        result.append(contentsOf: lines[(endIndex + 1)...])
        return result.joined(separator: "\n")
    }

    /// Atomically insert or replace one host's marked block in `~/.ssh/config`.
    /// The caller is responsible for obtaining the user's explicit confirmation
    /// immediately before calling this method.
    public func insertSSHConfig(_ plan: SetupPlan, hostID: String) throws {
        try insertSSHConfig(snippet: plan.sshConfigSnippet, hostID: hostID)
    }

    /// Same write, for a caller that has a block but no plan — the plugin
    /// update path, which regenerates this host's block so the port it is
    /// about to store on the remote and the port this Mac forwards can never
    /// disagree.
    public func insertSSHConfig(snippet: String, hostID: String) throws {
        Log.claudeContext.info("Claude remote ssh config insertion requested")
        guard let sshConfigFileSystem else {
            Log.claudeContext.error("Claude remote ssh config insertion failed: editing not configured")
            throw ServiceError.sshConfigEditingNotConfigured
        }
        do {
            let state = try sshConfigFileSystem.readState()
            // Trust gate before any write decision: never write through a
            // symlink, and never into a directory another principal can also
            // write. The copy path stays available for such setups.
            guard !state.configIsSymlink, !state.directoryIsSymlink else {
                throw ServiceError.sshConfigIsSymlink
            }
            if state.directoryExists {
                guard state.directoryOwnedByCurrentUser,
                      (state.directoryPermissions ?? 0) & 0o022 == 0
                else { throw ServiceError.sshDirectoryNotTrusted }
            }
            let existing: String
            if let data = state.configData {
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw ServiceError.invalidSSHConfigEncoding
                }
                existing = decoded
            } else {
                existing = ""
            }
            let updated = Self.applySSHConfigSnippet(
                to: existing,
                snippet: snippet,
                hostID: hostID
            )
            if !state.directoryExists {
                try sshConfigFileSystem.createSSHDirectory(permissions: 0o700)
            }
            try sshConfigFileSystem.atomicWriteConfig(
                Data(updated.utf8),
                permissions: state.configPermissions ?? 0o600
            )
            Log.claudeContext.info("Claude remote ssh config insertion completed")
        } catch {
            Log.claudeContext.error(
                "Claude remote ssh config insertion failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// Does this host's marked block already forward `port`?
    ///
    /// `nil` means "cannot tell" — no filesystem seam, or a config we refuse to
    /// read. Callers must treat nil as "not known to match" and regenerate,
    /// never as "fine": assuming a block is current is exactly how a plugin
    /// gets a port this Mac does not forward.
    public func sshConfigForwardsPort(_ port: UInt16, hostID: String) -> Bool? {
        guard let sshConfigFileSystem else { return nil }
        guard let state = try? sshConfigFileSystem.readState(),
              let data = state.configData,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let begin = Self.blockBegin(hostID: hostID)
        let end = Self.blockEnd(hostID: hostID)
        let lines = text.components(separatedBy: "\n")
        guard let beginIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == begin
        }), let endIndex = lines[beginIndex...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == end
        }) else { return false }
        return lines[beginIndex...endIndex].contains { line in
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0] == "RemoteForward" else { return false }
            return fields[1] == "\(port)"
        }
    }

    // MARK: - Execution (opt-in only)

    /// Run the plan's remote commands through the injected runner.
    ///
    /// Throws `.executionNotConfigured` when no runner was supplied. Each plan
    /// command is sent to `/bin/sh -s` over SSH stdin. The only spawned argv is
    /// `ssh -o BatchMode=yes -o ClearAllForwardings=yes <alias> /bin/sh -s`,
    /// which contains no token.
    ///
    /// - Parameter token: the plaintext, used ONLY to redact it back out of any
    ///   failure. Nothing here logs or stores it.
    @discardableResult
    public func executeRemoteSetup(
        _ plan: SetupPlan,
        sshHostAlias: String,
        token: String,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> [ExecutionStep] {
        try execute(
            commands: plan.remoteCommands,
            sshHostAlias: sshHostAlias,
            token: token,
            timeout: timeout,
            label: "setup"
        )
    }

    /// Update the remote plugin on an already-enrolled host.
    ///
    /// Token-free by construction: `claude plugin update` preserves the config
    /// the install stored, so this path never has the credential to leak. It is
    /// a separate entry point rather than a plan step because the user runs it
    /// long after enrollment — when the app ships a new plugin version — and by
    /// then the one-time token is gone.
    @discardableResult
    public func executeRemotePluginUpdate(
        sshHostAlias: String,
        remoteForwardPort: UInt16 = ClaudeRemoteForwardPort.legacyPort,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> [ExecutionStep] {
        try execute(
            commands: Self.remotePluginUpdateCommands(remoteForwardPort: remoteForwardPort),
            sshHostAlias: sshHostAlias,
            token: "",
            timeout: timeout,
            label: "plugin update"
        )
    }

    private func execute(
        commands: [String],
        sshHostAlias: String,
        token: String,
        timeout: TimeInterval,
        label: String
    ) throws -> [ExecutionStep] {
        Log.claudeContext.info("Claude remote \(label, privacy: .public) execution requested")
        guard let runner else {
            Log.claudeContext.error(
                "Claude remote \(label, privacy: .public) execution failed: runner not configured"
            )
            throw ServiceError.executionNotConfigured
        }
        guard Self.isValidHostAlias(sshHostAlias) else {
            Log.claudeContext.error(
                "Claude remote \(label, privacy: .public) execution failed: invalid host alias"
            )
            throw ServiceError.invalidHostAlias
        }
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var completed: [ExecutionStep] = []
        for (index, command) in commands.enumerated() {
            let displayCommand = ClaudeRemoteTokenRedaction.redact(
                command.trimmingCharacters(in: .whitespaces),
                token: token
            )
            let remaining = max(deadline.timeIntervalSinceNow, 0)
            guard remaining > 0 else {
                let failure = ServiceError.commandTimedOut(
                    step: index, command: displayCommand, seconds: timeout, message: ""
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            let invocation = Invocation(
                // ClearAllForwardings: this connection has no use for the
                // 8473 tunnel, and with the user's own session usually holding
                // it, attempting the forward here only produced a scary
                // "remote port forwarding failed" warning inside setup errors
                // (field report 2026-07-26).
                // `--` ends OpenSSH's option parsing: the alias is validated
                // above and cannot start with `-`, and this makes an alias that
                // somehow did reach here a failed connection rather than a
                // silently successful option.
                argv: [
                    "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                    sshHostAlias, "/bin/sh", "-s",
                ],
                standardInput: Self.remoteScript(command: command),
                timeout: remaining
            )
            Log.claudeContext.info(
                "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) requested"
            )
            let result: RunResult
            do {
                result = try runner(invocation)
            } catch let failure as RunnerFailure {
                let error: ServiceError
                switch failure {
                case .timedOut(let seconds, let message):
                    error = .commandTimedOut(
                        step: index,
                        command: displayCommand,
                        seconds: seconds,
                        message: ClaudeRemoteTokenRedaction.redact(message, token: token)
                    )
                case .outputTooLarge(_, let message):
                    error = .runnerFailed(
                        step: index,
                        command: displayCommand,
                        message: ClaudeRemoteTokenRedaction.redact(message, token: token)
                    )
                }
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                throw error
            } catch {
                let redacted = ClaudeRemoteTokenRedaction.redact(String(describing: error), token: token)
                let failure = ServiceError.runnerFailed(
                    step: index, command: displayCommand, message: redacted
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            guard result.succeeded else {
                let failure = ServiceError.commandFailed(
                    step: index,
                    command: displayCommand,
                    exitCode: result.exitCode,
                    message: ClaudeRemoteTokenRedaction.redact(result.message, token: token)
                )
                Log.claudeContext.error(
                    "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                throw failure
            }
            completed.append(
                ExecutionStep(
                    index: index,
                    command: displayCommand,
                    message: ClaudeRemoteTokenRedaction.redact(result.message, token: token)
                )
            )
            Log.claudeContext.info(
                "Claude remote \(label, privacy: .public) step \(index + 1, privacy: .public) completed"
            )
        }
        Log.claudeContext.info("Claude remote \(label, privacy: .public) execution completed")
        return completed
    }

    /// PATH resolution for `claude` under `ssh <host> /bin/sh -s`.
    ///
    /// Non-interactive SSH shells run with sshd's minimal PATH (no login rc),
    /// which usually lacks the user-local directories claude installs into —
    /// the field failure was dash's bare `claude: not found` on a host where
    /// claude worked fine interactively. Probe the same locations the local
    /// installer does (`ClaudePluginInstallService.claudeCLICandidates`), plus
    /// nvm-style node bins, and fail with an actionable message instead of
    /// dash's. POSIX sh only — the remote /bin/sh is dash on Debian-family
    /// hosts. Token-free by construction, like the `set -eu` line: the
    /// confirmation shows the commands the user authorizes; this is part of
    /// how they run.
    static let claudePathResolverPreamble = """
        if ! command -v claude >/dev/null 2>&1; then
          for lv_dir in "$HOME/.claude/local" "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin "$HOME"/.nvm/versions/node/*/bin; do
            if [ -x "$lv_dir/claude" ]; then PATH="$lv_dir:$PATH"; break; fi
          done
        fi
        if ! command -v claude >/dev/null 2>&1; then
          echo "localvoxtral: 'claude' was not found on this host's non-interactive PATH, nor in ~/.claude/local, ~/.local/bin, ~/bin, /opt/homebrew/bin, /usr/local/bin, or ~/.nvm/versions/node/*/bin. Run 'command -v claude' in a normal shell on this host, then rerun setup — or add that directory to PATH for non-interactive SSH shells." >&2
          exit 127
        fi

        """

    static func remoteScript(command: String) -> Data {
        // The resolver only guards commands that actually invoke claude, so a
        // future non-claude step cannot be failed by a missing CLI it never
        // needed.
        let preamble = command.contains("claude") ? claudePathResolverPreamble : ""
        return Data("set -eu\n\(preamble)\(command)\n".utf8)
    }
}
