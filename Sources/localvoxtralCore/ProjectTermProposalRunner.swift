import Foundation

/// Runs one project-terms request and reads its answer. The seam the
/// trigger tests replace.
package protocol ProjectTermProposalRunning: Sendable {
    func run(_ invocation: ProjectTermProposal.Invocation) async -> ProjectTermProposal.Outcome
}

/// The real run: the agent's CLI in the project directory, with the
/// invocation's variables over the app's environment, stdin from
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
        var environment = environment.merging(invocation.environment) { _, run in run }
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
        case .vibe:
            return ProjectTermProposal.parseVibe(stdout: output.data, exitCode: output.exitCode)
                .reporting(VibeSessionUsage.read(home: vibeHome, output: output.data))
        case .opencode: return ProjectTermProposal.parseOpencode(stdout: output.data, exitCode: output.exitCode)
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
            return commonCandidates(for: "vibe", environment: environment, homeDirectories: [".local/bin"])
        case .opencode:
            // opencode's install script puts it in ~/.opencode/bin.
            return commonCandidates(
                for: "opencode", environment: environment, homeDirectories: [".opencode/bin", ".local/bin"]
            )
        }
    }

    private static func commonCandidates(
        for name: String,
        environment: [String: String],
        homeDirectories: [String]
    ) -> [String] {
        var candidates: [String] = []
        if let home = environment["HOME"], !home.isEmpty {
            candidates += homeDirectories.map { "\(home)/\($0)/\(name)" }
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                candidates.append("\(directory)/\(name)")
            }
        }
        candidates.append("/opt/homebrew/bin/\(name)")
        candidates.append("/usr/local/bin/\(name)")
        return candidates
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

/// What a Vibe run used, from the session log Vibe writes under the app's
/// `VIBE_HOME`; `vibe -p --output json` carries no usage. Measured on Vibe
/// 2.25.4's unified harness (2026-09-27): the output's entries name the
/// session, `logs/session/unified/<id>/CURRENT` names its newest generation,
/// and that generation's `projection-state.json` holds
/// `snapshot.session.tokenUsage`, summed over the run's turns, with the
/// cached input inside the input count. Vibe keeps no price. The same file
/// holds the prompt as `preview`; only the three counts are read.
package enum VibeSessionUsage {
    /// The session the output's entries name: 1 to 64 ASCII letters,
    /// digits and `-`, so it can name a directory and nothing else.
    package static func sessionID(inOutput stdout: Data) -> String? {
        guard let entries = try? JSONSerialization.jsonObject(with: stdout) as? [[String: Any]],
              let id = entries.lazy.compactMap({ $0["sessionId"] as? String }).first,
              isPathComponent(id)
        else { return nil }
        return id
    }

    /// The run's usage, or nil when the log is missing or not this shape.
    package static func read(home: URL, output: Data, fileManager: FileManager = .default) -> ProjectTermProposal.Usage? {
        guard let id = sessionID(inOutput: output) else { return nil }
        let session = home.appendingPathComponent("logs/session/unified/\(id)", isDirectory: true)
        guard let current = fileManager.contents(atPath: session.appendingPathComponent("CURRENT").path),
              let object = try? JSONSerialization.jsonObject(with: current) as? [String: Any],
              let generation = object["generation"] as? String, isPathComponent(generation),
              let state = fileManager.contents(
                  atPath: session.appendingPathComponent("generations/\(generation)/projection-state.json").path)
        else { return nil }
        return usage(inProjectionState: state)
    }

    package static func usage(inProjectionState data: Data) -> ProjectTermProposal.Usage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = object["snapshot"] as? [String: Any],
              let session = snapshot["session"] as? [String: Any],
              let tokens = session["tokenUsage"] as? [String: Any]
        else { return nil }
        return usage(
            inputTokens: (tokens["inputTokens"] as? NSNumber)?.intValue,
            cachedInputTokens: (tokens["cachedInputTokens"] as? NSNumber)?.intValue,
            outputTokens: (tokens["outputTokens"] as? NSNumber)?.intValue
        )
    }

    /// Vibe's counts in the ledger's terms: its input includes the cached
    /// part, which the ledger counts as cache reads beside the rest.
    package static func usage(inputTokens: Int?, cachedInputTokens: Int?, outputTokens: Int?)
        -> ProjectTermProposal.Usage?
    {
        guard let input = inputTokens, input >= 0 else { return nil }
        let cached = cachedInputTokens.map { min(max($0, 0), input) }
        return ProjectTermProposal.Usage(
            turns: nil,
            costUSD: nil,
            inputTokens: input - (cached ?? 0),
            cacheWriteTokens: nil,
            cacheReadTokens: cached,
            outputTokens: outputTokens.map { max($0, 0) }
        )
    }

    private static func isPathComponent(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count)
            && value.utf8.allSatisfy { byte in
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || byte == UInt8(ascii: "-")
            }
    }
}

extension ProjectTermProposal.Outcome {
    /// An answer with `usage` beside it, when it has none of its own.
    package func reporting(_ usage: ProjectTermProposal.Usage?) -> Self {
        guard let usage, case .terms(let terms, nil, let line) = self else { return self }
        return .terms(terms, usage: usage, line: line)
    }
}

extension QuickCaptureDraft.Outcome {
    /// A draft with `usage` beside it, when it has none of its own.
    package func reporting(_ usage: ProjectTermProposal.Usage?) -> Self {
        guard let usage, case .draft(let draft, nil) = self else { return self }
        return .draft(draft, usage: usage)
    }
}
