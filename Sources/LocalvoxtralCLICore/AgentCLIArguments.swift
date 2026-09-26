import ClaudeContextWire
import Foundation

/// What `localvoxtral <command> …` asked for.
public struct AgentCLIInvocation: Equatable, Sendable {
    public var request: AgentCLIRequest
    public var json: Bool

    public init(request: AgentCLIRequest, json: Bool) {
        self.request = request
        self.json = json
    }
}

public enum AgentCLIParseResult: Equatable, Sendable {
    case run(AgentCLIInvocation)
    case help
    case usageError(String)
}

/// Reads the command line. The clock, the time zone, the working directory and
/// the environment are passed in, so every answer here is testable.
public struct AgentCLIArguments: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var workingDirectory: String
    public var environment: [String: String]

    public init(now: Date, timeZone: TimeZone, workingDirectory: String, environment: [String: String]) {
        self.now = now
        self.timeZone = timeZone
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public static let usage = """
        usage: localvoxtral <command> [options]

        Reads your dictation history and terms from the running localvoxtral app.

          history search <text>   dictations containing <text>
              --project <dir|name>  only dictations that joined this project
              --since <when>        today, yesterday, 3d, 12h, 30m, 2w, or 2026-09-25
              --limit <n>           at most n dictations (default 20, max 200)
          history last            the last dictation, inserted or not
          terms list              your names and terms, learned and proposed
              --project <dir|name>  one project's terms
          terms propose <term>…   suggest terms for a project; three dictations
                                  or a pin in Settings make one yours
              --project <dir>       the project (default: the current directory)
              --agent <name>        claude, codex, opencode or vibe (default: detected)
          status                  whether the app runs, its engines, the last join

        Every command takes --json. Exit status: 0 answered, 1 the app refused,
        2 bad arguments, 3 the app is not running.
        """

    public func parse(_ arguments: [String]) -> AgentCLIParseResult {
        var positional: [String] = []
        var options: [String: String] = [:]
        var json = false
        var index = 0
        let valued: Set<String> = ["--project", "--since", "--limit", "--agent"]
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return .help
            case "--json":
                json = true
            case "--":
                positional += arguments[(index + 1)...]
                index = arguments.count
                continue
            default:
                if let equals = argument.firstIndex(of: "="), valued.contains(String(argument[..<equals])) {
                    options[String(argument[..<equals])] = String(argument[argument.index(after: equals)...])
                } else if valued.contains(argument) {
                    guard index + 1 < arguments.count else { return .usageError("\(argument) needs a value") }
                    options[argument] = arguments[index + 1]
                    index += 1
                } else if argument.hasPrefix("--") {
                    return .usageError("unknown option \(argument)")
                } else {
                    positional.append(argument)
                }
            }
            index += 1
        }

        guard let group = positional.first, group != "help" else { return .help }
        let rest = Array(positional.dropFirst())
        let command: AgentCLICommand
        var operands: [String]
        switch group {
        case "status":
            command = .status
            operands = rest
        case "history", "terms":
            guard let verb = rest.first else { return .usageError("\(group) needs a command") }
            operands = Array(rest.dropFirst())
            switch (group, verb) {
            case ("history", "search"): command = .historySearch
            case ("history", "last"): command = .historyLast
            case ("terms", "list"): command = .termsList
            case ("terms", "propose"): command = .termsPropose
            default: return .usageError("unknown command: \(group) \(verb)")
            }
        default:
            return .usageError("unknown command: \(group)")
        }

        let allowed: Set<String>
        switch command {
        case .historySearch: allowed = ["--project", "--since", "--limit"]
        case .termsList: allowed = ["--project"]
        case .termsPropose: allowed = ["--project", "--agent"]
        case .historyLast, .status: allowed = []
        }
        if let stray = options.keys.sorted().first(where: { !allowed.contains($0) }) {
            return .usageError("\(stray) does not apply to \(command.rawValue.replacingOccurrences(of: ".", with: " "))")
        }

        var request = AgentCLIRequest(command: command)
        switch command {
        case .historySearch:
            request.text = operands.joined(separator: " ")
            operands = []
        case .termsPropose:
            guard !operands.isEmpty else { return .usageError("terms propose needs at least one term") }
            request.terms = operands
            operands = []
            request.project = project(options["--project"] ?? ".")
            if let agent = options["--agent"] {
                guard let caller = AgentCLICaller(rawValue: agent.lowercased()), caller != .unknown else {
                    return .usageError("--agent must be claude, codex, opencode or vibe")
                }
                request.caller = caller
            } else {
                request.caller = AgentCLICaller.detect(environment: environment)
            }
        case .historyLast, .termsList, .status:
            break
        }
        guard operands.isEmpty else { return .usageError("unexpected argument: \(operands[0])") }

        if command != .termsPropose, let value = options["--project"] {
            request.project = project(value)
        }
        if let value = options["--since"] {
            guard let since = since(value) else {
                return .usageError("--since takes today, yesterday, 3d, 12h, 30m, 2w, or a date like 2026-09-25")
            }
            request.since = since
        }
        if let value = options["--limit"] {
            guard let limit = Int(value), (1...AgentCLIWire.maxHistoryLimit).contains(limit) else {
                return .usageError("--limit must be between 1 and \(AgentCLIWire.maxHistoryLimit)")
            }
            request.limit = limit
        }
        return .run(AgentCLIInvocation(request: request, json: json))
    }

    /// A directory becomes an absolute path; anything else is a project name.
    /// Something that looks like a path is a path: `.`, `..`, `~`, or any
    /// string with a `/`.
    func project(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let looksLikePath = trimmed == "." || trimmed == ".." || trimmed.hasPrefix("~") || trimmed.contains("/")
        guard looksLikePath else { return trimmed }
        var path = trimmed
        if path == "~" || path.hasPrefix("~/"), let home = environment["HOME"] {
            path = home + path.dropFirst()
        }
        if !path.hasPrefix("/") {
            path = workingDirectory + "/" + path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The start of the window `--since` names, in the caller's time zone.
    func since(_ value: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        switch trimmed {
        case "today":
            return calendar.startOfDay(for: now)
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default:
            break
        }
        if let unit = trimmed.last, let count = Int(trimmed.dropLast()), count >= 0 {
            let seconds: Double? = switch unit {
            case "m": 60
            case "h": 3_600
            case "d": 86_400
            case "w": 604_800
            default: nil
            }
            if let seconds { return now.addingTimeInterval(-Double(count) * seconds) }
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = calendar
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: trimmed) { return date }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}
