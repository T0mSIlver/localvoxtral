import Foundation

/// Runs one project-terms request and reads its answer. The seam the
/// trigger tests replace.
package protocol ProjectTermProposalRunning: Sendable {
    func run(_ invocation: ProjectTermProposal.Invocation) async -> ProjectTermProposal.Outcome
}

/// The real run: the agent's CLI in the project directory, stdin from
/// `/dev/null`, a `ProjectTermProposal.timeoutSeconds` deadline, stdout
/// read through `BoundedProcess`.
package struct ProjectTermProposalProcessRunner: ProjectTermProposalRunning {
    /// The app's environment, which carries `HOME` and the login the CLIs
    /// read. `VIBE_HOME` is replaced for a Vibe run.
    private let environment: [String: String]
    /// The Vibe home this app owns (`VibeProposalHome`).
    private let vibeHome: URL
    /// The user's Vibe directory, whose `config.toml` and `.env` the app
    /// home links to. `~/.vibe`: a GUI app cannot see a `VIBE_HOME` the
    /// user's shell exports (`VibeHooksInstallService`).
    private let userVibeDirectory: URL
    private let isExecutable: @Sendable (String) -> Bool

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        vibeHome: URL,
        userVibeDirectory: URL,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environment = environment
        self.vibeHome = vibeHome
        self.userVibeDirectory = userVibeDirectory
        self.isExecutable = isExecutable
    }

    package func run(_ invocation: ProjectTermProposal.Invocation) async -> ProjectTermProposal.Outcome {
        let agent = invocation.agent
        guard let executable = Self.locate(agent, environment: environment, isExecutable: isExecutable) else {
            return .failed(.agentNotFound)
        }
        var environment = environment
        if agent == .vibe {
            guard VibeProposalHome.prepare(at: vibeHome, linkingTo: userVibeDirectory) else {
                return .failed(.launchFailed)
            }
            environment["VIBE_HOME"] = vibeHome.path
        }
        guard let output = await BoundedProcess.run(
            executableURL: executable,
            arguments: invocation.arguments,
            environment: environment,
            currentDirectory: invocation.workingDirectory,
            timeoutSeconds: ProjectTermProposal.timeoutSeconds,
            maxBytes: ProjectTermProposal.maxOutputBytes,
            label: "project terms \(agent.rawValue)"
        ) else {
            return .failed(.launchFailed)
        }
        if output.timedOut { return .failed(.timedOut) }
        if output.capped { return .failed(.outputTooLarge) }
        switch agent {
        case .claude: return ProjectTermProposal.parseClaude(stdout: output.data, exitCode: output.exitCode)
        case .vibe: return ProjectTermProposal.parseVibe(stdout: output.data, exitCode: output.exitCode)
        }
    }

    /// Where the CLI might live, in probe order: the installers' own
    /// directories, then PATH, then Homebrew. A GUI app's PATH is not the
    /// user's shell PATH.
    package static func candidates(for agent: ProjectTermProposal.Agent, environment: [String: String]) -> [String] {
        switch agent {
        case .claude:
            return ClaudePluginInstallService.claudeCLICandidates(environment: environment)
        case .vibe:
            var candidates: [String] = []
            if let home = environment["HOME"], !home.isEmpty {
                candidates.append("\(home)/.local/bin/vibe")
            }
            if let path = environment["PATH"] {
                for directory in path.split(separator: ":") where !directory.isEmpty {
                    candidates.append("\(directory)/vibe")
                }
            }
            candidates.append("/opt/homebrew/bin/vibe")
            candidates.append("/usr/local/bin/vibe")
            return candidates
        }
    }

    static func locate(
        _ agent: ProjectTermProposal.Agent,
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> URL? {
        candidates(for: agent, environment: environment).first(where: isExecutable).map {
            URL(fileURLWithPath: $0)
        }
    }
}

/// The `VIBE_HOME` a Vibe terms run uses. Vibe has no flag to turn hooks
/// off, and under the user's own home it fires every `hooks.toml` hook,
/// ours included, which would publish a phantom session. This directory
/// holds only two symlinks, to the user's `config.toml` and `.env`, so Vibe
/// finds the user's model and key and no hook. The app reads neither file
/// and writes nothing into the user's directory. Vibe writes the run's
/// session log here, so the run stays out of the user's Vibe history.
package enum VibeProposalHome {
    package static let linkedFiles = ["config.toml", ".env"]

    /// Creates the directory and points each link at the user's file,
    /// replacing a link that points elsewhere and removing one whose target
    /// is gone. False only when the directory cannot be created, or a link
    /// name is taken by something that is not a symlink.
    @discardableResult
    package static func prepare(
        at home: URL,
        linkingTo userDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        } catch {
            Log.backends.error("Project terms: cannot create the Vibe home: \(error.localizedDescription, privacy: .public)")
            return false
        }
        for name in linkedFiles {
            let link = home.appendingPathComponent(name)
            let target = userDirectory.appendingPathComponent(name).path
            let current = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
            let targetExists = fileManager.fileExists(atPath: target)
            if current == target, targetExists { continue }
            if current != nil {
                try? fileManager.removeItem(at: link)
            } else if (try? fileManager.attributesOfItem(atPath: link.path)) != nil {
                Log.backends.error("Project terms: \(name, privacy: .public) in the Vibe home is not a link; not running")
                return false
            }
            guard targetExists else { continue }
            do {
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            } catch {
                Log.backends.error("Project terms: cannot link \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        return true
    }
}
