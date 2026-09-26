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

switch arguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .help:
    write(AgentCLIArguments.usage + "\n", to: .standardOutput)
    exit(0)
case .usageError(let message):
    write("localvoxtral: \(message)\n\n\(AgentCLIArguments.usage)\n", to: .standardError)
    exit(AgentCLIRunner.ExitCode.usage.rawValue)
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
