import Foundation

/// The join, reduced to the handful of facts that can be reported outside the
/// process without leaking anything the logs redact.
///
/// One type, two consumers: the dogfood capture record's `join` block and the
/// `--probe-surface` diagnostic verb. Two mappings of one vocabulary is one too
/// many — an arm renamed on one side and not the other would make a probe run
/// and a captured record disagree about the same dictation, which is exactly
/// the drift a diagnostic must never introduce.
///
/// What is deliberately NOT here is the point. A join knows the session id,
/// the workspace path, the herdr socket path, the remote host, and (for
/// a panel-authorized remote join) a live nonce. None of those may cross this
/// boundary: `workspaceIsLocal` is a Bool rather than the path, `origin` is a
/// class rather than a host, and `terminal` is the app's name rather than
/// anything about what it is displaying. `abstentionReason` carries only the
/// resolver's own content-free outcome categories — the same strings it already
/// writes to `Log.claudeContext`, which are audited for exactly this.
struct ClaudeSessionJoinSummary: Codable, Equatable, Sendable {
    /// `tty`, `herdrPane`, `browserTab`, `cmuxSurface`, `remoteHerdrPane`,
    /// `remoteSSHConnection`, `remoteLocalTTY`, or `none`. The resolver's mechanism vocabulary,
    /// not a second naming of it.
    var arm: String
    /// Every arm that declined, oldest first, joined by `; `. Present even when
    /// an arm ultimately answered: "the tty arm never answers" is invisible in
    /// a summary that names only the winner.
    var abstentionReason: String?
    /// `local` or `remote` — which context the session was even eligible for.
    var origin: String?
    /// `Ghostty`, `iTerm2`, `Terminal.app`, or `cmux`.
    var terminal: String?
    /// True when the join carries a herdr pane binding (local or remote), which
    /// makes the join herdr-or-nothing from that point.
    var herdrBound: Bool?
    var workspaceIsLocal: Bool?

    init(
        arm: String,
        abstentionReason: String? = nil,
        origin: String? = nil,
        terminal: String? = nil,
        herdrBound: Bool? = nil,
        workspaceIsLocal: Bool? = nil
    ) {
        self.arm = arm
        self.abstentionReason = abstentionReason
        self.origin = origin
        self.terminal = terminal
        self.herdrBound = herdrBound
        self.workspaceIsLocal = workspaceIsLocal
    }

    /// The single place a `ClaudeSessionJoin` becomes reportable.
    ///
    /// - Parameter abstentions: the causes collected during the resolve, in
    ///   order. Empty means the resolver reached its answer without any arm
    ///   declining — which for `arm == "none"` means no arm ran at all, and
    ///   that distinction is itself diagnostic.
    static func summarize(
        join: ClaudeSessionJoin?,
        abstentions: [String]
    ) -> ClaudeSessionJoinSummary {
        let reason = abstentions.isEmpty ? nil : abstentions.joined(separator: "; ")
        guard let join else {
            return ClaudeSessionJoinSummary(
                arm: "none",
                abstentionReason: reason,
                origin: nil,
                terminal: nil,
                herdrBound: nil,
                workspaceIsLocal: nil
            )
        }
        return ClaudeSessionJoinSummary(
            arm: armName(join.mechanism),
            abstentionReason: reason,
            origin: join.snapshot.origin.isLocalAuthenticated ? "local" : "remote",
            terminal: TerminalScreenAllowlist.displayName(forBundleID: join.target.bundleID),
            herdrBound: join.herdrPane != nil,
            workspaceIsLocal: join.snapshot.localWorkspacePath != nil
        )
    }

    static func armName(_ mechanism: ClaudeSessionJoinMechanism) -> String {
        switch mechanism {
        case .ttyDevice: return "tty"
        case .herdrPane: return "herdrPane"
        case .browserTab: return "browserTab"
        case .cmuxSurface: return "cmuxSurface"
        case .remoteHerdrPane: return "remoteHerdrPane"
        case .remoteSSHConnection: return "remoteSSHConnection"
        case .remoteLocalTTY: return "remoteLocalTTY"
        }
    }

    /// One line of JSON, keys always in this order and nulls always present.
    ///
    /// Hand-rendered rather than `JSONEncoder`-ed because the shape IS the
    /// contract callers assert against: synthesized `Codable` omits nil
    /// optionals, so an encoder would drop `"origin": null` and turn "the join
    /// reported no origin" into "this field does not exist in this build".
    var jsonLine: String {
        let fields: [(String, String)] = [
            ("arm", Self.jsonString(arm)),
            ("abstentionReason", abstentionReason.map(Self.jsonString) ?? "null"),
            ("origin", origin.map(Self.jsonString) ?? "null"),
            ("terminal", terminal.map(Self.jsonString) ?? "null"),
            ("herdrBound", herdrBound.map { $0 ? "true" : "false" } ?? "null"),
            ("workspaceIsLocal", workspaceIsLocal.map { $0 ? "true" : "false" } ?? "null"),
        ]
        let body = fields.map { "\(Self.jsonString($0.0)):\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }

    /// Escapes through `JSONSerialization` rather than by hand: abstention
    /// causes are assembled from enum raw values today, but a future one
    /// carrying a quote or a backslash must not be able to emit invalid JSON.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// The same six facts as aligned text, for a human reading a terminal.
    var textLines: String {
        [
            "arm:              \(arm)",
            "abstentionReason: \(abstentionReason ?? "(none)")",
            "origin:           \(origin ?? "(none)")",
            "terminal:         \(terminal ?? "(none)")",
            "herdrBound:       \(herdrBound.map(String.init) ?? "(none)")",
            "workspaceIsLocal: \(workspaceIsLocal.map(String.init) ?? "(none)")",
        ].joined(separator: "\n")
    }
}
