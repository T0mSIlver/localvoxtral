import Foundation

#if canImport(Darwin)
import Darwin

/// The ssh connection a terminal surface is displaying, as far as the local
/// process table can prove it.
struct SSHSurfaceConnection: Sendable, Equatable {
    /// Normalized destination host/alias.
    var destination: String
    /// No OTHER terminal on this machine hosts an ssh to the same destination.
    ///
    /// Without this the probe binds to a HOST rather than to a CONNECTION: with
    /// one terminal on a plain shell to `builder` and another attached to herdr
    /// on `builder`, both surfaces answer "ssh to builder", and the plain shell
    /// would join the herdr terminal's session (review blocker 1).
    var isOnlyConnectionToDestination: Bool
    /// The argv positively names herdr as the remote command — the shape
    /// `herdr --remote` spawns, or a hand-typed `ssh host herdr …`. This binds
    /// the CONNECTION to herdr, which no amount of host-level reasoning can.
    var indicatesHerdr: Bool

    init(destination: String, isOnlyConnectionToDestination: Bool, indicatesHerdr: Bool) {
        self.destination = destination
        self.isOnlyConnectionToDestination = isOnlyConnectionToDestination
        self.indicatesHerdr = indicatesHerdr
    }
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
    case undeterminable
}

/// One ssh process as the probe sees it.
struct SSHClientProcess: Sendable, Equatable {
    var pid: Int32
    /// Controlling terminal device, or nil when it has none. A process with no
    /// terminal is not a surface anyone can be dictating into — our OWN
    /// `ssh -L` forward is exactly that, which is why it must not count.
    var ttyDevice: dev_t?
    var processGroupID: Int32
    /// The foreground process group of its controlling terminal.
    var terminalForegroundGroupID: Int32
    /// Resolved executable path (`proc_pidpath`), not argv[0] and not `p_comm`.
    var executablePath: String?
    var arguments: [String]?

    init(
        pid: Int32,
        ttyDevice: dev_t?,
        processGroupID: Int32,
        terminalForegroundGroupID: Int32,
        executablePath: String?,
        arguments: [String]?
    ) {
        self.pid = pid
        self.ttyDevice = ttyDevice
        self.processGroupID = processGroupID
        self.terminalForegroundGroupID = terminalForegroundGroupID
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
///   interactive session" — `-o` (HostName/Port/User/ProxyJump/…), `-F`, `-O`,
///   `-S`, `-N`, `-f`, `-M`, `-D`, `-W`, `-w` — ABSTAINS instead of being
///   skipped.
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
            sshProcesses: liveSSHProcesses
        )
    }

    /// Pure over the two live reads, so the whole truth table is unit-testable
    /// without a real ssh on a real tty.
    ///
    /// - Parameter sshProcesses: EVERY ssh process on the machine, not just this
    ///   device's — the uniqueness question is machine-wide by definition.
    static func connection(
        onTTYDevicePath path: String,
        deviceID: @Sendable (String) -> dev_t?,
        sshProcesses: @Sendable () -> [SSHClientProcess]?
    ) -> SSHDestinationTTYProbeResult {
        guard let device = deviceID(path), let processes = sshProcesses() else {
            // A device we cannot resolve, or a process table we cannot read, is
            // not evidence of absence.
            return .undeterminable
        }

        // Only the foreground process group of THIS terminal can be what the
        // user is looking at. A backgrounded or stopped ssh on the same device
        // means the surface is showing the shell, not a remote session.
        let onSurface = processes.filter {
            $0.ttyDevice == device && $0.isForegroundOfItsTerminal
        }
        guard !onSurface.isEmpty else { return .noSSHClient }

        // EXACTLY ONE foreground ssh, or nothing. The first version combined
        // several — one destination set, `indicatesHerdr` OR-ed across them —
        // and that union was itself a mis-join (review round 7): a foreground
        // group holding both `ssh builder` and `ssh builder herdr` reported
        // "unique" AND "is herdr", so the plain, visible connection joined the
        // other process's herdr session. A pipeline or wrapper that launches
        // several ssh children in one group is the same shape.
        //
        // There is no way to tell from here WHICH of them the user is looking
        // at, and this arm's rule is to abstain rather than guess.
        guard onSurface.count == 1, let surfaceProcess = onSurface.first else {
            return .undeterminable
        }
        guard let parsed = verifiedInvocation(of: surfaceProcess) else {
            return .undeterminable
        }

        return .connection(
            SSHSurfaceConnection(
                destination: parsed.destination,
                isOnlyConnectionToDestination: isOnlyConnection(
                    to: parsed.destination,
                    surfacePID: surfaceProcess.pid,
                    processes: processes
                ),
                indicatesHerdr: parsed.indicatesHerdr
            )
        )
    }

    /// Is this terminal's the only connection to that destination?
    ///
    /// Every OTHER ssh counts, foreground or not, and — this is the part the
    /// first version got wrong (review round 5b) — including ones on THIS
    /// device. Excluding same-device background processes let `ssh builder
    /// herdr` be suspended with Ctrl+Z, its server side still attached and its
    /// pane still focused, while a plain `ssh builder` in the foreground of the
    /// same terminal claimed to be the only connection.
    ///
    /// "The surface shows the shell, not that ssh" is a fact about which
    /// connection this terminal DISPLAYS — it belongs to destination
    /// determination above, and says nothing about how many connections exist.
    ///
    /// Excluded: the surface's own connection (the single foreground ssh this
    /// answer is about), and anything with no controlling terminal — nobody can
    /// be dictating into one, and our own `ssh -L` forward is exactly that.
    private static func isOnlyConnection(
        to destination: String,
        surfacePID: Int32,
        processes: [SSHClientProcess]
    ) -> Bool {
        for process in processes
        where process.ttyDevice != nil && process.pid != surfacePID {
            guard let parsed = verifiedInvocation(of: process) else {
                // An ssh elsewhere we cannot read could be to this destination.
                // Uniqueness is a claim, and an unreadable process cannot be
                // part of one.
                return false
            }
            if parsed.destination == destination { return false }
        }
        return true
    }

    private static func verifiedInvocation(of process: SSHClientProcess) -> ParsedInvocation? {
        guard let executablePath = process.executablePath,
              isTrustedSSHExecutable(executablePath),
              let arguments = process.arguments
        else { return nil }
        return parse(arguments: arguments)
    }

    // MARK: - argv parsing

    struct ParsedInvocation: Sendable, Equatable {
        var destination: String
        var indicatesHerdr: Bool
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
    /// `-o` is refused wholesale rather than parsed: proving a specific option
    /// inert means reimplementing OpenSSH's config semantics, and the cost of
    /// refusing is one join that does not happen.
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
        while index < argv.count {
            let token = argv[index]
            if token == "--" {
                guard index + 1 < argv.count else { return nil }
                return invocation(
                    destinationOperand: argv[index + 1],
                    remoteCommand: Array(argv.dropFirst(index + 2))
                )
            }
            if token.hasPrefix("-"), token.count > 1 {
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
                remoteCommand: Array(argv.dropFirst(index + 1))
            )
        }
        return nil
    }

    private static func invocation(
        destinationOperand: String,
        remoteCommand: [String]
    ) -> ParsedInvocation? {
        guard let destination = normalizedDestination(destinationOperand) else { return nil }
        return ParsedInvocation(
            destination: destination,
            indicatesHerdr: commandNamesHerdr(remoteCommand)
        )
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
    /// the join: the pane id, the marker, herdr's own session claim, and the
    /// foreground process all still have to agree afterwards.
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

    /// EVERY ssh process on the machine (`KERN_PROC_ALL`), with the metadata the
    /// rules above need. One scan answers both the surface question and the
    /// uniqueness question.
    static let liveSSHProcesses: @Sendable () -> [SSHClientProcess]? = {
        guard let entries = TTYProcessTable.allProcesses() else { return nil }
        return entries
            .filter { $0.name == "ssh" }
            .map { entry in
                SSHClientProcess(
                    pid: entry.pid,
                    ttyDevice: entry.ttyDevice,
                    processGroupID: entry.processGroupID,
                    terminalForegroundGroupID: entry.terminalForegroundGroupID,
                    executablePath: executablePath(pid: entry.pid),
                    arguments: processArguments(pid: entry.pid)
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
        var name: String
        var ttyDevice: dev_t?
        var processGroupID: Int32
        var terminalForegroundGroupID: Int32

        init(
            pid: Int32,
            name: String,
            ttyDevice: dev_t? = nil,
            processGroupID: Int32 = 0,
            terminalForegroundGroupID: Int32 = 0
        ) {
            self.pid = pid
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
