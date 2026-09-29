import ClaudeContextWire
import Foundation

/// `localvoxtral logs`: the app's join outcome lines, and with them its error
/// and fault lines, from the unified log. The command reads the log itself
/// with `log show`, so it answers while the app is not running.
///
/// It prints what `log show` prints: a value the app logs private stays
/// `<private>`. `AgentCLILogPrivacyTests` keeps dictated text out of the
/// public values.
public struct AgentCLILogsQuery: Equatable, Sendable {
    /// Only the join outcome lines, one per dictation.
    public var joinOnly: Bool
    public var since: Date
    public var json: Bool

    public init(joinOnly: Bool, since: Date, json: Bool) {
        self.joinOnly = joinOnly
        self.since = since
        self.json = json
    }

    /// Without `--since`.
    public static let defaultWindow: TimeInterval = 3_600

    public static let subsystem = "com.localvoxtral"
    /// `SessionContextResolver.joinOutcomeLog`'s prefix.
    public static let joinOutcomePrefix = "Claude join outcome: "

    public var predicate: String {
        let join = "eventMessage BEGINSWITH \"\(Self.joinOutcomePrefix)\""
        let lines = joinOnly ? join : "(\(join) OR messageType == error OR messageType == fault)"
        return "subsystem == \"\(Self.subsystem)\" AND \(lines)"
    }

    /// The arguments for `/usr/bin/log`. `--start` takes local time.
    public func logShowArguments(timeZone: TimeZone) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return ["show", "--style", "ndjson", "--start", formatter.string(from: since), "--predicate", predicate]
    }
}

/// One line of the app's log.
public struct AgentCLILogLine: Equatable, Sendable, Codable {
    public var at: Date
    /// notice, error or fault.
    public var level: String
    public var category: String
    public var message: String

    public init(at: Date, level: String, category: String, message: String) {
        self.at = at
        self.level = level
        self.category = category
        self.message = message
    }
}

public struct AgentCLILogsReadFailure: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum AgentCLILogs {
    /// `log show --style ndjson` output, oldest first. Lines that are not a
    /// log entry (the closing summary, a warning) are skipped.
    public static func parse(_ output: Data) -> [AgentCLILogLine] {
        // `log show` writes microseconds and a `+0200` offset; a line without
        // the fraction, or with a `+02:00` offset, still parses.
        let formats = ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ssZ",
                       "yyyy-MM-dd HH:mm:ss.SSSSSSxxx", "yyyy-MM-dd HH:mm:ssxxx"]
        let timestamps = formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
        return output.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let rawTime = object["timestamp"] as? String,
                  let at = timestamps.lazy.compactMap({ $0.date(from: rawTime) }).first
            else { return nil }
            let level = switch (object["messageType"] as? String)?.lowercased() {
            case "error": "error"
            case "fault": "fault"
            case "info": "info"
            case "debug": "debug"
            default: "notice"
            }
            return AgentCLILogLine(
                at: at, level: level, category: object["category"] as? String ?? "", message: message
            )
        }
    }

    /// Runs `log show` through `readLog` (its arguments in, its stdout or
    /// an error sentence out) and renders the answer.
    public static func run(
        _ query: AgentCLILogsQuery,
        timeZone: TimeZone,
        readLog: ([String]) -> Result<Data, AgentCLILogsReadFailure>
    ) -> AgentCLIRunner.Outcome {
        switch readLog(query.logShowArguments(timeZone: timeZone)) {
        case .failure(let failure):
            return AgentCLIRunner.Outcome(
                stdout: "", stderr: "localvoxtral: could not read the log: \(failure.message)\n", exitCode: .refused
            )
        case .success(let output):
            return AgentCLIRunner.Outcome(
                stdout: render(parse(output), json: query.json, timeZone: timeZone), stderr: "", exitCode: .answered
            )
        }
    }

    public struct Output: Codable, Equatable, Sendable {
        public var cli: Int
        public var ok: Bool
        public var logs: [AgentCLILogLine]
    }

    public static func render(_ lines: [AgentCLILogLine], json: Bool, timeZone: TimeZone) -> String {
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let output = Output(cli: AgentCLIWire.version, ok: true, logs: lines)
            return (try? encoder.encode(output)).flatMap { String(data: $0, encoding: .utf8) }.map { $0 + "\n" } ?? ""
        }
        guard !lines.isEmpty else { return "No lines in that window.\n" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return lines.map { line in
            let level = line.level == "notice" ? "" : " \(line.level):"
            return "\(formatter.string(from: line.at)) [\(line.category)]\(level) \(line.message)\n"
        }.joined()
    }
}
