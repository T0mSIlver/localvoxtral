import Foundation

#if canImport(Darwin)
import Darwin

/// What an ssh remote command says about herdr — a CLASSIFICATION, not a
/// boolean, because "mentions herdr first" spans shapes that display entirely
/// different things (verified against herdr v0.8.0 / protocol 19, 2026-08-06):
///
/// * a bare client attach displays the server's GLOBAL focused pane — herdr
///   focus is server-global and multi-client attach is a mirror
///   (`src/app/api/panes.rs::handle_pane_current`, `tests/multi_client.rs`),
///   which is the semantic the whole remote arm reads through `pane.current`;
/// * `herdr terminal attach <id>` renders exactly ONE pane, and
///   `herdr --session <name>` attaches a DIFFERENT server (named sessions have
///   separate sockets) — joining the global focus of the candidates' socket
///   while the user looks at either of those is a mis-join reachable with a
///   single connection, which is why the boolean had to go.
enum HerdrInvocation: Sendable, Equatable {
    /// The remote command is not herdr (or there is no remote command).
    case notHerdr
    /// A bare `herdr` whole-view client attach — the only shape whose display
    /// is the server's global focus. `sessionSelector` is the normalized
    /// `--session` value (nil = the default session); two connections display
    /// the same server only when their selectors are byte-identical.
    case plainClient(sessionSelector: String?)
    /// herdr with any other subcommand or flag shape: single-pane attaches,
    /// observers, named-session verbs, `server`, or tokens this classifier
    /// does not know. Refused by the arm — never a join, never a guess.
    case otherHerdrSubcommand
}

/// The ssh connection a terminal surface is displaying, as far as the local
/// process table can prove it.
struct SSHSurfaceConnection: Sendable, Equatable {
    /// Normalized destination host/alias.
    var destination: String
    /// Another terminal on this machine hosts an ssh to the same destination
    /// that COULD be displaying a different herdr view: a herdr client with a
    /// different session selector, a single-pane herdr attach, or an ssh whose
    /// argv cannot rule herdr out.
    ///
    /// This is deliberately narrower than the original "only connection to
    /// the destination" rule. What that rule actually protected against is a
    /// surface joining a herdr view it is not displaying — and a plain shell
    /// on another tty can never be that: the probe only ever reads the FOCUSED
    /// surface's tty, and herdr focus is server-global with mirror attach
    /// (verified in herdr source, 2026-08-06), so even a second client of the
    /// SAME server displays the same focused pane. What still competes is a
    /// client of a DIFFERENT server (session selector mismatch), a single-pane
    /// attach, or anything unreadable enough that it might be one.
    var hasCompetingHerdrClient: Bool
    /// The classified herdr invocation of THIS connection's remote command.
    /// Binds the CONNECTION to herdr, which no amount of host-level reasoning
    /// can — argv here is the exec-time vector of a VERIFIED OpenSSH binary,
    /// i.e. the command ssh actually ran, not a self-report.
    var herdr: HerdrInvocation
    /// The argv named a jump host (`-J`). The connection this process opens
    /// then goes to the JUMP host, while the destination's sshd sees the jump
    /// host's source port — so the local socket and the remote
    /// `$SSH_CONNECTION` describe two different connections and can never be
    /// compared. Recorded rather than refused: the herdr arm has always
    /// accepted `-J` (it never looks at a socket), and only the plain-ssh arm
    /// must abstain on it.
    var usesProxyJump: Bool
    /// The ESTABLISHED TCP sockets of the surface's ssh process, or nil when
    /// the fd table could not be read. Nil is UNREADABLE, never "none": an
    /// empty array is a positive claim about a process and a failed syscall
    /// is not one.
    var sockets: [SSHClientSocket]?
    /// Another same-uid ssh CONNECTION to this destination holds no
    /// established TCP socket of its own — the shape of an OpenSSH
    /// **ControlMaster mux client**, and the one way a session's
    /// `$SSH_CONNECTION` can be honest and still describe a different
    /// terminal's surface.
    ///
    /// With `ControlMaster auto` in `~/.ssh/config` (invisible in argv — the
    /// probe refuses `-M`/`-S` but does not read config), terminal A's ssh
    /// owns the TCP connection and terminal B's `ssh host` is a mux client
    /// over an AF_UNIX control path with no TCP socket at all. sshd derives
    /// `$SSH_CONNECTION` from the underlying CONNECTION, so a Claude session
    /// started in B truthfully reports A's ports; dictating into A — a plain
    /// shell with no agent in it — would then match and join B's session.
    /// Found by review, 2026-09-05.
    ///
    /// So the flag is about a NEIGHBOR, not about this process: a socketless
    /// (or unreadable) sibling to the same destination means connection
    /// multiplexing cannot be ruled out, and the plain-ssh arm abstains. It
    /// costs the ordinary two-terminals-two-connections case nothing — those
    /// each hold their own socket and are told apart by their ports.
    var hasSocketlessSiblingToDestination: Bool

    init(
        destination: String,
        hasCompetingHerdrClient: Bool,
        herdr: HerdrInvocation,
        usesProxyJump: Bool = false,
        sockets: [SSHClientSocket]? = nil,
        hasSocketlessSiblingToDestination: Bool = false
    ) {
        self.destination = destination
        self.hasCompetingHerdrClient = hasCompetingHerdrClient
        self.herdr = herdr
        self.usesProxyJump = usesProxyJump
        self.sockets = sockets
        self.hasSocketlessSiblingToDestination = hasSocketlessSiblingToDestination
    }
}

/// WHY the probe could not pin an ssh session down. Deliberately content-free
/// — a category, never a path, host, or option letter — so it is safe to put
/// in the log and the dogfood record. Three field dictations were diagnosed
/// blind (2026-08-06) because every branch collapsed into one word; the cause
/// had to be reconstructed from the REMOTE host's process table.
enum SSHProbeIndeterminacy: String, Sendable, Equatable {
    /// The tty device path did not resolve.
    case deviceUnreadable = "device unreadable"
    /// The machine-wide process scan failed. Not evidence of absence.
    case tableUnreadable = "process table unreadable"
    /// More than one foreground ssh CONNECTION on the surface.
    case multipleForegroundClients = "multiple foreground ssh"
    /// The surface process's executable is not one we trust to be OpenSSH.
    case untrustedExecutable = "untrusted executable"
    /// The surface process's argv could not be read.
    case unreadableArguments = "unreadable argv"
    /// The argv was read and refused: a destination-moving or non-interactive
    /// option, an unknown option letter, or a destination shape outside the
    /// grammar.
    case refusedArguments = "refused argv"
    /// The seam default: no live probe was injected, so the arm is disabled.
    case probeUnavailable = "probe unavailable"
}

/// What the process table says about ssh clients on ONE terminal device.
///
/// Three answers, and the difference between the last two is the whole point:
/// "there is no ssh session here" is a fact the resolver can act on (fall
/// through to the arms that do not involve another machine), while "I could not
/// tell" must stop the remote arm dead.
enum SSHDestinationTTYProbeResult: Sendable, Equatable {
    /// No foreground ssh session on this device.
    case noSSHClient
    case connection(SSHSurfaceConnection)
    /// An ssh session is there and cannot be pinned down: argv unavailable, an
    /// unverifiable executable, an option that can move the destination, a
    /// grammar we do not recognize — or MORE THAN ONE foreground ssh on the
    /// surface, whatever their destinations. Two to the same host abstain just
    /// as two to different hosts do: nothing here says which one the user is
    /// looking at, and unioning them let one borrow the other's herdr signal.
    /// The payload says WHICH refusal fired — it changes logging, never the
    /// abstention.
    case undeterminable(SSHProbeIndeterminacy)
}

/// One ssh process as the probe sees it.
struct SSHClientProcess: Sendable, Equatable {
    var pid: Int32
    /// Kernel-reported parent pid (`e_ppid`). This is what lets ProxyJump
    /// machinery be told apart from a connection: OpenSSH spawns its `-W`
    /// stdio-forward hop as a direct CHILD, and ppid is kernel truth — unlike
    /// argv, no launcher gets to choose it.
    var parentPID: Int32
    /// Controlling terminal device, or nil when it has none. A process with no
    /// terminal is not a surface anyone can be dictating into — our OWN
    /// `ssh -L` forward is exactly that, which is why it must not count.
    var ttyDevice: dev_t?
    var processGroupID: Int32
    /// The foreground process group of its controlling terminal.
    var terminalForegroundGroupID: Int32
    /// Kernel credential (`e_ucred.cr_uid`), never self-reported. A process
    /// owned by another user stays visible to the SURFACE question — a
    /// `sudo ssh` in this terminal's foreground must abstain, not vanish —
    /// but it is invisible to the competing-view scan, and its executable
    /// path and argv are never read (they would fail cross-uid anyway).
    /// The default exists for test convenience only; the live scan always
    /// stamps the real credential.
    var effectiveUserID: uid_t
    /// Resolved executable path (`proc_pidpath`), not argv[0] and not `p_comm`.
    var executablePath: String?
    var arguments: [String]?

    init(
        pid: Int32,
        parentPID: Int32 = 0,
        ttyDevice: dev_t?,
        processGroupID: Int32,
        terminalForegroundGroupID: Int32,
        effectiveUserID: uid_t = 0,
        executablePath: String?,
        arguments: [String]?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.ttyDevice = ttyDevice
        self.processGroupID = processGroupID
        self.terminalForegroundGroupID = terminalForegroundGroupID
        self.effectiveUserID = effectiveUserID
        self.executablePath = executablePath
        self.arguments = arguments
    }

    /// Is this process the one the terminal is currently giving input to?
    var isForegroundOfItsTerminal: Bool {
        ttyDevice != nil && processGroupID == terminalForegroundGroupID
    }
}

/// Reads the local process table to answer "is the focused terminal surface an
/// ssh session, to where, and is it the only one?".
///
/// This is the binding that makes a REMOTE herdr join safe. Without it, a live
/// remote herdr whose focused pane hosts a Claude session would join whatever
/// the user is looking at locally, because every other check in that arm is
/// about the REMOTE side.
///
/// The posture is `HerdrClientTTYProbe`'s — same-user process table only,
/// injected seams, every metadata failure abstains — with three additional
/// refusals the review demanded, all of them ways an argv can name one host
/// while the connection goes somewhere else:
///
/// * the EXECUTABLE is verified (`proc_pidpath`), not `p_comm` and not argv[0];
/// * the process must be in its terminal's FOREGROUND process group, so a
///   stopped ssh, a background one, or an ssh spawned by `scp`/`rsync` cannot
///   be mistaken for the session on screen;
/// * any option that can move the destination or means "this is not an
///   interactive session" — `-o` (HostName/Port/User/ProxyJump/…) except
///   destination-inert `SetEnv`/`SendEnv`, `-F`, `-O`, `-S`, `-N`, `-f`, `-M`,
///   `-D`, `-W`, `-w` — ABSTAINS instead of being skipped.
enum SSHDestinationTTYProbe {
    /// The only executables we are willing to believe are OpenSSH: three exact
    /// absolute paths, the system client plus Homebrew's on both architectures.
    ///
    /// PREFIXES were the earlier rule and they were forgeable: anything under
    /// `/opt/homebrew/` or `/usr/local/` whose basename was `ssh` passed, so a
    /// compiled `/opt/homebrew/tmp/ssh` with a crafted argv was trusted (review
    /// round 3, blocker 2). Those directories are user-writable, which is the
    /// whole problem — an exact path is a claim about ONE file.
    static let canonicalSSHExecutablePaths = [
        "/usr/bin/ssh",
        "/opt/homebrew/bin/ssh",
        "/usr/local/bin/ssh",
    ]

    /// Is this the executable of a process we will read a destination from?
    ///
    /// `proc_pidpath` reports the RESOLVED path, and Homebrew's `bin/ssh` is a
    /// symlink into the Cellar — so a Cellar path is accepted only when it is
    /// what resolving one of the canonical paths above actually produces. That
    /// keeps the Homebrew case working without trusting the directory it lives
    /// in: `/opt/homebrew/Cellar/openssh/9.9p1/bin/ssh` passes only while
    /// `/opt/homebrew/bin/ssh` points at exactly it.
    ///
    /// - Parameter resolvedPath: injected so the Cellar rule is testable on a
    ///   machine that has no Homebrew (and so a test can prove an impostor in
    ///   the same tree is still refused).
    static func isTrustedSSHExecutable(
        _ path: String,
        resolvedPath: (String) -> String? = { canonicalPath(of: $0) }
    ) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if canonicalSSHExecutablePaths.contains(path) { return true }
        // The symlink-target rule, and every clause of it earns its place. The
        // first version accepted ANYTHING a canonical path resolved to, so
        // repointing `/opt/homebrew/bin/ssh` at a same-tree
        // `…/bin/ssh-impostor` was trusted (review round 4, blocker 1).
        //
        // Honest about what this is: an attacker who can repoint that symlink
        // already controls what the USER's own `ssh` runs, so this is
        // defense-in-depth against a sloppy target, not a privilege boundary.
        // It does make the accepted set describable — "the file Homebrew's
        // `ssh` actually is" — instead of "whatever that name happens to point
        // at today".
        guard (path as NSString).lastPathComponent == "ssh" else { return false }
        return canonicalSSHExecutablePaths.contains { canonical in
            guard resolvedPath(canonical) == path else { return false }
            // A resolved path must stay inside the tree its canonical name
            // lives in: `/opt/homebrew/bin/ssh` may resolve into
            // `/opt/homebrew/Cellar/…`, never into `/tmp`.
            guard let root = installationRoot(ofCanonicalPath: canonical) else { return false }
            return path.hasPrefix(root + "/")
        }
    }

    /// `/opt/homebrew/bin/ssh` → `/opt/homebrew`; `/usr/bin/ssh` → `/usr`.
    ///
    /// The prefix is derived from the canonical path rather than listed, so a
    /// new canonical entry cannot forget to bring its own boundary.
    static func installationRoot(ofCanonicalPath canonical: String) -> String? {
        let binDirectory = (canonical as NSString).deletingLastPathComponent
        guard (binDirectory as NSString).lastPathComponent == "bin" else { return nil }
        let root = (binDirectory as NSString).deletingLastPathComponent
        return root.isEmpty || root == "/" ? nil : root
    }

    /// `realpath(3)`, or nil when the path does not resolve.
    static func canonicalPath(of path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func connection(onTTYDevicePath path: String) -> SSHDestinationTTYProbeResult {
        connection(
            onTTYDevicePath: path,
            deviceID: TTYProcessTable.liveDeviceID,
            sshProcesses: liveSSHProcesses,
            readSockets: SSHProcessSocketReader.live
        )
    }

    /// Pure over the two live reads, so the whole truth table is unit-testable
    /// without a real ssh on a real tty.
    ///
    /// - Parameter sshProcesses: EVERY ssh process on the machine, not just this
    ///   device's — the uniqueness question is machine-wide by definition.
    /// - Parameter readSockets: the surface ssh process's established TCP
    ///   sockets. DEFAULTS TO UNREADABLE so a test that forgets to inject can
    ///   never reach the kernel's fd tables, and so every caller that has no
    ///   business with sockets keeps the pre-existing behaviour: the only arm
    ///   that reads them treats nil as an abstention.
    static func connection(
        onTTYDevicePath path: String,
        deviceID: @Sendable (String) -> dev_t?,
        sshProcesses: @Sendable () -> [SSHClientProcess]?,
        readSockets: @Sendable (Int32) -> [SSHClientSocket]? = { _ in nil }
    ) -> SSHDestinationTTYProbeResult {
        guard let device = deviceID(path) else {
            // A device we cannot resolve is not evidence of absence.
            return .undeterminable(.deviceUnreadable)
        }
        guard let processes = sshProcesses() else {
            return .undeterminable(.tableUnreadable)
        }

        // CONNECTIONS are the ssh processes with no ssh parent. OpenSSH spawns
        // its own helpers as direct children — a ProxyJump's `ssh -W` hop, on
        // the SAME tty and in the SAME foreground process group as the session
        // it carries (field abstention, 2026-08-06) — and such machinery is
        // not a second connection anywhere below: not on the surface, and not
        // in the uniqueness claim (its connection is its root, which is always
        // also in this scan). The partition rides kernel ppid, which no
        // launcher gets to write, so it cannot be used to HIDE a connection:
        // only a real ssh parent demotes a process, and that parent is
        // counted. A shell-mediated ProxyCommand (sh alive between the two
        // sshs) stays a root and still abstains — refusing to guess there is
        // cheaper than trusting one un-attested hop.
        let connections = processes.filter { !hasSSHParent($0, in: processes) }

        // Only the foreground process group of THIS terminal can be what the
        // user is looking at. A backgrounded or stopped ssh on the same device
        // means the surface is showing the shell, not a remote session.
        let onSurface = connections.filter {
            $0.ttyDevice == device && $0.isForegroundOfItsTerminal
        }
        guard !onSurface.isEmpty else { return .noSSHClient }

        // EXACTLY ONE foreground ssh connection, or nothing. The first version
        // combined several — one destination set, `indicatesHerdr` OR-ed across
        // them — and that union was itself a mis-join (review round 7): a
        // foreground group holding both `ssh builder` and `ssh builder herdr`
        // reported "unique" AND "is herdr", so the plain, visible connection
        // joined the other process's herdr session. A pipeline or wrapper that
        // launches several ssh children in one group is the same shape — and
        // stays refused: siblings have no ssh parent, so the machinery rule
        // never reduces them to one.
        //
        // There is no way to tell from here WHICH of them the user is looking
        // at, and this arm's rule is to abstain rather than guess.
        guard onSurface.count == 1, let surfaceProcess = onSurface.first else {
            return .undeterminable(.multipleForegroundClients)
        }
        guard let executablePath = surfaceProcess.executablePath,
              isTrustedSSHExecutable(executablePath)
        else { return .undeterminable(.untrustedExecutable) }
        guard let arguments = surfaceProcess.arguments else {
            return .undeterminable(.unreadableArguments)
        }
        guard let parsed = parse(arguments: arguments) else {
            return .undeterminable(.refusedArguments)
        }

        return .connection(
            SSHSurfaceConnection(
                destination: parsed.destination,
                hasCompetingHerdrClient: hasCompetingHerdrClient(
                    destination: parsed.destination,
                    surfaceHerdr: parsed.herdr,
                    surfacePID: surfaceProcess.pid,
                    surfaceUserID: surfaceProcess.effectiveUserID,
                    connections: connections
                ),
                herdr: parsed.herdr,
                usesProxyJump: parsed.usesProxyJump,
                // Read for the ONE process the surface rules just proved is
                // the foreground ssh on the focused tty — never machine-wide.
                sockets: readSockets(surfaceProcess.pid),
                hasSocketlessSiblingToDestination: hasSocketlessSibling(
                    destination: parsed.destination,
                    surfacePID: surfaceProcess.pid,
                    surfaceUserID: surfaceProcess.effectiveUserID,
                    connections: connections,
                    readSockets: readSockets
                )
            )
        )
    }

    /// Is this process a direct child of another ssh in the same scan?
    ///
    /// One hop is the whole walk on purpose: the scan holds only ssh
    /// processes, so an ssh-to-ssh ancestry link IS a direct parent link
    /// (multi-hop ProxyJump chains demote each hop by its own parent), and a
    /// non-ssh intermediary — a shell running a ProxyCommand — breaks the
    /// chain, leaving the grandchild a root. That is the conservative side:
    /// an extra root can only ever cause an abstention, never a join.
    private static func hasSSHParent(
        _ process: SSHClientProcess, in processes: [SSHClientProcess]
    ) -> Bool {
        // The self-parent clause is defensive against hand-built test data
        // only — no Darwin process is its own parent.
        guard process.parentPID > 0, process.parentPID != process.pid else { return false }
        return processes.contains { $0.pid == process.parentPID }
    }

    /// Could another terminal be displaying a DIFFERENT herdr view of this
    /// destination?
    ///
    /// The successor to the machine-wide "only connection" rule, narrowed to
    /// what that rule actually defended: the join reads the candidates'
    /// server-global focused pane, so the only dangerous neighbor is one that
    /// could be a herdr client of a DIFFERENT server (or of a single pane).
    /// A plain shell, a build session, an `ssh host ls` — none of those can
    /// be the surface being dictated into (the probe reads only the focused
    /// tty), and a second whole-view client of the SAME server mirrors the
    /// same focused pane (herdr focus is server-global; verified in source,
    /// 2026-08-06), so joining is correct for both.
    ///
    /// Every OTHER tty-holding connection still counts, foreground or not,
    /// including suspended ones on THIS device (review round 5b: a suspended
    /// `ssh builder herdr <verb>` keeps its server side attached). Excluded:
    /// the surface's own connection, anything with no controlling terminal
    /// (our own `ssh -L` forward), ssh MACHINERY (the caller passes
    /// connections only — a ProxyJump's `-W` child is its root's transport),
    /// and processes owned by ANOTHER user: their herdr view lives in their
    /// own login session, not on a surface this user could be dictating
    /// into, and their metadata is unreadable-by-design, so counting them
    /// meant every root/other-user ssh on the machine was a blanket
    /// abstention. (A cross-uid ssh ON the surface never reaches this scan —
    /// its unreadable executable abstains the probe first.)
    ///
    /// The refusal ladder for a neighbor, most to least readable:
    /// parsed to another destination — irrelevant (its herdr, if any, is
    /// another host's server, which our candidates cannot name); parsed to
    /// this destination — competes exactly when its herdr classification is
    /// not "the same view" (`.plainClient` with a byte-identical selector, or
    /// not herdr at all); argv readable but refused — competes only when some
    /// token contains `herdr` (one-sided: can over-block, never under-block);
    /// argv or executable unreadable — always competes, an unreadable process
    /// cannot be ruled out.
    private static func hasCompetingHerdrClient(
        destination: String,
        surfaceHerdr: HerdrInvocation,
        surfacePID: Int32,
        surfaceUserID: uid_t,
        connections: [SSHClientProcess]
    ) -> Bool {
        for process in connections
        where process.ttyDevice != nil && process.pid != surfacePID
            && process.effectiveUserID == surfaceUserID {
            guard let executablePath = process.executablePath,
                  isTrustedSSHExecutable(executablePath),
                  let arguments = process.arguments
            else { return true }
            guard let parsed = parse(arguments: arguments) else {
                if mentionsHerdr(arguments) { return true }
                continue
            }
            guard parsed.destination == destination else { continue }
            switch parsed.herdr {
            case .notHerdr:
                continue
            case .plainClient(let selector):
                guard case .plainClient(let surfaceSelector) = surfaceHerdr,
                      selector == surfaceSelector
                else { return true }
            case .otherHerdrSubcommand:
                return true
            }
        }
        return false
    }

    /// Is there another same-uid ssh CONNECTION to this destination that holds
    /// no established TCP socket of its own?
    ///
    /// That is the ControlMaster mux-client shape (see
    /// `SSHSurfaceConnection.hasSocketlessSiblingToDestination`). Scoped as
    /// tightly as the question allows, so an ordinary second terminal to the
    /// same host does not pay for it:
    ///
    /// * same uid only — a `ControlPath` is per-user, and another user's fd
    ///   table is not ours to read;
    /// * the argv must PARSE to the same destination. A neighbor we cannot
    ///   parse is skipped rather than counted: a mux client's argv is by
    ///   definition an ordinary `ssh host`, and counting unparseable ones
    ///   would abstain on every wrapper anywhere on the machine;
    /// * an UNREADABLE fd table counts, matching the posture the herdr
    ///   competitor scan takes: a process we cannot describe cannot be ruled
    ///   out. The cost is one abstained dictation when a neighbor exits
    ///   between the scan and the read.
    private static func hasSocketlessSibling(
        destination: String,
        surfacePID: Int32,
        surfaceUserID: uid_t,
        connections: [SSHClientProcess],
        readSockets: @Sendable (Int32) -> [SSHClientSocket]?
    ) -> Bool {
        for process in connections
        where process.pid != surfacePID && process.effectiveUserID == surfaceUserID {
            guard let executablePath = process.executablePath,
                  isTrustedSSHExecutable(executablePath),
                  let arguments = process.arguments,
                  let parsed = parse(arguments: arguments),
                  parsed.destination == destination
            else { continue }
            guard let sockets = readSockets(process.pid) else { return true }
            if sockets.isEmpty { return true }
        }
        return false
    }

    /// Does any argv token mention herdr at all?
    ///
    /// Used ONLY for neighbors whose argv was read but refused by the parser:
    /// we cannot name their destination, but an argv with no `herdr` substring
    /// anywhere cannot have run herdr as its remote command. Substring, not
    /// basename, on purpose — `sh -lc 'exec herdr'` arrives as one token, and
    /// this test must only ever err toward blocking. Known over-block: a
    /// HOSTNAME containing "herdr" trips it too (`ssh -o X herdrhost`) —
    /// accepted, since the cost is an abstention on a refused-argv neighbor,
    /// never a join.
    static func mentionsHerdr(_ argv: [String]) -> Bool {
        argv.contains { $0.contains("herdr") }
    }

    // MARK: - argv parsing

    struct ParsedInvocation: Sendable, Equatable {
        var destination: String
        var herdr: HerdrInvocation
        /// A `-J` appeared before the destination operand. `-o ProxyJump=…`
        /// needs no flag of its own: every `-o` but `SetEnv`/`SendEnv` already
        /// refuses the whole parse.
        var usesProxyJump: Bool = false
    }

    /// Options that take no argument, per ssh(1)'s synopsis
    /// (`[-46AaCfGgKkMNnqsTtVvXxYy]`), minus the ones this probe refuses.
    private static let flagOptions = Set("46AaCgKknqsTtVvXxYy")
    /// Options that take one argument and cannot move the destination.
    private static let argumentOptions = Set("BbcEeIiJLlmPpQR")
    /// Options that ABSTAIN, either because they can change where the
    /// connection actually goes (`-o HostName=…`, `-F other.conf`) or because
    /// they mean this is not an interactive session on a terminal (`-N`, `-f`,
    /// `-M`, `-O`, `-S`, `-D`, `-W`, `-w`).
    ///
    /// `-o` is refused wholesale except for exact `SetEnv=` / `SendEnv=` keys.
    /// Those only shape the remote environment: they cannot move the
    /// destination or change whether the session is interactive. No other
    /// config semantics are reimplemented here.
    private static let refusedOptions = Set("oFOSNfMDWw")

    /// The destination host and whether the remote command names herdr, or nil
    /// when this argv cannot be interpreted with certainty.
    ///
    /// Deliberately NOT "the last non-option token": everything after the
    /// destination is a remote COMMAND, and `ssh host ls /tmp` would then be
    /// read as a destination of `/tmp`. The walk classifies options in order and
    /// stops at the first operand, which is the destination by definition.
    static func parse(arguments argv: [String]) -> ParsedInvocation? {
        guard let executable = argv.first, isSSHArgumentZero(executable) else { return nil }

        var index = 1
        var usesProxyJump = false
        while index < argv.count {
            let token = argv[index]
            if token == "--" {
                guard index + 1 < argv.count else { return nil }
                return invocation(
                    destinationOperand: argv[index + 1],
                    remoteCommand: Array(argv.dropFirst(index + 2)),
                    usesProxyJump: usesProxyJump
                )
            }
            if token.hasPrefix("-"), token.count > 1 {
                if let consumed = destinationInertOOptionArgumentCount(
                    token, nextArgument: index + 1 < argv.count ? argv[index + 1] : nil
                ) {
                    index += consumed
                    continue
                }
                if namesProxyJump(optionToken: token) { usesProxyJump = true }
                switch consumption(ofOptionToken: token) {
                case .unrecognized, .refused:
                    return nil
                case .selfContained:
                    index += 1
                case .consumesNextArgument:
                    index += 2
                }
                continue
            }
            return invocation(
                destinationOperand: token,
                remoteCommand: Array(argv.dropFirst(index + 1)),
                usesProxyJump: usesProxyJump
            )
        }
        return nil
    }

    /// Does this option token carry `-J` (a jump host)?
    ///
    /// Walks the cluster the way `consumption(ofOptionToken:)` does, so `-J`,
    /// `-Jjump`, `-tJ jump` and `-4J jump` all count while a `J` that is part
    /// of some OTHER option's glued argument (`-p22J`, `-i/tmp/J`) does not:
    /// the walk stops at the first argument-taking letter, which is where the
    /// option letters end.
    static func namesProxyJump(optionToken token: String) -> Bool {
        for character in token.dropFirst() {
            if flagOptions.contains(character) { continue }
            return character == "J"
        }
        return false
    }

    private static func invocation(
        destinationOperand: String,
        remoteCommand: [String],
        usesProxyJump: Bool
    ) -> ParsedInvocation? {
        guard let destination = normalizedDestination(destinationOperand) else { return nil }
        return ParsedInvocation(
            destination: destination,
            herdr: classifyHerdrCommand(remoteCommand),
            usesProxyJump: usesProxyJump
        )
    }

    /// Classify a remote command's relationship to herdr.
    ///
    /// The first token must BE herdr (`commandNamesHerdr` — first token only,
    /// by basename; a shell wrapper's first token is `sh` and what it goes on
    /// to run is not something an argv can promise). What follows decides the
    /// shape: nothing, or `--session <name>` / `--session=<name>`, is the
    /// whole-view client attach; ANY other token — `terminal attach <id>`,
    /// `session attach <name>`, `server`, a flag this classifier does not
    /// know — is `.otherHerdrSubcommand`, refused. Unknown herdr verbs must
    /// land there and not in `.plainClient`: a verb added by a future herdr
    /// that displays one pane would otherwise become a mis-join.
    static func classifyHerdrCommand(_ remoteCommand: [String]) -> HerdrInvocation {
        guard commandNamesHerdr(remoteCommand) else { return .notHerdr }
        var selector: String?
        var index = 1
        while index < remoteCommand.count {
            let token = remoteCommand[index]
            let value: String
            if token == "--session" {
                guard index + 1 < remoteCommand.count else { return .otherHerdrSubcommand }
                value = remoteCommand[index + 1]
                index += 2
            } else if token.hasPrefix("--session=") {
                value = String(token.dropFirst("--session=".count))
                index += 1
            } else {
                return .otherHerdrSubcommand
            }
            // An empty selector is not a name we can compare byte-identically,
            // and a REPEATED --session is refused rather than resolved: which
            // occurrence herdr honors is its business, and a classifier that
            // silently picks one can agree with itself while disagreeing with
            // herdr (review finding, 2026-08-06).
            guard !value.isEmpty, selector == nil else { return .otherHerdrSubcommand }
            selector = value
        }
        return .plainClient(sessionSelector: selector)
    }

    /// Is the remote command herdr ITSELF?
    ///
    /// Exactly the first command token, by basename: `ssh host herdr attach`
    /// and `ssh host /usr/local/bin/herdr attach` count; nothing else does.
    ///
    /// The earlier version scanned every token, split on whitespace and
    /// semicolons, which made the signal forgeable by anything that merely
    /// MENTIONED herdr — `ssh builder sh -lc 'printf herdr; exec claude'` set
    /// it (review round 3, blocker 1a). A shell wrapper is refused for the same
    /// reason it was the exploit: its first token is `sh`, and what it goes on
    /// to run is not something an argv can promise.
    ///
    /// REQUIRED by the arm (review round 5b), not corroboration: herdr exposes
    /// no read-only attachment signal, so the invocation is the only evidence
    /// that this terminal is a herdr client at all. It never stands ALONE
    /// either — uniqueness is required alongside it, because argv is written by
    /// whoever launched the process.
    static func commandNamesHerdr(_ remoteCommand: [String]) -> Bool {
        guard let command = remoteCommand.first, !command.isEmpty else { return false }
        return (command as NSString).lastPathComponent == "herdr"
    }

    private static func isSSHArgumentZero(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "ssh"
    }

    /// What one option token does to the walk.
    enum OptionConsumption: Sendable, Equatable {
        /// Pure flags (`-tt`), or an option whose argument is glued to it
        /// (`-p22`).
        case selfContained
        /// The option's argument is the NEXT argv element (`-p 22`).
        case consumesNextArgument
        /// An option that can move the destination or marks a non-interactive
        /// session. Abstain.
        case refused
        /// A letter this parser does not know. Never guessed: an unknown option
        /// that takes an argument would make the walk read that argument as the
        /// destination.
        case unrecognized
    }

    static func consumption(ofOptionToken token: String) -> OptionConsumption {
        let characters = Array(token.dropFirst())
        for (index, character) in characters.enumerated() {
            if refusedOptions.contains(character) { return .refused }
            if flagOptions.contains(character) { continue }
            guard argumentOptions.contains(character) else { return .unrecognized }
            return index == characters.count - 1 ? .consumesNextArgument : .selfContained
        }
        // A cluster of pure flags (`-tt`, `-AC`).
        return .selfContained
    }

    /// Number of argv elements consumed by an allowlisted `-o`, including
    /// `-o` after pure flags in a cluster (`-to SetEnv=…`). Anything before the
    /// `o` that is not a pure flag belongs to the ordinary option parser.
    private static func destinationInertOOptionArgumentCount(
        _ token: String, nextArgument: String?
    ) -> Int? {
        let characters = Array(token.dropFirst())
        for (index, character) in characters.enumerated() {
            if flagOptions.contains(character) { continue }
            guard character == "o" else { return nil }
            if index == characters.count - 1 {
                guard let nextArgument, isDestinationInertOOption(nextArgument) else { return nil }
                return 2
            }
            let value = String(characters[(index + 1)...])
            return isDestinationInertOOption(value) ? 1 : nil
        }
        return nil
    }

    private static func isDestinationInertOOption(_ value: String) -> Bool {
        value.range(of: "SetEnv=", options: [.anchored, .caseInsensitive]) != nil
            || value.range(of: "SendEnv=", options: [.anchored, .caseInsensitive]) != nil
    }

    /// The host part of an ssh destination operand, lowercased, or nil when the
    /// operand is a shape we refuse to interpret.
    ///
    /// Refused on purpose: the `ssh://` URI form (its host is followed by an
    /// optional `:port`, and this is not the place to reimplement a URL parser)
    /// and anything outside a hostname/alias charset.
    ///
    /// Lowercased because hostnames are case-insensitive and an ssh config alias
    /// is matched the same way in practice. That makes the comparison WIDER,
    /// which is only safe because a match is a precondition of the arm, never
    /// the join: the pane id, herdr's own session claim, and the foreground
    /// process all still have to agree afterwards.
    static func normalizedDestination(_ operand: String) -> String? {
        guard !operand.isEmpty, operand.utf8.count <= 253 else { return nil }
        guard !operand.contains("://") else { return nil }
        // `user@host`: split on the LAST `@`, so a username containing one does
        // not steal the host.
        let host: Substring
        if let separator = operand.lastIndex(of: "@") {
            host = operand[operand.index(after: separator)...]
        } else {
            host = operand[...]
        }
        guard !host.isEmpty else { return nil }
        let allowed = host.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "." || character == "-" || character == "_")
        }
        guard allowed else { return nil }
        return host.lowercased()
    }

    // MARK: - Live reads

    /// EVERY ssh process on the machine (`KERN_PROC_ALL`), with the metadata
    /// the rules above need. One scan answers both the surface question and
    /// the competing-view question. Cross-uid processes are carried WITHOUT
    /// their metadata: they must stay visible to the surface count (a
    /// `sudo ssh` in the foreground abstains rather than reading as "no ssh
    /// here"), but their executable path and argv are another user's business
    /// — never read, not merely expected to fail.
    static let liveSSHProcesses: @Sendable () -> [SSHClientProcess]? = {
        guard let entries = TTYProcessTable.allProcesses() else { return nil }
        return sshProcesses(
            from: entries,
            effectiveUserID: geteuid(),
            readExecutablePath: executablePath,
            readArguments: processArguments
        )
    }

    /// Maps the process-table scan into the ssh-specific shape at the live-read
    /// boundary, keeping credential handling out of the pure decision code.
    static func sshProcesses(
        from entries: [TTYProcessTable.Entry],
        effectiveUserID: uid_t,
        readExecutablePath: (Int32) -> String?,
        readArguments: (Int32) -> [String]?
    ) -> [SSHClientProcess] {
        return entries
            .filter { $0.name == "ssh" }
            .map { entry in
                let sameUser = entry.effectiveUserID == effectiveUserID
                return SSHClientProcess(
                    pid: entry.pid,
                    parentPID: entry.parentProcessID,
                    ttyDevice: entry.ttyDevice,
                    processGroupID: entry.processGroupID,
                    terminalForegroundGroupID: entry.terminalForegroundGroupID,
                    effectiveUserID: entry.effectiveUserID,
                    executablePath: sameUser ? readExecutablePath(entry.pid) : nil,
                    arguments: sameUser ? readArguments(entry.pid) : nil
                )
            }
    }

    /// The real executable behind a pid — which `p_comm` (16 bytes, and a name
    /// the process chose) and argv[0] (chosen by whoever exec'd it) are not.
    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self
        )
    }

    /// argv of one process via `KERN_PROCARGS2`.
    ///
    /// Layout (`sysctl.h`, unchanged since 10.x): `int32 argc`, the exec path,
    /// NUL padding, then exactly `argc` NUL-terminated argv strings, then the
    /// environment — which this deliberately stops before. Another process's
    /// environment is not ours to read, and nothing here needs it.
    static func processArguments(pid: Int32) -> [String]? {
        var argumentMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var maxMIB = [Int32(CTL_KERN), Int32(KERN_ARGMAX)]
        guard sysctl(&maxMIB, u_int(maxMIB.count), &argumentMax, &size, nil, 0) == 0,
              argumentMax > 0
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argumentMax))
        var length = buffer.count
        var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &length, nil, 0)
        }
        guard status == 0, length > MemoryLayout<Int32>.size else { return nil }

        return parseProcessArguments(Array(buffer.prefix(length)))
    }

    /// Pure parser over a `KERN_PROCARGS2` buffer, so the layout handling is
    /// testable without spawning processes.
    static func parseProcessArguments(_ buffer: [UInt8]) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count > headerSize else { return nil }
        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            destination.copyBytes(from: buffer[0..<headerSize])
        }
        guard argumentCount > 0, argumentCount < 4096 else { return nil }

        var index = headerSize
        // Exec path, then its NUL padding.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < Int(argumentCount), index < buffer.count {
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            // The last string must be NUL-terminated inside the buffer; a
            // truncated tail means the layout was not what we think it is.
            guard end < buffer.count else { return nil }
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        guard arguments.count == Int(argumentCount) else { return nil }
        return arguments
    }
}

/// Shared same-user walks of the process table.
///
/// Extracted so the ssh probe and `HerdrClientTTYProbe` cannot drift apart on
/// what "on this tty" means. The ssh probe needs more per process (controlling
/// device, process groups) and needs a machine-wide scan for the uniqueness
/// rule, so both shapes live here.
enum TTYProcessTable {
    struct Entry: Sendable, Equatable {
        var pid: Int32
        var parentProcessID: Int32
        /// Kernel credential from `kp_eproc.e_ucred.cr_uid`, never a value the
        /// process can choose or report about itself.
        var effectiveUserID: uid_t
        var name: String
        var ttyDevice: dev_t?
        var processGroupID: Int32
        var terminalForegroundGroupID: Int32

        init(
            pid: Int32,
            parentProcessID: Int32 = 0,
            effectiveUserID: uid_t,
            name: String,
            ttyDevice: dev_t? = nil,
            processGroupID: Int32 = 0,
            terminalForegroundGroupID: Int32 = 0
        ) {
            self.pid = pid
            self.parentProcessID = parentProcessID
            self.effectiveUserID = effectiveUserID
            self.name = name
            self.ttyDevice = ttyDevice
            self.processGroupID = processGroupID
            self.terminalForegroundGroupID = terminalForegroundGroupID
        }
    }

    static let liveDeviceID: @Sendable (String) -> dev_t? = { path in
        // `lstat`, matching ClaudeSocketGuard: `Darwin.stat` resolves to the
        // struct type, not the function, and a /dev node is never a symlink.
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return nil }
        return metadata.st_rdev
    }

    static func entries(onDevice device: dev_t) -> [Entry]? {
        // dev_t is Int32 on Darwin, so this is an identity conversion today —
        // but if the type ever widens, a device that does not fit must abstain,
        // not trap mid-dictation.
        guard let deviceMIB = Int32(exactly: device) else { return nil }
        return scan(mib: [Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_TTY), deviceMIB])
    }

    static func allProcesses() -> [Entry]? {
        scan(mib: [Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_ALL), 0])
    }

    private static func scan(mib: [Int32]) -> [Entry]? {
        var mib = mib
        var byteCount = 0
        guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0, byteCount > 0
        else { return nil }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Headroom: processes can appear between the sizing call and the fetch,
        // and a short buffer makes the second sysctl fail with ENOMEM.
        let capacity = (byteCount + stride - 1) / stride + 32
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var fetchedBytes = processes.count * stride
        let status = processes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &fetchedBytes, nil, 0)
        }
        guard status == 0 else { return nil }

        return processes.prefix(fetchedBytes / stride).map { process in
            // Bounded decode: `String(cString:)` would walk past the fixed-size
            // p_comm tuple if a corrupted entry ever arrived without its NUL.
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let device = process.kp_eproc.e_tdev
            return Entry(
                pid: process.kp_proc.p_pid,
                parentProcessID: process.kp_eproc.e_ppid,
                effectiveUserID: process.kp_eproc.e_ucred.cr_uid,
                name: name,
                // NODEV means no controlling terminal — not a surface.
                ttyDevice: device == ~dev_t(0) ? nil : device,
                processGroupID: process.kp_eproc.e_pgid,
                terminalForegroundGroupID: process.kp_eproc.e_tpgid
            )
        }
    }
}
#endif
