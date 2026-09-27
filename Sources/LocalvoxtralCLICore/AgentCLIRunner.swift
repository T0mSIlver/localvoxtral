import ClaudeContextWire
import ClaudeHookPublisherCore
import Foundation

/// Sends one request to the app and turns the answer into what the command
/// prints and its exit status.
public struct AgentCLIRunner: Sendable {
    public enum ExitCode: Int32, Sendable {
        case answered = 0
        case refused = 1
        case usage = 2
        case notRunning = 3
    }

    public struct Outcome: Equatable, Sendable {
        public var stdout: String
        public var stderr: String
        public var exitCode: ExitCode
    }

    /// Writes a request line and returns the reply line.
    public typealias Transport = @Sendable (Data) -> Result<Data?, ClaudeHookPublishFailure>

    public var transport: Transport
    public var timeZone: TimeZone

    public init(transport: @escaping Transport, timeZone: TimeZone) {
        self.transport = transport
        self.timeZone = timeZone
    }

    /// Over the hook broker's socket. The deadline covers the app's answer,
    /// which the broker bounds at 10 s, plus the write.
    public static func socketTransport(socketPath: String?) -> Transport {
        { line in
            guard let socketPath else { return .failure(.noSocketPath) }
            return UnixSocketPublisher(timeout: 12, maxReplyBytes: AgentCLIWire.maxResponseBytes)
                .publishAndReadReply(line: line, to: socketPath)
        }
    }

    public func run(_ invocation: AgentCLIInvocation) -> Outcome {
        guard let line = AgentCLIWire.encodeLine(invocation.request) else {
            return Outcome(stdout: "", stderr: "localvoxtral: could not encode the request\n", exitCode: .usage)
        }
        let response: AgentCLIResponse
        switch transport(line) {
        case .failure(.noSocketPath), .failure(.notListening), .failure(.socketPathTooLong):
            if invocation.request.knownCommand == .status {
                response = AgentCLIResponse(status: .notRunning)
            } else {
                response = .failure(.notRunning, "localvoxtral is not running")
            }
        case .failure(.timedOut):
            response = .failure(.busy, "localvoxtral did not answer in time")
        case .failure:
            response = .failure(.notRunning, "could not reach localvoxtral")
        case .success(let reply):
            guard let reply, let decoded = AgentCLIWire.decodeResponse(reply) else {
                return Outcome(
                    stdout: "",
                    stderr: "localvoxtral: the app sent an answer this command cannot read; update the command from Settings\n",
                    exitCode: .refused
                )
            }
            response = decoded
        }

        let exitCode: ExitCode
        if let error = response.error {
            exitCode = error.code == .notRunning ? .notRunning : .refused
        } else {
            exitCode = .answered
        }
        if invocation.json {
            let text = AgentCLIWire.encodeLine(response).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return Outcome(stdout: text, stderr: "", exitCode: exitCode)
        }
        if let error = response.error {
            return Outcome(stdout: "", stderr: "localvoxtral: \(error.message)\n", exitCode: exitCode)
        }
        let text = AgentCLIText(timeZone: timeZone).render(response)
        return Outcome(stdout: text, stderr: "", exitCode: exitCode)
    }
}

/// The human-readable form of an answer. Agents should pass `--json`.
public struct AgentCLIText: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    public func render(_ response: AgentCLIResponse) -> String {
        var lines: [String] = []
        if let history = response.history { lines += render(history) }
        if let terms = response.terms { lines += render(terms) }
        if let proposal = response.proposal { lines += render(proposal) }
        if let status = response.status { lines += render(status) }
        return lines.map { $0 + "\n" }.joined()
    }

    private func render(_ history: AgentCLIHistory) -> [String] {
        guard history.historyKept else { return ["History is off (Settings > History: Don't keep)."] }
        guard !history.dictations.isEmpty else { return ["No dictations."] }
        var lines: [String] = []
        for (index, dictation) in history.dictations.enumerated() {
            if index > 0 { lines.append("") }
            var heading = [timestamp(dictation.startedAt)]
            if let project = dictation.project { heading.append(project.name) }
            if let agent = dictation.agent { heading.append(agent) }
            if let app = dictation.targetApp { heading.append(app) }
            if !dictation.inserted { heading.append("not inserted") }
            lines.append(heading.joined(separator: "  "))
            lines.append("  " + dictation.finalText)
            if dictation.rawText != dictation.finalText {
                lines.append("  heard: " + dictation.rawText)
            }
        }
        return lines
    }

    private func render(_ terms: AgentCLITerms) -> [String] {
        var lines = ["Names and terms: " + (terms.userTerms.isEmpty ? "none" : terms.userTerms.joined(separator: ", "))]
        for project in terms.projects {
            lines.append("")
            let where_ = project.project.key.hasPrefix("/") ? " (\(project.project.key))" : ""
            lines.append(project.project.name + where_)
            for term in project.terms {
                var detail: String
                switch term.state {
                case .pinned: detail = "pinned"
                case .confirmed: detail = "yours"
                case .learning: detail = "learning, \(term.dictations) of 3 dictations"
                case .proposed:
                    detail = "proposed by \(term.proposedBy ?? "an agent"), \(term.dictations) of 3 dictations"
                }
                if term.state == .pinned || term.state == .confirmed {
                    detail += ", \(term.dictations) dictation\(term.dictations == 1 ? "" : "s")"
                }
                lines.append("  \(term.term)  \(detail)")
            }
        }
        return lines
    }

    private func render(_ proposal: AgentCLIProposal) -> [String] {
        var lines: [String] = []
        let project = proposal.project.name
        lines.append(
            proposal.added.isEmpty
                ? "Nothing added to \(project)."
                : "Proposed for \(project): \(proposal.added.joined(separator: ", ")). Three dictations or a pin in Settings make them yours."
        )
        for skipped in proposal.skipped {
            let reason = switch skipped.reason {
            case .known: "the project already has it"
            case .userList: "in your names and terms, or a suggestion you refused"
            case .notTermShaped: "not a term"
            case .overLimit: "over \(AgentCLIWire.maxProposedTerms) terms"
            }
            lines.append("Skipped \(skipped.term): \(reason).")
        }
        return lines
    }

    private func render(_ status: AgentCLIStatus) -> [String] {
        guard status.running else { return ["localvoxtral is not running."] }
        var lines = ["localvoxtral \(status.version ?? "") is running\(status.dictating ? ", dictating" : "")."]
        if let engine = status.dictation {
            lines.append("Dictation: \(engine.model) (\(engine.backend))")
        }
        if let engine = status.polish {
            lines.append(engine.enabled ? "Polish: \(engine.model) (\(engine.backend))" : "Polish: off")
        }
        lines.append("History: \(status.historyKept ? "kept" : "off")")
        if let join = status.lastJoin {
            let project = join.project.map { " in \($0.name)" } ?? ""
            lines.append("Last dictation joined: \(join.agent)\(project), \(join.remote ? "remote" : "local"), by \(join.mechanism)")
        } else {
            lines.append("Last dictation joined: no session")
        }
        return lines
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
