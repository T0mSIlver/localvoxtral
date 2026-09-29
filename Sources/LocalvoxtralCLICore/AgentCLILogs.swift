import ClaudeContextWire
import Foundation

extension AgentCLILogs {
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
}
