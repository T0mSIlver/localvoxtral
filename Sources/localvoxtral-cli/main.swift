import ClaudeContextWire
import ClaudeHookPublisherCore
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

/// Raw `write(2)`, never `FileHandle.write`: that raises an uncatchable
/// exception on a closed or broken descriptor, and the command aborted
/// instead of exiting with its status (#1165). A lost write never changes the
/// status.
func write(_ text: String, toDescriptor descriptor: Int32) {
    guard !text.isEmpty else { return }
    ClaudeHookPublisher.writeAll(Data(text.utf8), toDescriptor: descriptor)
}

let standardOutput: Int32 = 1
let standardError: Int32 = 2

switch arguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .help:
    write(AgentCLIArguments.usage + "\n", toDescriptor: standardOutput)
    exit(0)
case .usageError(let message):
    write("localvoxtral: \(message)\n\n\(AgentCLIArguments.usage)\n", toDescriptor: standardError)
    exit(AgentCLIRunner.ExitCode.usage.rawValue)
case .logs(let query):
    let outcome = AgentCLILogs.run(query, timeZone: .current, readLog: AgentCLILogs.readWithLogShow)
    write(outcome.stdout, toDescriptor: standardOutput)
    write(outcome.stderr, toDescriptor: standardError)
    exit(outcome.exitCode.rawValue)
case .run(let invocation):
    let runner = AgentCLIRunner(
        transport: AgentCLIRunner.socketTransport(socketPath: ClaudeHookSocketPath.resolve(environment: environment)),
        timeZone: .current
    )
    let outcome = runner.run(invocation)
    write(outcome.stdout, toDescriptor: standardOutput)
    write(outcome.stderr, toDescriptor: standardError)
    exit(outcome.exitCode.rawValue)
}
