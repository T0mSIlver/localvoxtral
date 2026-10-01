import Foundation

/// The `localvoxtral` command's requests and the app's answers (#721).
///
/// The command reaches the app over the hook broker's socket: one request
/// line out, one response line back, then the connection closes. A request
/// carries a `cli` key, which no hook record has, and that key is how the
/// broker tells the two apart before it decodes anything else. The socket's
/// trust is unchanged: a private directory, a 0600 socket, and the peer's uid
/// checked before the first byte is read, so only the user's own processes
/// can ask, and they could already read `history.store` themselves.
public enum AgentCLIWire {
    public static let version = 1

    /// A request is a command and a few terms; far under the broker's line
    /// cap.
    public static let maxRequestBytes = 16 * 1024
    /// A history answer holds at most `maxHistoryLimit` dictations.
    public static let maxResponseBytes = 8 * 1024 * 1024
    public static let defaultHistoryLimit = 20
    public static let maxHistoryLimit = 200
    /// Terms one `terms propose` may carry. Matches the headless run's cap
    /// (`ProjectTermProposal.maxTerms`).
    public static let maxProposedTerms = 40

    /// Whether a line is a CLI request rather than a hook record. Only the
    /// key's presence is checked; decoding reports anything else.
    public static func isRequest(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let dictionary = object as? [String: Any]
        else { return false }
        return dictionary["cli"] != nil
    }

    public static func encodeLine<Value: Encodable>(_ value: Value) -> Data? {
        guard var data = try? encoder.encode(value) else { return nil }
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ line: Data) throws -> AgentCLIRequest {
        guard line.count <= maxRequestBytes else { throw AgentCLIError(.badRequest, "request too long") }
        let request: AgentCLIRequest
        do {
            request = try decoder.decode(AgentCLIRequest.self, from: line)
        } catch {
            throw AgentCLIError(.badRequest, "unreadable request")
        }
        guard request.cli == version else {
            throw AgentCLIError(.unsupportedVersion, "this app speaks version \(version) of the command")
        }
        return request
    }

    public static func decodeResponse(_ line: Data) -> AgentCLIResponse? {
        try? decoder.decode(AgentCLIResponse.self, from: line)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum AgentCLICommand: String, Sendable, CaseIterable {
    case historySearch = "history.search"
    case historyLast = "history.last"
    case termsList = "terms.list"
    case termsPropose = "terms.propose"
    case status
    case doctor
    case captureList = "capture.list"
    case captureShow = "capture.show"
    case captureFiled = "capture.filed"
}

/// The coding agent that ran the command, recorded as a proposed term's
/// source (`agent:<rawValue>`). A label, not a credential: every caller
/// shares the user's uid.
public enum AgentCLICaller: String, Sendable, CaseIterable, Codable {
    case claude
    case codex
    case opencode
    case vibe
    case unknown

    /// The agent's own environment names it: Claude Code sets `CLAUDECODE`,
    /// opencode `OPENCODE`, Codex `CODEX_THREAD_ID` in the commands they run
    /// (probed 2026-09-26). Vibe sets nothing of its own, so it passes
    /// `--agent vibe`.
    public static func detect(environment: [String: String]) -> AgentCLICaller {
        if environment["CLAUDECODE"]?.isEmpty == false { return .claude }
        if environment["OPENCODE"]?.isEmpty == false { return .opencode }
        if environment["CODEX_THREAD_ID"]?.isEmpty == false { return .codex }
        return .unknown
    }
}

public struct AgentCLIRequest: Sendable, Equatable, Codable {
    /// The wire version; its presence marks the line as a CLI request.
    public var cli: Int
    /// An `AgentCLICommand` raw value, kept as a string so an unknown command
    /// is an answer, not an unreadable line.
    public var command: String
    /// `history search`'s text.
    public var text: String?
    /// A project name, or an absolute path the command resolved from the
    /// caller's working directory.
    public var project: String?
    public var since: Date?
    public var limit: Int?
    /// `terms propose`'s terms.
    public var terms: [String]?
    public var caller: AgentCLICaller?
    /// `capture show` and `capture filed`: an id, a unique id prefix, a
    /// title, or a unique part of one.
    public var capture: String?
    /// `capture filed`'s issue URL.
    public var url: String?

    public init(
        command: AgentCLICommand,
        text: String? = nil,
        project: String? = nil,
        since: Date? = nil,
        limit: Int? = nil,
        terms: [String]? = nil,
        caller: AgentCLICaller? = nil,
        capture: String? = nil,
        url: String? = nil
    ) {
        self.cli = AgentCLIWire.version
        self.command = command.rawValue
        self.text = text
        self.project = project
        self.since = since
        self.limit = limit
        self.terms = terms
        self.caller = caller
        self.capture = capture
        self.url = url
    }

    public var knownCommand: AgentCLICommand? { AgentCLICommand(rawValue: command) }
}

public struct AgentCLIError: Error, Sendable, Equatable, Codable {
    public enum Code: String, Sendable, Codable {
        case badRequest
        case unsupportedVersion
        case unknownCommand
        /// No project matches `--project`.
        case unknownProject
        /// No capture matches, or more than one does.
        case unknownCapture
        case ambiguousCapture
        /// `capture filed` on a capture that is not waiting to be filed, or
        /// with a URL that is not an issue in its repository.
        case notFileable
        /// The app is running but could not answer in time.
        case busy
        /// Set by the command itself: nothing answered on the socket.
        case notRunning
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct AgentCLIProject: Sendable, Equatable, Codable {
    /// A local directory, `remote:<label>`, or `shared` for dictations that
    /// belong to no project (`LearnedTermProjectResolver`).
    public var key: String
    public var name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public struct AgentCLIDictation: Sendable, Equatable, Codable {
    public var id: String
    public var startedAt: Date
    public var finishedAt: Date
    /// The joined session's project; nil when the dictation joined none.
    public var project: AgentCLIProject?
    /// `claude`, `vibe`, `opencode`: the agent whose session it joined.
    public var agent: String?
    /// The bundle id of the app the text went to, when the commit knew it.
    public var targetApp: String?
    public var rawText: String
    public var finalText: String
    /// False when the text never reached the target app.
    public var inserted: Bool
    public var status: String

    public init(
        id: String,
        startedAt: Date,
        finishedAt: Date,
        project: AgentCLIProject?,
        agent: String?,
        targetApp: String?,
        rawText: String,
        finalText: String,
        inserted: Bool,
        status: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.project = project
        self.agent = agent
        self.targetApp = targetApp
        self.rawText = rawText
        self.finalText = finalText
        self.inserted = inserted
        self.status = status
    }
}

public struct AgentCLIHistory: Sendable, Equatable, Codable {
    /// False under History's "Don't keep": nothing is kept, so nothing is
    /// listed.
    public var historyKept: Bool
    /// Newest first.
    public var dictations: [AgentCLIDictation]

    public init(historyKept: Bool, dictations: [AgentCLIDictation]) {
        self.historyKept = historyKept
        self.dictations = dictations
    }
}

public struct AgentCLITerm: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        /// The user pinned it.
        case pinned
        /// Three dictations or a hand correction made it the user's.
        case confirmed
        /// Heard, not yet three times.
        case learning
        /// A coding agent proposed it; use or a pin has not confirmed it.
        case proposed
    }

    public var term: String
    public var state: State
    public var dictations: Int
    /// The agent that proposed it, if one did.
    public var proposedBy: String?
    public var lastSeen: Date

    public init(term: String, state: State, dictations: Int, proposedBy: String?, lastSeen: Date) {
        self.term = term
        self.state = state
        self.dictations = dictations
        self.proposedBy = proposedBy
        self.lastSeen = lastSeen
    }
}

public struct AgentCLITermProject: Sendable, Equatable, Codable {
    public var project: AgentCLIProject
    public var terms: [AgentCLITerm]

    public init(project: AgentCLIProject, terms: [AgentCLITerm]) {
        self.project = project
        self.terms = terms
    }
}

public struct AgentCLITerms: Sendable, Equatable, Codable {
    /// Settings' Global terms, which apply everywhere.
    public var userTerms: [String]
    public var projects: [AgentCLITermProject]

    public init(userTerms: [String], projects: [AgentCLITermProject]) {
        self.userTerms = userTerms
        self.projects = projects
    }
}

public struct AgentCLIProposal: Sendable, Equatable, Codable {
    public struct Skipped: Sendable, Equatable, Codable {
        public enum Reason: String, Sendable, Codable {
            /// The project already holds it, in any state.
            case known
            /// In Global terms, or a suggestion the user refused.
            case userList
            /// Not a term: too long, a sentence, control characters.
            case notTermShaped
            /// Past `AgentCLIWire.maxProposedTerms`.
            case overLimit
        }

        public var term: String
        public var reason: Reason

        public init(term: String, reason: Reason) {
            self.term = term
            self.reason = reason
        }
    }

    public var project: AgentCLIProject
    public var added: [String]
    public var skipped: [Skipped]

    public init(project: AgentCLIProject, added: [String], skipped: [Skipped]) {
        self.project = project
        self.added = added
        self.skipped = skipped
    }
}

public struct AgentCLIEngine: Sendable, Equatable, Codable {
    /// `managed_local`, `external_url` or `mistral_api`.
    public var backend: String
    public var model: String
    public var enabled: Bool

    public init(backend: String, model: String, enabled: Bool) {
        self.backend = backend
        self.model = model
        self.enabled = enabled
    }
}

public struct AgentCLIJoin: Sendable, Equatable, Codable {
    public var agent: String
    public var project: AgentCLIProject?
    /// How the session was found: `tty`, `herdrPane`, `desktopSession`, …
    public var mechanism: String
    public var remote: Bool

    public init(agent: String, project: AgentCLIProject?, mechanism: String, remote: Bool) {
        self.agent = agent
        self.project = project
        self.mechanism = mechanism
        self.remote = remote
    }
}

public struct AgentCLIStatus: Sendable, Equatable, Codable {
    public var running: Bool
    public var version: String?
    public var dictating: Bool
    public var historyKept: Bool
    public var dictation: AgentCLIEngine?
    public var polish: AgentCLIEngine?
    /// The session the last dictation joined; nil when it joined none or
    /// nothing was dictated since launch.
    public var lastJoin: AgentCLIJoin?

    public init(
        running: Bool,
        version: String? = nil,
        dictating: Bool = false,
        historyKept: Bool = false,
        dictation: AgentCLIEngine? = nil,
        polish: AgentCLIEngine? = nil,
        lastJoin: AgentCLIJoin? = nil
    ) {
        self.running = running
        self.version = version
        self.dictating = dictating
        self.historyKept = historyKept
        self.dictation = dictation
        self.polish = polish
        self.lastJoin = lastJoin
    }

    public static let notRunning = AgentCLIStatus(running: false)
}

/// One `doctor` check: what was checked, what was found, and when it is not
/// fine, the one step that fixes it. No dictated text and no key; a remote
/// host's check names the host.
public struct AgentCLICheck: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        case ok
        case warning
        case failed
        /// Nothing to check here (a feature that is off, an engine the app
        /// does not run).
        case skipped
    }

    /// Stable across versions, so an agent can match on it.
    public var id: String
    public var title: String
    public var state: State
    public var detail: String
    public var fix: String?
    /// Supporting lines, such as the last dictations' join lines, most
    /// recent first.
    public var lines: [String]?

    public init(
        id: String, title: String, state: State, detail: String, fix: String? = nil, lines: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.fix = fix
        self.lines = lines
    }
}

public struct AgentCLIDoctor: Sendable, Equatable, Codable {
    public var checks: [AgentCLICheck]

    public init(checks: [AgentCLICheck]) {
        self.checks = checks
    }

    public var hasFailure: Bool { checks.contains { $0.state == .failed } }

    /// Numbered, so a person can say "check 4" and an agent can quote it.
    /// The Mac's `doctor` and a remote host's print the same form.
    public func textLines(numberedFrom first: Int = 1) -> [String] {
        var lines: [String] = []
        for (index, check) in checks.enumerated() {
            let mark = switch check.state {
            case .ok: "ok  "
            case .warning: "warn"
            case .failed: "FAIL"
            case .skipped: "--  "
            }
            lines.append("\(first + index). [\(mark)] \(check.title): \(check.detail)")
            for line in check.lines ?? [] { lines.append("   \(line)") }
            if let fix = check.fix, check.state != .ok { lines.append("   fix: \(fix)") }
        }
        return lines
    }

    public var summaryLine: String {
        let failed = checks.filter { $0.state == .failed }.count
        let warned = checks.filter { $0.state == .warning }.count
        return failed + warned == 0 ? "No problems found." : "\(failed) failed, \(warned) to look at."
    }
}

/// One quick capture in the Inbox (#923). "Capture" is the Inbox item's name
/// here, not "issue": an agent reads "the issue about X" as a GitHub issue.
public struct AgentCLICapture: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        case routing
        case drafting
        /// Waiting for the user, or an agent, to file it.
        case ready
        case filing
        case filed
    }

    public var id: String
    public var capturedAt: Date
    /// Nil while the capture belongs to no project.
    public var project: AgentCLIProject?
    /// What the draft is: `issue`, `question`, `task` or `note` (#918).
    /// Only an issue is filed. Nil without a draft.
    public var kind: String?
    /// The draft's title, or the capture's first words while it has none.
    public var title: String
    public var state: State
    /// `owner/name`, where the draft files; nil when unknown.
    public var repository: String?
    /// `duplicate` or `extends` an open issue, with its number.
    public var relation: String?
    public var relatedIssue: Int?
    /// Why there is no draft, in one sentence.
    public var note: String?
    public var filedURL: String?
    /// `capture show` only: the words as dictated, the draft's body, and
    /// the body to file (the draft with the dictated words quoted under it,
    /// as the Inbox's File sends it).
    public var text: String?
    public var body: String?
    public var issueBody: String?

    public init(
        id: String,
        capturedAt: Date,
        project: AgentCLIProject?,
        kind: String?,
        title: String,
        state: State,
        repository: String? = nil,
        relation: String? = nil,
        relatedIssue: Int? = nil,
        note: String? = nil,
        filedURL: String? = nil,
        text: String? = nil,
        body: String? = nil,
        issueBody: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.project = project
        self.kind = kind
        self.title = title
        self.state = state
        self.repository = repository
        self.relation = relation
        self.relatedIssue = relatedIssue
        self.note = note
        self.filedURL = filedURL
        self.text = text
        self.body = body
        self.issueBody = issueBody
    }
}

public struct AgentCLICaptures: Sendable, Equatable, Codable {
    /// False when the app has no Inbox (quick capture unavailable).
    public var inboxAvailable: Bool
    /// Newest first.
    public var captures: [AgentCLICapture]

    public init(inboxAvailable: Bool, captures: [AgentCLICapture]) {
        self.inboxAvailable = inboxAvailable
        self.captures = captures
    }
}

/// One answer. Exactly one of the payloads is set when `ok`, `error` when not.
public struct AgentCLIResponse: Sendable, Equatable, Codable {
    public var cli: Int
    public var ok: Bool
    public var error: AgentCLIError?
    public var history: AgentCLIHistory?
    public var terms: AgentCLITerms?
    public var proposal: AgentCLIProposal?
    public var status: AgentCLIStatus?
    public var doctor: AgentCLIDoctor?
    /// `capture list`.
    public var captures: AgentCLICaptures?
    /// `capture show` and `capture filed`.
    public var capture: AgentCLICapture?

    public init(
        error: AgentCLIError? = nil,
        history: AgentCLIHistory? = nil,
        terms: AgentCLITerms? = nil,
        proposal: AgentCLIProposal? = nil,
        status: AgentCLIStatus? = nil,
        doctor: AgentCLIDoctor? = nil,
        captures: AgentCLICaptures? = nil,
        capture: AgentCLICapture? = nil
    ) {
        self.cli = AgentCLIWire.version
        self.ok = error == nil
        self.error = error
        self.history = history
        self.terms = terms
        self.proposal = proposal
        self.status = status
        self.doctor = doctor
        self.captures = captures
        self.capture = capture
    }

    public static func failure(_ code: AgentCLIError.Code, _ message: String) -> AgentCLIResponse {
        AgentCLIResponse(error: AgentCLIError(code, message))
    }
}
