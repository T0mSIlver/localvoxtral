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
        ["show", "--style", "ndjson", "--start", AgentCLILogs.startStamp(since, timeZone: timeZone),
         "--predicate", predicate]
    }
}

/// The app's lines in a few categories, every level `log show` prints by
/// default (notice, error, fault): what the failure alert's Show Log window
/// reads. Categories that hold dictated text (Deltas, Insertion) are never
/// asked for.
public struct AgentCLIFailureLogQuery: Equatable, Sendable {
    public var categories: [String]
    public var since: Date

    public init(categories: [String], since: Date) {
        self.categories = categories
        self.since = since
    }

    /// Before the failure: a connect timeout plus a retry fits in it.
    public static let defaultWindow: TimeInterval = 900

    public var predicate: String {
        let names = categories.map { "\"\($0)\"" }.joined(separator: ", ")
        return "subsystem == \"\(AgentCLILogsQuery.subsystem)\" AND category IN {\(names)}"
    }

    public func logShowArguments(timeZone: TimeZone) -> [String] {
        ["show", "--style", "ndjson", "--start", AgentCLILogs.startStamp(since, timeZone: timeZone),
         "--predicate", predicate]
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
    /// `log show --start` takes local time.
    static func startStamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Runs `/usr/bin/log` with `arguments` and returns its stdout. The
    /// output goes to a private temporary file, not a pipe: a pipe needs a
    /// reader running while the child writes (#60 bans the FileHandle ones).
    /// Blocks until `log` exits; call it off the main actor.
    public static func readWithLogShow(_ arguments: [String]) -> Result<Data, AgentCLILogsReadFailure> {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoxtral-logs-\(UUID().uuidString).ndjson")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output)
        else { return .failure(AgentCLILogsReadFailure("could not create a temporary file")) }
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(AgentCLILogsReadFailure("/usr/bin/log did not start (\(error.localizedDescription))"))
        }
        process.waitUntilExit()
        try? handle.close()
        guard process.terminationStatus == 0 else {
            return .failure(AgentCLILogsReadFailure("/usr/bin/log exited with \(process.terminationStatus)"))
        }
        guard let data = try? Data(contentsOf: output) else {
            return .failure(AgentCLILogsReadFailure("could not read log show's output"))
        }
        return .success(data)
    }

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

    /// The failure alert's Show Log text: the query's lines rendered as
    /// `logs` prints them, or why the log could not be read.
    public static func failureLog(
        _ query: AgentCLIFailureLogQuery,
        timeZone: TimeZone,
        readLog: ([String]) -> Result<Data, AgentCLILogsReadFailure>
    ) -> Result<String, AgentCLILogsReadFailure> {
        readLog(query.logShowArguments(timeZone: timeZone)).map {
            render(parse($0), json: false, timeZone: timeZone)
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
