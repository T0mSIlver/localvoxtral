import Foundation

/// Runs one drafting invocation. The seam the drafter's tests replace.
package protocol QuickCaptureDraftRunning: Sendable {
    func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome
}

/// The real run, on #609's process plumbing: the same CLI lookup, the same
/// app-owned `VIBE_HOME` that keeps the user's hooks out, the invocation's
/// own variables on top (opencode's run config), `BoundedProcess`.
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
        guard let executable = ProjectTermProposalProcessRunner.locate(
            agent, environment: environment, isExecutable: isExecutable
        ) else {
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
        case .vibe:
            return QuickCaptureDraft.parseVibe(stdout: output.data, exitCode: output.exitCode, openIssues: openIssues)
                .reporting(VibeSessionUsage.read(home: vibeHome, output: output.data))
        case .opencode: return QuickCaptureDraft.parseOpencode(stdout: output.data, exitCode: output.exitCode, openIssues: openIssues)
        }
    }
}

/// Drafts a routed capture (#731, #918): the first draft from the polishing
/// model, then, for an issue, the check against the code by the first
/// installed agent.
package struct QuickCaptureDrafter: Sendable {
    /// Hands the first draft to its owner, and says whether the check should
    /// still run: false once the capture was filed, moved or discarded.
    package typealias FirstDraftHandler = @Sendable (QuickCaptureDraft.Outcome) async -> Bool

    /// Drafts on a remote project's host (#745): the capture, its project,
    /// the first drafter, and the first draft's handler. Returns the check,
    /// or nil when none ran.
    package typealias Remote = @Sendable (
        String, QuickCaptureProject, (any QuickCaptureFirstDrafting)?, @escaping FirstDraftHandler
    ) async -> QuickCaptureDraft.Outcome?

    private let runner: any QuickCaptureDraftRunning
    /// The open issues of a checkout at a path, in the repository its
    /// captures are filed in when known; nil when `gh` failed.
    private let openIssues: @Sendable (String, String?) async -> [QuickCaptureDraft.OpenIssue]?
    /// The first draft's context for a checkout, the repository its captures
    /// are filed in when known, and a capture; nil reads only the open issues.
    private let context: (@Sendable (String, String?, String) async -> QuickCaptureContext)?
    /// Nil when polishing has no model: the agent drafts alone, as before #918.
    private let firstDrafter: (any QuickCaptureFirstDrafting)?
    private let trackedFiles: @Sendable (String) async -> [String]
    private let directoryExists: @Sendable (String) -> Bool
    private let fileExists: @Sendable (String) -> Bool
    /// Nil leaves a remote capture undrafted.
    private let remote: Remote?
    private let usageRecorder: (any UsageRecording)?
    private let now: @Sendable () -> Date

    package init(
        runner: any QuickCaptureDraftRunning,
        openIssues: @escaping @Sendable (String, String?) async -> [QuickCaptureDraft.OpenIssue]?,
        context: (@Sendable (String, String?, String) async -> QuickCaptureContext)? = nil,
        firstDrafter: (any QuickCaptureFirstDrafting)? = nil,
        trackedFiles: @escaping @Sendable (String) async -> [String] = ProjectTermProposer.gitTrackedFiles,
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        remote: Remote? = nil,
        usageRecorder: (any UsageRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.usageRecorder = usageRecorder
        self.now = now
        self.remote = remote
        self.runner = runner
        self.openIssues = openIssues
        self.context = context
        self.firstDrafter = firstDrafter
        self.trackedFiles = trackedFiles
        self.directoryExists = directoryExists
        self.fileExists = fileExists
    }

    package var writesFirstDrafts: Bool { firstDrafter != nil }

    /// This drafter with another first drafter: the app builds it from the
    /// polishing settings at each capture.
    package func withFirstDrafter(_ firstDrafter: (any QuickCaptureFirstDrafting)?) -> QuickCaptureDrafter {
        QuickCaptureDrafter(
            runner: runner, openIssues: openIssues, context: context, firstDrafter: firstDrafter,
            trackedFiles: trackedFiles, directoryExists: directoryExists, fileExists: fileExists,
            remote: remote, usageRecorder: usageRecorder, now: now
        )
    }

    /// Both stages. `onFirstDraft` gets the first draft, or its failure;
    /// it is not called when there is no first drafter, or nothing ran.
    /// Returns the agent's run: the checked draft, its failure, or why none
    /// ran; nil when no check was due (not an issue, or `onFirstDraft` said
    /// stop).
    ///
    /// - Parameter agents: in order of preference; the next is tried only
    ///   when one is not installed.
    package func draft(
        capture: String,
        route: QuickCaptureRoute.Destination,
        projects: [QuickCaptureProject],
        agents: [ProjectTermProposal.Agent],
        onFirstDraft: @escaping FirstDraftHandler = { _ in true }
    ) async -> QuickCaptureDraft.Outcome? {
        // A capture keeps the checkout it was routed to; its project drafts
        // in the checkout it leads with now (#971).
        guard case .project(let routed) = route, let project = projects.first(where: { $0.keys.contains(routed) }) else {
            return .notRun(.catchAll)
        }
        let key = project.key
        if key.hasPrefix(ProjectRemote.keyPrefix) { return .notRun(.noCheckout) }
        guard key.hasPrefix("/") else {
            // A remote label never becomes a working directory here: the
            // host runs the agent in its own checkout.
            guard let remote else { return .notRun(.remoteProject) }
            return await remote(capture, project, firstDrafter, onFirstDraft)
        }
        guard directoryExists(key) else { return .notRun(.checkoutMissing) }
        let started = now()
        let gathered: QuickCaptureContext
        if let context {
            gathered = await context(key, project.issueRepository, capture)
        } else {
            gathered = QuickCaptureContext(openIssues: await openIssues(key, project.issueRepository))
        }
        let issues = gathered.openIssues
        Log.backends.notice(
            "Quick capture draft: context gathered in \(secondsSince(started), privacy: .public): \(Self.summary(of: gathered), privacy: .public)"
        )
        var firstDraft: QuickCaptureDraft.Draft?
        if let firstDrafter {
            let first = await firstDrafter.firstDraft(capture: capture, projectName: project.name, context: gathered)
            Self.logFirstDraft(first, seconds: secondsSince(started))
            guard await onFirstDraft(first) else { return nil }
            if case .draft(let draft, _) = first {
                guard draft.kind == .issue else { return nil }
                firstDraft = draft
            }
        }
        let prompt = QuickCaptureDraft.prompt(
            capture: capture, projectName: project.name, issues: issues, firstDraft: firstDraft
        )
        let numbers = issues?.map(\.number) ?? []
        var last: QuickCaptureDraft.Outcome = .failed(.agentNotFound)
        for agent in agents {
            let files = agent == .vibe ? await trackedFiles(key) : []
            let invocation = QuickCaptureDraft.invocation(
                agent: agent, workingDirectory: key, prompt: prompt, trackedFiles: files
            )
            let checkStarted = now()
            Log.backends.notice(
                "Quick capture draft: asking \(agent.rawValue, privacy: .public) to \(firstDraft == nil ? "draft" : "check the first draft", privacy: .public)"
            )
            last = await runner.run(invocation, openIssues: numbers)
            QuickCaptureDraft.recordUsage(of: last, agent: agent, date: now(), to: usageRecorder)
            switch last {
            case .draft(let draft, let usage):
                // Only files that exist in the checkout count as read.
                let read = draft.filesRead?.filter { fileExists((key as NSString).appendingPathComponent($0)) }
                last = .draft(draft.keepingFiles(read, agent: agent), usage: usage)
                Log.backends.notice(
                    "Quick capture draft: \(agent.rawValue, privacy: .public) \(firstDraft == nil ? "drafted" : "checked", privacy: .public) in \(secondsSince(checkStarted), privacy: .public), \(read?.count ?? 0, privacy: .public) files read, relation \(draft.relation.rawValue, privacy: .public) (\(usage?.summary ?? "usage not reported", privacy: .public))"
                )
                return last
            case .failed(.agentNotFound):
                Log.backends.notice("Quick capture draft: \(agent.rawValue, privacy: .public) not installed")
                continue
            case .failed(let failure):
                Log.backends.error(
                    "Quick capture draft: \(agent.rawValue, privacy: .public) failed after \(secondsSince(checkStarted), privacy: .public): \(String(describing: failure), privacy: .public)"
                )
                return last
            case .notRun:
                return last
            }
        }
        Log.backends.error("Quick capture draft: no agent installed")
        return last
    }

    /// For the log: counts only, never the text.
    static func summary(of context: QuickCaptureContext) -> String {
        [
            "readme \(context.readme == nil ? "no" : "yes")",
            "guide rules \(context.issueRules == nil ? "no" : "yes")",
            "\(context.codeHits.count) search hits",
            context.openIssues.map { "\($0.count) open issues" } ?? "open issues not listed",
            context.closedIssues.map { "\($0.count) closed" } ?? "closed not listed",
            context.mergedPullRequests.map { "\($0.count) merged PRs" } ?? "merged PRs not listed",
        ].joined(separator: ", ")
    }

    package static func logFirstDraft(_ outcome: QuickCaptureDraft.Outcome, seconds: String) {
        switch outcome {
        case .draft(let draft, let usage):
            Log.backends.notice(
                "Quick capture first draft: \(draft.kind.rawValue, privacy: .public) in \(seconds, privacy: .public), relation \(draft.relation.rawValue, privacy: .public) (\(usage?.summary ?? "usage not reported", privacy: .public))"
            )
        case .failed(let failure):
            Log.backends.error(
                "Quick capture first draft: failed after \(seconds, privacy: .public): \(String(describing: failure), privacy: .public)"
            )
        case .notRun(let reason):
            Log.backends.notice("Quick capture first draft: not run, \(reason.rawValue, privacy: .public)")
        }
    }

    private func secondsSince(_ date: Date) -> String { Self.seconds(since: date, now: now()) }

    static func seconds(since date: Date, now: Date) -> String {
        String(format: "%.1f s", now.timeIntervalSince(date))
    }

    /// `gh issue list` of the repository the project files in, else of the
    /// checkout's (`QuickCaptureFiling`'s pick), as the app's user. Nil when
    /// `gh` is missing, not logged in, or the checkout has no GitHub
    /// repository.
    package static func ghOpenIssues(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> @Sendable (String, String?) async -> [QuickCaptureDraft.OpenIssue]? {
        { root, known in
            guard let gh = ghCandidates(environment: environment).first(where: isExecutable) else { return nil }
            var repository = known.flatMap { QuickCaptureInbox.isRepository($0) ? $0 : nil }
            if repository == nil {
                repository = await QuickCaptureFiling.repository(
                    ofCheckout: root, environment: environment, isExecutable: isExecutable
                )
            }
            guard let repository else { return nil }
            guard let output = await BoundedProcess.run(
                executableURL: URL(fileURLWithPath: gh),
                arguments: QuickCaptureDraft.ghIssueListArguments(repository: repository),
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
