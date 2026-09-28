import ClaudeContextWire
import Foundation
import LocalvoxtralCLICore

// localvoxtral — the command agents (and people) run to read dictation history
// and terms from the running app (#721). Settings installs it as
// /usr/local/bin/localvoxtral, a link to this binary inside the app bundle.
//
// The target is named `localvoxtral-cli` because the app's own target already
// holds the name, and SwiftPM names a binary after its target.

let environment = ProcessInfo.processInfo.environment
let arguments = AgentCLIArguments(
    now: Date(),
    timeZone: .current,
    workingDirectory: FileManager.default.currentDirectoryPath,
    environment: environment
)

func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else { return }
    handle.write(Data(text.utf8))
}

/// `log show`'s stdout goes to a private temporary file, not a pipe: a
/// pipe needs a reader running while the child writes (#60 bans the
/// FileHandle ones).
func readUnifiedLog(_ arguments: [String]) -> Result<Data, AgentCLILogsReadFailure> {
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

switch arguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .help:
    write(AgentCLIArguments.usage + "\n", to: .standardOutput)
    exit(0)
case .usageError(let message):
    write("localvoxtral: \(message)\n\n\(AgentCLIArguments.usage)\n", to: .standardError)
    exit(AgentCLIRunner.ExitCode.usage.rawValue)
case .logs(let query):
    let outcome = AgentCLILogs.run(query, timeZone: .current, readLog: readUnifiedLog)
    write(outcome.stdout, to: .standardOutput)
    write(outcome.stderr, to: .standardError)
    exit(outcome.exitCode.rawValue)
case .run(let invocation):
    let runner = AgentCLIRunner(
        transport: AgentCLIRunner.socketTransport(socketPath: ClaudeHookSocketPath.resolve(environment: environment)),
        timeZone: .current
    )
    let outcome = runner.run(invocation)
    write(outcome.stdout, to: .standardOutput)
    write(outcome.stderr, to: .standardError)
    exit(outcome.exitCode.rawValue)
}
