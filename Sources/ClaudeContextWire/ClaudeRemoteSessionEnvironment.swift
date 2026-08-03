import Foundation

/// One allowlisted environment value a REMOTE Claude Code hook may report.
///
/// The remote shim has no `jq` and must leave the event body byte-identical to
/// what Claude Code handed it, so the enrichment rides as request HEADERS. This
/// enum is the single source of truth for that mapping: the shim writes
/// `headerName`, the listener reads `lowercasedHeaderName`, and the plugin
/// manifest tests assert both against `shellSource` so the two sides can never
/// drift into a silent no-op.
///
/// Everything here names WHERE a session runs on another machine — a pane id, a
/// socket path, a multiplexer handle. None of it is content, and none of it is
/// ever trusted: see `ClaudeRemoteSessionEnvironment`.
public enum ClaudeRemoteEnvironmentField: String, CaseIterable, Sendable {
    case herdrPaneID
    case herdrSocketPath
    case herdrSession
    case cmuxSurfaceID
    case cmuxSocketPath
    case bridgeSessionID
    case tmux
    case tmuxPane
    case sshTTY
    case hookParentPID

    /// The header the shim writes, in its canonical spelling.
    ///
    /// No underscores by construction: some proxies and CGI-shaped readers fold
    /// `-` and `_` together, and a name that survives that folding unchanged is
    /// one fewer thing to reason about.
    public var headerName: String {
        switch self {
        case .herdrPaneID: return "X-Lvx-Env-Herdr-Pane-Id"
        case .herdrSocketPath: return "X-Lvx-Env-Herdr-Socket-Path"
        case .herdrSession: return "X-Lvx-Env-Herdr-Session"
        case .cmuxSurfaceID: return "X-Lvx-Env-Cmux-Surface-Id"
        case .cmuxSocketPath: return "X-Lvx-Env-Cmux-Socket-Path"
        case .bridgeSessionID: return "X-Lvx-Env-Bridge-Session-Id"
        case .tmux: return "X-Lvx-Env-Tmux"
        case .tmuxPane: return "X-Lvx-Env-Tmux-Pane"
        case .sshTTY: return "X-Lvx-Env-Ssh-Tty"
        case .hookParentPID: return "X-Lvx-Env-Hook-Parent-Pid"
        }
    }

    /// How the parser keys it — `ClaudeRemoteHTTPCodec` lowercases field names.
    public var lowercasedHeaderName: String { headerName.lowercased() }

    /// The shell expansion the shim reads this value from. `$PPID` is the one
    /// that is not an environment variable: it is the shim's own parent, i.e. a
    /// best-effort handle on the Claude Code process on the remote host.
    public var shellSource: String {
        switch self {
        case .herdrPaneID: return "$HERDR_PANE_ID"
        case .herdrSocketPath: return "$HERDR_SOCKET_PATH"
        case .herdrSession: return "$HERDR_SESSION"
        case .cmuxSurfaceID: return "$CMUX_SURFACE_ID"
        case .cmuxSocketPath: return "$CMUX_SOCKET_PATH"
        case .bridgeSessionID: return "$CLAUDE_CODE_BRIDGE_SESSION_ID"
        case .tmux: return "$TMUX"
        case .tmuxPane: return "$TMUX_PANE"
        case .sshTTY: return "$SSH_TTY"
        case .hookParentPID: return "$PPID"
        }
    }
}

/// Hard bounds on the env-header enrichment, applied on the receiving side and
/// mirrored by the shim.
///
/// The shim validates before it writes, and this re-validates on arrival and
/// never trusts that it did — the same posture `ClaudeHookLimits` takes toward
/// the local publisher.
public struct ClaudeRemoteEnvironmentLimits: Sendable, Equatable {
    /// Max UTF-8 bytes of any single value. A pane id or socket path that
    /// approaches this is not one.
    public var maxValueBytes: Int
    /// Max values retained from one request. The allowlist is smaller than this
    /// today, which is the point: the cap is a belt that survives someone
    /// growing the allowlist without revisiting the budget.
    public var maxFieldCount: Int
    /// Max total UTF-8 bytes across all retained values.
    public var maxTotalBytes: Int

    public init(
        maxValueBytes: Int = 200,
        maxFieldCount: Int = 12,
        maxTotalBytes: Int = 1024
    ) {
        self.maxValueBytes = maxValueBytes
        self.maxFieldCount = maxFieldCount
        self.maxTotalBytes = maxTotalBytes
    }

    public static let `default` = ClaudeRemoteEnvironmentLimits()
}

/// Allowlisted environment values reported by a REMOTE session's hooks.
///
/// **Every field here is an opaque, untrusted LABEL about another machine.**
/// That is not a caveat, it is the type's reason to exist as a separate type
/// rather than more fields on `ClaudeHookProcessInfo`:
///
/// * It is never merged into `ClaudeSessionSnapshot.process`, which the local
///   arms read — `resolve(tty:)`, `resolve(herdrPaneID:)`, and
///   `liveLocalHerdrSocketPaths()` all filter on `origin.isLocalAuthenticated`
///   AND read `process`, so a remote value has no route into any of them.
/// * `herdrSocketPath`/`cmuxSocketPath` name a socket in ANOTHER host's
///   filesystem. Nothing here may be dialed, `stat`ed, or handed to
///   `FileManager`; `HerdrSocketClient` requires a local socket owned by
///   `getuid()` and that guard is what makes this safe by construction.
/// * `hookParentPID` is a String, deliberately. It is a pid in another host's
///   namespace, so it is not a number this process may ever `kill(pid, 0)` —
///   keeping it un-numeric keeps it out of every liveness probe by type.
///
/// What it IS good for: a future remote-herdr / cmux / bridge join arm can ask
/// "does the surface the user is looking at report the same pane id this remote
/// session did", which is an equality test between two labels and needs no
/// trust at all.
public struct ClaudeRemoteSessionEnvironment: Sendable, Equatable {
    public var herdrPaneID: String?
    public var herdrSocketPath: String?
    public var herdrSession: String?
    public var cmuxSurfaceID: String?
    public var cmuxSocketPath: String?
    public var bridgeSessionID: String?
    public var tmux: String?
    public var tmuxPane: String?
    public var sshTTY: String?
    /// The remote shim's `$PPID` — Claude Code's pid ON THAT HOST. Diagnostics
    /// and cross-checks against another remote report only; never a local pid.
    public var hookParentPID: String?

    public init(
        herdrPaneID: String? = nil,
        herdrSocketPath: String? = nil,
        herdrSession: String? = nil,
        cmuxSurfaceID: String? = nil,
        cmuxSocketPath: String? = nil,
        bridgeSessionID: String? = nil,
        tmux: String? = nil,
        tmuxPane: String? = nil,
        sshTTY: String? = nil,
        hookParentPID: String? = nil
    ) {
        self.herdrPaneID = herdrPaneID
        self.herdrSocketPath = herdrSocketPath
        self.herdrSession = herdrSession
        self.cmuxSurfaceID = cmuxSurfaceID
        self.cmuxSocketPath = cmuxSocketPath
        self.bridgeSessionID = bridgeSessionID
        self.tmux = tmux
        self.tmuxPane = tmuxPane
        self.sshTTY = sshTTY
        self.hookParentPID = hookParentPID
    }

    public var isEmpty: Bool {
        ClaudeRemoteEnvironmentField.allCases.allSatisfy { self[$0] == nil }
    }

    /// Field-keyed access, so callers (and tests) can iterate the allowlist
    /// instead of restating it.
    public subscript(field: ClaudeRemoteEnvironmentField) -> String? {
        get {
            switch field {
            case .herdrPaneID: return herdrPaneID
            case .herdrSocketPath: return herdrSocketPath
            case .herdrSession: return herdrSession
            case .cmuxSurfaceID: return cmuxSurfaceID
            case .cmuxSocketPath: return cmuxSocketPath
            case .bridgeSessionID: return bridgeSessionID
            case .tmux: return tmux
            case .tmuxPane: return tmuxPane
            case .sshTTY: return sshTTY
            case .hookParentPID: return hookParentPID
            }
        }
        set {
            switch field {
            case .herdrPaneID: herdrPaneID = newValue
            case .herdrSocketPath: herdrSocketPath = newValue
            case .herdrSession: herdrSession = newValue
            case .cmuxSurfaceID: cmuxSurfaceID = newValue
            case .cmuxSocketPath: cmuxSocketPath = newValue
            case .bridgeSessionID: bridgeSessionID = newValue
            case .tmux: tmux = newValue
            case .tmuxPane: tmuxPane = newValue
            case .sshTTY: sshTTY = newValue
            case .hookParentPID: hookParentPID = newValue
            }
        }
    }
}

/// Reads the allowlisted env headers off a parsed request head.
public enum ClaudeRemoteEnvironmentCodec {
    /// The charset a value may consist of: ASCII alphanumerics plus
    /// `. _ : / @ + , = % -`.
    ///
    /// `%` is in the set for one concrete reason: a tmux pane id IS `%3`. It
    /// was left out of the first draft and the hand-run of the shim showed
    /// `TMUX_PANE` silently never arriving — exactly the failure mode this
    /// whole plugin is prone to.
    ///
    /// This is the whole header-injection defence, and it is a whitelist for
    /// that reason: CR, LF, NUL, every other C0 byte, space, tab, and every
    /// non-ASCII byte are outside it, so a value that passes CANNOT terminate a
    /// header line or start a new one. The shim applies the identical set in a
    /// `case` pattern before it writes the file; this is the half that does not
    /// depend on the remote host having done so.
    static func isAllowedByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        case UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: ":"),
             UInt8(ascii: "/"), UInt8(ascii: "@"), UInt8(ascii: "+"),
             UInt8(ascii: ","), UInt8(ascii: "="), UInt8(ascii: "%"),
             UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }

    /// Whether a single value is acceptable: non-empty, within the byte cap,
    /// and entirely inside the charset above.
    ///
    /// Applied to the value as the PEER WROTE IT, minus HTTP's own OWS. That
    /// ordering is load-bearing: while the head parser trimmed with Foundation's
    /// Unicode whitespace set, `pane-7<NBSP>` reached here already trimmed to
    /// `pane-7` and passed — a malformed wire value laundered into a
    /// well-formed one before the byte check could see it. The parser now trims
    /// SP/HTAB only (`ClaudeRemoteHTTPCodec.trimmingOWS`), so a non-ASCII byte
    /// anywhere in the value arrives intact and is rejected here.
    public static func isAcceptableValue(
        _ value: String,
        limits: ClaudeRemoteEnvironmentLimits = .default
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= limits.maxValueBytes else { return false }
        return bytes.allSatisfy(isAllowedByte)
    }

    /// Collect the allowlisted env values from already-parsed request headers.
    ///
    /// Returns nil when nothing survived, so "no enrichment" and "an empty
    /// enrichment" are the same value downstream.
    ///
    /// A value that fails validation is DROPPED — the request is not rejected.
    /// Delivery of the hook itself is the thing that must not become brittle:
    /// the body is the payload, and an enrichment header is a bonus. Caps are
    /// applied walking `allCases` in declaration order, so a truncated result is
    /// deterministic rather than dictionary-order noise.
    public static func environment(
        in headers: [String: String],
        limits: ClaudeRemoteEnvironmentLimits = .default
    ) -> ClaudeRemoteSessionEnvironment? {
        var environment = ClaudeRemoteSessionEnvironment()
        var count = 0
        var totalBytes = 0
        for field in ClaudeRemoteEnvironmentField.allCases {
            guard count < limits.maxFieldCount else { break }
            guard let value = headers[field.lowercasedHeaderName] else { continue }
            guard isAcceptableValue(value, limits: limits) else { continue }
            let size = value.utf8.count
            guard totalBytes + size <= limits.maxTotalBytes else { continue }
            environment[field] = value
            count += 1
            totalBytes += size
        }
        return environment.isEmpty ? nil : environment
    }
}
