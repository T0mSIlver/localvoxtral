import Foundation
import Observation
import SwiftUI

/// Installs and removes the `localvoxtral` command (#721): a link at
/// `/usr/local/bin/localvoxtral` to the binary in this app's bundle. Where
/// that directory is not the user's to write, macOS asks for an
/// administrator's password.
@MainActor
@Observable
final class AgentCLIInstallModel {
    private(set) var state: AgentCLIInstallState = .notInstalled
    private(set) var isWorking = false
    /// The last action's failure, shown until the next refresh.
    private(set) var failure: String?

    let bundledBinary: String

    init(
        bundledBinary: String = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(AgentCLIInstallState.binaryName).path ?? ""
    ) {
        self.bundledBinary = bundledBinary
    }

    func refresh() {
        state = AgentCLIInstallState.read(bundledBinary: bundledBinary)
    }

    var statusText: String {
        if let failure { return failure }
        switch state {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed as localvoxtral"
        case .otherCopy: return "Points to another copy of the app"
        case .foreign: return "Another file is at \(AgentCLIInstallState.linkPath)"
        }
    }

    func install() async {
        guard FileManager.default.isExecutableFile(atPath: bundledBinary) else {
            Log.backends.error("CLI install: the app bundle has no \(AgentCLIInstallState.binaryName, privacy: .public)")
            failure = "This build has no command-line tool"
            return
        }
        await run(
            AgentCLIInstallState.installCommand(bundledBinary: bundledBinary),
            action: "install"
        ) { [bundledBinary] in
            let fileManager = FileManager.default
            try? fileManager.removeItem(atPath: AgentCLIInstallState.linkPath)
            try fileManager.createSymbolicLink(
                atPath: AgentCLIInstallState.linkPath, withDestinationPath: bundledBinary)
        }
    }

    func remove() async {
        // Only a link we made: `foreign` offers no Remove.
        guard state == .installed || state == .otherCopy else { return }
        await run(AgentCLIInstallState.removeCommand(), action: "remove") {
            try FileManager.default.removeItem(atPath: AgentCLIInstallState.linkPath)
        }
    }

    /// Writes directly when the directory is the user's (an Intel Homebrew
    /// setup), through an administrator prompt otherwise.
    private func run(
        _ command: String,
        action: String,
        direct: @escaping @Sendable () throws -> Void
    ) async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        let directory = (AgentCLIInstallState.linkPath as NSString).deletingLastPathComponent
        let succeeded: Bool = await Task.detached {
            if FileManager.default.isWritableFile(atPath: directory) {
                do {
                    try direct()
                    return true
                } catch {
                    Log.backends.error(
                        "CLI \(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", AgentCLIInstallState.privilegedAppleScript(command)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                Log.backends.error(
                    "CLI \(action, privacy: .public): osascript did not start: \(error.localizedDescription, privacy: .public)")
                return false
            }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                // Also what a cancelled password prompt looks like.
                Log.backends.error(
                    "CLI \(action, privacy: .public): the privileged step exited \(process.terminationStatus, privacy: .public)")
                return false
            }
            return true
        }.value
        refresh()
        if succeeded {
            Log.backends.info("CLI \(action, privacy: .public): done, \(String(describing: self.state), privacy: .public)")
        } else {
            failure = action == "install" ? "Not installed" : "Not removed"
        }
    }
}

/// One row: the command's state, and the one action that changes it.
struct AgentCLIInstallRow: View {
    @Bindable var model: AgentCLIInstallModel

    var body: some View {
        SettingsFieldRow(
            title: "Command-line tool",
            status: model.statusText,
            statusAccessibilityIdentifier: "settings.general.cli.status"
        ) {
            HStack(spacing: 8) {
                // "…": macOS asks for an administrator's password first.
                switch model.state {
                case .notInstalled:
                    Button("Install…") { Task { await model.install() } }
                        .accessibilityIdentifier("settings.general.cli.install")
                case .otherCopy:
                    Button("Update…") { Task { await model.install() } }
                        .accessibilityIdentifier("settings.general.cli.install")
                case .installed, .foreign:
                    EmptyView()
                }
                if model.state == .installed || model.state == .otherCopy {
                    Button("Remove…") { Task { await model.remove() } }
                        .accessibilityIdentifier("settings.general.cli.remove")
                }
                if model.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(model.isWorking)
            .controlSize(.small)
        }
    }
}
