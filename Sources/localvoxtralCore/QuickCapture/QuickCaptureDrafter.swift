import Foundation

/// Runs one drafting invocation. The seam the drafter's tests replace.
package protocol QuickCaptureDraftRunning: Sendable {
    func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome
}

/// The real run, on #609's process plumbing: the same CLI lookup, the same
/// app-owned `VIBE_HOME` that keeps the user's hooks out, `BoundedProcess`.
package struct QuickCaptureDraftProcessRunner: QuickCaptureDraftRunning {
    private let environment: [String: String]
    private let vibeHome: URL
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

    package func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome {
        let agent = invocation.agent
        // Drafting speaks Claude Code's and Vibe's output; opencode's is a
        // follow-up, so it reads as not installed and the next agent runs.
        guard agent != .opencode else { return .failed(.agentNotFound) }
        guard let executable = ProjectTermProposalProcessRunner.locate(
            agent, environment: environment, isExecutable: isExecutable
        ) else {
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
            timeoutSeconds: QuickCaptureDraft.timeoutSeconds,
            maxBytes: QuickCaptureDraft.maxOutputBytes,
            label: "quick capture draft \(agent.rawValue)"
        ) else {
            return .failed(.launchFailed)
        }
        if output.timedOut { return .failed(.timedOut) }
        if output.capped { return .failed(.outputTooLarge) }
        switch agent {
        case .claude: return QuickCaptureDraft.parseClaude(stdout: output.data, exitCode: output.exitCode, openIssues: openIssues)
        case .vibe: return QuickCaptureDraft.parseVibe(stdout: output.data, exitCode: output.exitCode, openIssues: openIssues)
        case .opencode: return .failed(.agentNotFound)
        }
    }
}

/// Drafts an issue for a routed capture (#731): lists the project's open
/// issues with the user's `gh`, then asks the first installed agent.
package struct QuickCaptureDrafter: Sendable {
    private let runner: any QuickCaptureDraftRunning
    /// The open issues of the repository at a path; nil when `gh` failed.
    private let openIssues: @Sendable (String) async -> [QuickCaptureDraft.OpenIssue]?
    private let trackedFiles: @Sendable (String) async -> [String]
    private let directoryExists: @Sendable (String) -> Bool

    package init(
        runner: any QuickCaptureDraftRunning,
        openIssues: @escaping @Sendable (String) async -> [QuickCaptureDraft.OpenIssue]?,
        trackedFiles: @escaping @Sendable (String) async -> [String] = ProjectTermProposer.gitTrackedFiles,
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) {
        self.runner = runner
        self.openIssues = openIssues
        self.trackedFiles = trackedFiles
        self.directoryExists = directoryExists
    }

    /// - Parameter agents: in order of preference; the next is tried only
    ///   when one is not installed.
    package func draft(
        capture: String,
        route: QuickCaptureRoute.Destination,
        projects: [QuickCaptureProject],
        agents: [ProjectTermProposal.Agent]
    ) async -> QuickCaptureDraft.Outcome {
        guard case .project(let key) = route, let project = projects.first(where: { $0.key == key }) else {
            return .notRun(.catchAll)
        }
        guard key.hasPrefix("/") else { return .notRun(.remoteProject) }
        guard directoryExists(key) else { return .notRun(.checkoutMissing) }
        let issues = await openIssues(key)
        Log.backends.info(
            "Quick capture draft: \(issues.map { "\($0.count) open issues" } ?? "open issues not listed", privacy: .public)"
        )
        let prompt = QuickCaptureDraft.prompt(capture: capture, projectName: project.name, issues: issues)
        let numbers = issues?.map(\.number) ?? []
        var last: QuickCaptureDraft.Outcome = .failed(.agentNotFound)
        for agent in agents {
            let files = agent == .vibe ? await trackedFiles(key) : []
            let invocation = QuickCaptureDraft.invocation(
                agent: agent, workingDirectory: key, prompt: prompt, trackedFiles: files
            )
            Log.backends.info("Quick capture draft: asking \(agent.rawValue, privacy: .public)")
            last = await runner.run(invocation, openIssues: numbers)
            switch last {
            case .draft(let draft, let usage):
                Log.backends.info(
                    "Quick capture draft: \(agent.rawValue, privacy: .public) drafted, relation \(draft.relation.rawValue, privacy: .public) (\(usage?.summary ?? "usage not reported", privacy: .public))"
                )
                return last
            case .failed(.agentNotFound):
                continue
            case .failed(let failure):
                Log.backends.error(
                    "Quick capture draft: \(agent.rawValue, privacy: .public) failed: \(String(describing: failure), privacy: .public)"
                )
                return last
            case .notRun:
                return last
            }
        }
        Log.backends.error("Quick capture draft: no agent installed")
        return last
    }

    /// `gh issue list` in the checkout, as the app's user. Nil when `gh` is
    /// missing, not logged in, or the repository has no GitHub remote.
    package static func ghOpenIssues(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> @Sendable (String) async -> [QuickCaptureDraft.OpenIssue]? {
        { root in
            guard let gh = ghCandidates(environment: environment).first(where: isExecutable) else { return nil }
            guard let output = await BoundedProcess.run(
                executableURL: URL(fileURLWithPath: gh),
                arguments: QuickCaptureDraft.ghIssueListArguments,
                environment: environment,
                currentDirectory: root,
                timeoutSeconds: 20,
                maxBytes: 4_000_000,
                label: "quick capture gh issue list"
            ), !output.timedOut, !output.capped, output.exitCode == 0 else { return nil }
            return QuickCaptureDraft.parseIssueList(output.data)
        }
    }

    /// PATH first, then Homebrew's two prefixes: a GUI app's PATH is not the
    /// user's shell PATH.
    package static func ghCandidates(environment: [String: String]) -> [String] {
        var candidates: [String] = []
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") where !directory.isEmpty {
                candidates.append("\(directory)/gh")
            }
        }
        candidates.append("/opt/homebrew/bin/gh")
        candidates.append("/usr/local/bin/gh")
        return candidates
    }
}
