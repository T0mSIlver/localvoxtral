import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// What one stop-commit sent to the polish model and wrote to the session
/// record, pinned byte for byte.
///
/// `finishStoppedSession` is the one place every polish context source, both
/// prompt profiles, the clipboard macro and the three backend configurations
/// meet. #432 moves that code into types of its own, and the e2e dictation
/// check runs with polishing off, so these fixtures are what proves a move
/// changed nothing on the polish path: a refactor PR must leave every file
/// under `Fixtures/PolishRequestGoldens` untouched.
///
/// A missing fixture is recorded, printed between `POLISH GOLDEN BEGIN/END`
/// lines (the build host cannot send files back, so the log is the channel)
/// and reported as a failure until it is committed. To re-record a case on
/// purpose, delete its file; a mismatch never rewrites one.
@MainActor
final class PolishRequestGoldenTests: XCTestCase {
    // MARK: - Fixture shape

    struct Golden: Codable, Equatable {
        struct Configuration: Codable, Equatable {
            var endpointURL: String
            /// Length only: the fixture is committed, the key never is.
            var apiKeyLength: Int
            var model: String
            var requestShape: String
            var samplingTemperature: Double?
            var samplingTopP: Double?
            var samplingTopK: Int?
            var samplingMinP: Double?
            var samplingPresencePenalty: Double?
            var chatTemplateArguments: [String: Bool]?
            var thinkingBudgetTokens: Int?
            var passthroughExtraParameters: Bool
            var mistralReasoningEffort: String?
        }

        struct Request: Codable, Equatable {
            var inputText: String
            var systemPrompt: String
            var userPrompts: [String]
            var maxTokens: Int?
            var timeoutSeconds: Double?
            var prefersDeepReasoning: Bool
        }

        struct Record: Codable, Equatable {
            var rawText: String
            var polishedText: String?
            var polishingDurationSeconds: Double?
            var provider: String
            var model: String
            var outputMode: String
            var targetAppBundleID: String?
            var status: String
            var commitSucceeded: Bool
            var polishProfile: String?
            var polishContextSummary: String?
        }

        /// Nil when no request reached the service (configuration missing).
        var configuration: Configuration?
        var request: Request?
        var record: Record?
        /// `currentDictationEventText` after the commit: what the overlay
        /// inserted, payload substituted.
        var committedText: String
        var statusText: String
        var lastError: String?
        /// How often the clipboard was read, for context or for the payload
        /// macro. Zero is the privacy guarantee two of the cases exist for.
        var pasteboardReads: Int
        /// How often the repo vocabulary pipeline ran (the seam call count).
        var repoVocabularyPipelineRuns: Int
        /// The terms the learned-term store holds for the project the commit
        /// resolved to, at any dictation count: what this commit recorded, plus
        /// what the case seeded.
        var learnedTermsRecorded: [String]
    }

    // MARK: - Scenario

    /// Everything a case may vary. Defaults are the standard profile against
    /// an external loopback endpoint with every context source off.
    struct Scenario {
        var transcript = "please fix local vox trawl before the release"
        var backendMode: BackendMode = .externalURL
        /// Loopback, so the context gates pass, but not the managed polishd
        /// pin (port 8472): a managed configuration must differ from an
        /// external one by more than a catalog field.
        var endpointURL = "http://127.0.0.1:8080/v1/chat/completions"
        var externalModel = "qwen35-4b"
        var mistralAPIKey = ""
        var agentProfileEnabled = false
        var targetBundleID: String? = "com.acme.notes"
        var speakerProfile = ""
        var speakerTerms: [String] = []
        var replacementDictionaryEnabled = true
        var clipboardContextEnabled = false
        var trustedEndpointEnabled = false
        /// What the clipboard holds; the context reader and the payload
        /// macro read the same one.
        var clipboardText: String? = nil
        var payloadMacroEnabled = false
        var terminalScreenContextEnabled = false
        var screenCapture: TerminalScreenCapture? = nil
        var rawScreenAttachmentAuthorized = false
        var repoVocabularyEnabled = false
        var repoVocabularyOutcome: RepoVocabularyMatcher.GroundingOutcome? = nil
        var repoVocabularyRoot: String? = nil
        var claudeRepoContextEnabled = false
        var claudeJoin: ClaudeJoinScenario? = nil
        var learnedTerms: [String] = []
        var standardUserTemplate =
            "Clean this up.\n{{replacement_dictionary}}\nWorking text:\n{{input_text}}"
        var agentUserTemplate =
            "Fix only recognition errors.\n{{replacement_dictionary}}\nWorking text:\n{{input_text}}"
        var polishReply: @Sendable (LLMPolishingRequest) throws -> String = { $0.inputText }
    }

    enum ClaudeJoinScenario {
        /// A tty-resolved local session at `/repo` with a prior prompt and one
        /// edited file; the fake collector answers with `repoSnapshot`.
        case local(repoSnapshot: ClaudeRepoSnapshot?)
        /// A remote session with a prior prompt and a tool-output excerpt. No
        /// local workspace, so the collector is never reached.
        case remote
    }

    private let ghostty = TerminalScreenTarget(
        pid: 4242,
        bundleID: TerminalScreenAllowlist.ghosttyBundleID
    )
    private static let surfaceTTY = "/dev/ttys003"

    override func tearDown() async throws {
        TerminalScreenAXReader.debugScreenReadOverride = nil
        TerminalScreenAXReader.debugScreenWindowIDOverride = nil
        TerminalScreenContextSource.debugFrontmostTargetOverride = nil
        TerminalScreenContextSource.debugTargetForPIDOverride = nil
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = nil
        TerminalScreenRawAttachmentPolicy.configure(authorizer: nil)
        try await super.tearDown()
    }

    // MARK: - The cases

    func testBaselineStandardProfileWithADictionaryHit() async throws {
        try await assertGolden("01-baseline", Scenario())
    }

    func testAgentProfileForATerminalTarget() async throws {
        var scenario = Scenario()
        scenario.transcript = "run the tests and fix the auth module"
        scenario.agentProfileEnabled = true
        scenario.targetBundleID = "com.apple.Terminal"
        try await assertGolden("02-agent-profile", scenario)
    }

    func testSpeakerProfileAndTermsReachTheSystemPrompt() async throws {
        var scenario = Scenario()
        // "SwiftPM" has a distinctive shape, so it also becomes a casing rule
        // applied before the request; "Voxtral" and "herdr" ride only in the
        // About-you block.
        scenario.transcript = "stream voxtral through swiftpm into herdr and commit"
        scenario.speakerProfile = "Tom, a Swift developer working on a macOS dictation app."
        scenario.speakerTerms = ["Voxtral", "SwiftPM", "herdr"]
        try await assertGolden("03-speaker-profile", scenario)
    }

    func testReplacementDictionaryOffStillCasesSpeakerTerms() async throws {
        var scenario = Scenario()
        scenario.transcript = "local vox trawl builds with swiftpm"
        scenario.replacementDictionaryEnabled = false
        scenario.speakerTerms = ["SwiftPM"]
        try await assertGolden("04-dictionary-off-terms-cased", scenario)
    }

    func testClipboardContextOnLoopbackAttachesTheBlock() async throws {
        var scenario = Scenario()
        scenario.transcript = "fix the user session manager refresh token path"
        scenario.clipboardContextEnabled = true
        scenario.clipboardText =
            "UserSessionManager.swift handles the refresh token"
        try await assertGolden("05-clipboard-context-loopback", scenario)
    }

    func testClipboardVocabularyGroundsTheTranscript() async throws {
        var scenario = Scenario()
        scenario.transcript = "open use auth dot ts and fix the import"
        scenario.targetBundleID = "com.apple.Terminal"
        scenario.clipboardContextEnabled = true
        scenario.clipboardText = "see use_auth.ts for the hook"
        try await assertGolden("05b-clipboard-vocabulary-grounded", scenario)
    }

    func testClipboardContextOnRemoteEndpointReadsNothing() async throws {
        var scenario = Scenario()
        scenario.transcript = "fix the user session manager refresh token path"
        scenario.endpointURL = "https://api.example.com/v1/chat/completions"
        scenario.clipboardContextEnabled = true
        scenario.clipboardText =
            "UserSessionManager.swift handles the refresh token"
        try await assertGolden("06-clipboard-context-remote-untrusted", scenario)
    }

    func testClipboardPayloadMacroKeepsThePlaceholderOutOfTheCommit() async throws {
        var scenario = Scenario()
        scenario.transcript = "here is the error paste clipboard end"
        scenario.payloadMacroEnabled = true
        scenario.clipboardText =
            "Traceback (most recent call last):\n  File \"app.py\", line 42\nValueError: boom"
        try await assertGolden("07-clipboard-payload-macro", scenario)
    }

    func testTerminalScreenRendersWithAPositiveLocalJoin() async throws {
        var scenario = Scenario()
        scenario.transcript = "rerun the polish token guard tests"
        scenario.targetBundleID = TerminalScreenAllowlist.ghosttyBundleID
        scenario.terminalScreenContextEnabled = true
        scenario.screenCapture = sampleScreenCapture
        scenario.rawScreenAttachmentAuthorized = true
        scenario.claudeJoin = .local(repoSnapshot: nil)
        try await assertGolden("08-terminal-screen-render", scenario)
    }

    func testTerminalScreenWithoutAJoinGroundsVocabularyOnly() async throws {
        var scenario = Scenario()
        scenario.transcript = "rerun the polish token guard tests"
        scenario.targetBundleID = TerminalScreenAllowlist.ghosttyBundleID
        scenario.terminalScreenContextEnabled = true
        scenario.screenCapture = sampleScreenCapture
        try await assertGolden("09-terminal-screen-vocabulary-only", scenario)
    }

    func testRepoVocabularyPreAppliesAndNominatesForVerification() async throws {
        var scenario = Scenario()
        scenario.transcript = "open use auth dot t s and ask the session broker"
        scenario.targetBundleID = "com.apple.Terminal"
        scenario.repoVocabularyEnabled = true
        scenario.repoVocabularyOutcome = RepoVocabularyMatcher.GroundingOutcome(
            entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth dot t s"])],
            isFallbackOnly: false,
            verificationCandidates: [
                ReplacementEntry(replaceWith: "SessionBroker", matches: ["session broker"]),
            ]
        )
        scenario.repoVocabularyRoot = "/Users/t/work/localvoxtral"
        try await assertGolden("10-repo-vocabulary", scenario)
    }

    func testClaudeLocalJoinAttachesTheRepositoryBlock() async throws {
        var scenario = Scenario()
        scenario.transcript = "make the token refresher retry twice"
        scenario.targetBundleID = TerminalScreenAllowlist.ghosttyBundleID
        scenario.claudeRepoContextEnabled = true
        scenario.claudeJoin = .local(repoSnapshot: sampleRepoSnapshot)
        try await assertGolden("11-claude-local-join-repo-block", scenario)
    }

    func testClaudeRemoteJoinAttachesSessionTextWithoutARepoBlock() async throws {
        var scenario = Scenario()
        scenario.transcript = "rerun the unit suite on the dev box"
        scenario.targetBundleID = TerminalScreenAllowlist.ghosttyBundleID
        scenario.claudeRepoContextEnabled = true
        scenario.claudeJoin = .remote
        try await assertGolden("12-claude-remote-join-session-text", scenario)
    }

    func testLearnedTermsGroundALaterDictation() async throws {
        var scenario = Scenario()
        scenario.transcript = "open useauth.ts please"
        scenario.targetBundleID = "com.apple.Terminal"
        scenario.repoVocabularyEnabled = true
        scenario.learnedTerms = ["useAuth.ts"]
        try await assertGolden("13-learned-terms", scenario)
    }

    func testConflictingSourcesAbstain() async throws {
        var scenario = Scenario()
        scenario.transcript = "open use auth dot ts and fix the import"
        scenario.targetBundleID = "com.apple.Terminal"
        scenario.repoVocabularyEnabled = true
        scenario.repoVocabularyOutcome = RepoVocabularyMatcher.GroundingOutcome(
            entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth dot ts"])],
            isFallbackOnly: false
        )
        scenario.clipboardContextEnabled = true
        scenario.clipboardText = "see use_auth.ts for the hook"
        try await assertGolden("14-conflict-abstains", scenario)
    }

    func testTemplateWithoutTheDictionarySlotSkipsThePipeline() async throws {
        var scenario = Scenario()
        scenario.transcript = "open use auth dot t s and fix the import"
        scenario.targetBundleID = "com.apple.Terminal"
        scenario.repoVocabularyEnabled = true
        scenario.repoVocabularyOutcome = RepoVocabularyMatcher.GroundingOutcome(
            entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth dot t s"])],
            isFallbackOnly: false
        )
        scenario.standardUserTemplate = "Clean this up.\n{{input_text}}"
        scenario.agentUserTemplate = "Fix only recognition errors.\n{{input_text}}"
        try await assertGolden("15-template-without-dictionary-slot", scenario)
    }

    func testManagedConfiguration() async throws {
        var scenario = Scenario()
        scenario.backendMode = .managedLocal
        try await assertGolden("16a-configuration-managed", scenario)
    }

    func testExternalURLConfiguration() async throws {
        var scenario = Scenario()
        scenario.backendMode = .externalURL
        scenario.endpointURL = "http://192.168.1.183:8080/v1/chat/completions"
        try await assertGolden("16b-configuration-external-url", scenario)
    }

    func testMistralAPIConfiguration() async throws {
        var scenario = Scenario()
        scenario.backendMode = .mistralAPI
        scenario.mistralAPIKey = "golden-test-key"
        try await assertGolden("16c-configuration-mistral-api", scenario)
    }

    func testPolishFailureNetworkError() async throws {
        var scenario = Scenario()
        scenario.polishReply = { _ in throw LLMPolishingError.networkError("The request timed out.") }
        try await assertGolden("17a-failure-network-error", scenario)
    }

    func testPolishFailureRequestRejected() async throws {
        var scenario = Scenario()
        scenario.polishReply = { _ in
            throw LLMPolishingError.requestFailed(
                statusCode: 401,
                body: #"{"object":"error","message":"Unauthorized","type":"invalid_request_error","code":"1100"}"#
            )
        }
        try await assertGolden("17b-failure-request-rejected", scenario)
    }

    func testPolishFailureTimedOut() async throws {
        var scenario = Scenario()
        scenario.polishReply = { _ in throw LLMPolishingError.timedOut(afterSeconds: 40) }
        try await assertGolden("17c-failure-timed-out", scenario)
    }

    func testPolishFailureEmptyInput() async throws {
        var scenario = Scenario()
        scenario.polishReply = { _ in throw LLMPolishingError.emptyInput }
        try await assertGolden("17d-failure-empty-input", scenario)
    }

    func testPolishFailureInvalidResponse() async throws {
        var scenario = Scenario()
        scenario.polishReply = { _ in throw LLMPolishingError.invalidResponse }
        try await assertGolden("17e-failure-invalid-response", scenario)
    }

    // MARK: - Sample material

    private var sampleScreenCapture: TerminalScreenCapture {
        TerminalScreenCapture(
            text: "$ swift test --filter PolishTokenGuardTests\nTest Suite 'PolishTokenGuardTests' passed",
            target: ghostty,
            windowID: 101
        )
    }

    private var sampleRepoSnapshot: ClaudeRepoSnapshot {
        var snapshot = ClaudeRepoSnapshot.empty
        snapshot.workspaceName = "repo"
        snapshot.branch = "main"
        snapshot.statusLines = [" M Sources/TokenRefresher.swift"]
        snapshot.activeFiles = [
            ClaudeRepoSnapshot.File(
                path: "Sources/TokenRefresher.swift",
                contents: "struct TokenRefresher {\n    func refresh() async throws {}\n}\n",
                touch: .edited,
                isTruncated: false
            ),
        ]
        snapshot.trackedPaths = ["Sources/TokenRefresher.swift", "Sources/SessionBroker.swift"]
        return snapshot
    }

    // MARK: - Harness

    private func runScenario(_ scenario: Scenario) async throws -> Golden {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = scenario.backendMode
        settings.llmPolishingEndpointURL = scenario.endpointURL
        settings.llmPolishingModel = scenario.externalModel
        settings.mistralAPIKey = scenario.mistralAPIKey
        settings.agentPolishProfileEnabled = scenario.agentProfileEnabled
        settings.polishSpeakerProfile = scenario.speakerProfile
        settings.polishSpeakerTerms = scenario.speakerTerms
        settings.replacementDictionaryEnabled = scenario.replacementDictionaryEnabled
        settings.polishClipboardContextEnabled = scenario.clipboardContextEnabled
        settings.polishContextTrustedEndpointEnabled = scenario.trustedEndpointEnabled
        settings.clipboardPayloadMacroEnabled = scenario.payloadMacroEnabled
        settings.terminalScreenContextEnabled = scenario.terminalScreenContextEnabled
        settings.repoVocabularyEnabled = scenario.repoVocabularyEnabled
        settings.claudeRepoContextEnabled = scenario.claudeRepoContextEnabled

        let service = FakePolishingService(reply: scenario.polishReply)
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "localvoxtral", matches: ["local vox trawl"]),
            ]),
            promptTemplates: LLMPromptTemplates(
                systemContent: "You polish dictated text.",
                userContent: scenario.standardUserTemplate
            ),
            agentPromptTemplates: LLMPromptTemplates(
                systemContent: "You polish dictation for a coding agent.",
                userContent: scenario.agentUserTemplate
            )
        )
        viewModel.llmPolishingService = service
        viewModel.stubCommitTarget { scenario.targetBundleID }
        // The failure cases present a real modal alert when NSApp exists; the
        // flag makes the presenter a no-op (AGENTS.md). `lastError` is set
        // before that gate.
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        let pasteboard = PasteboardStub(string: scenario.clipboardText)
        viewModel.dependencies.pasteboardReader = { pasteboard }

        final class Counter { var runs = 0 }
        let pipelineRuns = Counter()
        let repoOutcome = scenario.repoVocabularyOutcome
        viewModel.debugRepoVocabularyEntriesOverride = { _ in
            pipelineRuns.runs += 1
            return repoOutcome
        }
        viewModel.debugRepoVocabularyRootOverride = scenario.repoVocabularyRoot

        if let capture = scenario.screenCapture {
            viewModel.terminalScreenStartCapture = capture
            let target = capture.target
            let text = capture.text
            let windowID = capture.windowID
            TerminalScreenContextSource.debugTargetForPIDOverride = { _ in target }
            TerminalScreenAXReader.debugScreenReadOverride = { _ in text }
            TerminalScreenAXReader.debugScreenWindowIDOverride = { _ in windowID }
        }
        let authorized = scenario.rawScreenAttachmentAuthorized
        TerminalScreenRawAttachmentPolicy.debugAuthorizationOverride = { _, _ in authorized }

        if let joinScenario = scenario.claudeJoin {
            try await installClaudeJoin(joinScenario, on: viewModel)
        }

        let store = LearnedTermStore(fileURL: nil)
        viewModel.learnedTermStore = store
        for term in scenario.learnedTerms {
            for _ in 0..<LearnedTerms.confirmedDictations {
                store.record(
                    [LearnedTermObservation(term: term, source: .repository)],
                    project: LearnedTermProjectResolver.shared
                )
            }
        }
        store.waitForPendingWrites()

        var savedRecord: DictationSessionRecord?
        viewModel.debugSavedSessionRecordSink = { savedRecord = $0 }
        // Read before the commit consumes the join.
        let joinWorkspace = viewModel.claudeSessionJoin?.snapshot.workspace

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = scenario.transcript

        viewModel.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(viewModel)
        store.waitForPendingWrites()

        let request = await service.lastRequest
        let configuration = await service.lastConfiguration
        // The commit's root box is reported only by the vocabulary pipeline:
        // when the seam ran, its root (nil meaning no repository); otherwise
        // the box stays unknown.
        let repositoryRoot: LearnedTermProjectResolver.RepositoryRoot =
            pipelineRuns.runs > 0
            ? scenario.repoVocabularyRoot.map { .root($0) } ?? .noRepository
            : .unknown
        let learnedProject = LearnedTermProjectResolver.resolve(
            repositoryRoot: repositoryRoot,
            workspace: joinWorkspace
        )
        let learnedTerms = learnedProject.map {
            store.snapshot().confirmed(projectKey: $0.key, minimumDictations: 1)
                .map(\.term).sorted()
        } ?? []

        return Golden(
            configuration: configuration.map(Golden.Configuration.init),
            request: request.map(Golden.Request.init),
            record: savedRecord.map(Golden.Record.init),
            committedText: viewModel.currentDictationEventText,
            statusText: viewModel.statusText,
            lastError: viewModel.lastError,
            pasteboardReads: pasteboard.stringCallCount,
            repoVocabularyPipelineRuns: pipelineRuns.runs,
            learnedTermsRecorded: learnedTerms
        )
    }

    /// Seeds a registry with one session and hands the view model a join to
    /// it, the way `beginDictationSession` would have left one. The resolver
    /// stays installed so the commit's `isStillLive` re-check passes.
    private func installClaudeJoin(
        _ joinScenario: ClaudeJoinScenario,
        on viewModel: DictationViewModel
    ) async throws {
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in true }
        )
        switch joinScenario {
        case .local(let repoSnapshot):
            let origin = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
            let process = ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001, tty: Self.surfaceTTY)
            registry.ingest(
                ClaudeHookRecord(
                    event: .sessionStart, sessionID: "s1", timestamp: 0,
                    rawCwd: "/repo", process: process
                ),
                origin: origin
            )
            registry.ingest(
                ClaudeHookRecord(
                    event: .userPromptSubmit, sessionID: "s1", timestamp: 1,
                    rawCwd: "/repo", prompt: "add a retry to the token refresh", process: process
                ),
                origin: origin
            )
            registry.ingest(
                ClaudeHookRecord(
                    event: .postToolUse, sessionID: "s1", timestamp: 2,
                    rawCwd: "/repo", toolName: "Edit",
                    files: [ClaudeFileTouch(path: "/repo/Sources/TokenRefresher.swift", kind: .edited)],
                    process: process
                ),
                origin: origin
            )
            let resolver = ClaudeSessionJoinResolver(
                registry: registry,
                focusedTerminalTTY: { _ in Self.surfaceTTY },
                focusedWindowID: { _ in 101 }
            )
            viewModel.claudeSessionJoinResolver = resolver
            viewModel.claudeRepoCollector = StubClaudeRepoCollector(snapshot: repoSnapshot)
            let join = await resolver.resolve(target: ghostty)
            XCTAssertNotNil(join, "the local tty arm must resolve the seeded session")
            viewModel.claudeSessionJoin = join
        case .remote:
            let origin = ClaudeTransportOrigin.remote(channel: "ssh:devbox")
            registry.ingest(
                ClaudeHookRecord(
                    event: .sessionStart, sessionID: "r1", timestamp: 0,
                    rawCwd: "/home/dev/work/localvoxtral"
                ),
                origin: origin
            )
            registry.ingest(
                ClaudeHookRecord(
                    event: .userPromptSubmit, sessionID: "r1", timestamp: 1,
                    rawCwd: "/home/dev/work/localvoxtral", prompt: "run the unit suite"
                ),
                origin: origin
            )
            registry.ingest(
                ClaudeHookRecord(
                    event: .postToolUse, sessionID: "r1", timestamp: 2,
                    rawCwd: "/home/dev/work/localvoxtral", toolName: "Bash",
                    files: [ClaudeFileTouch(path: "/home/dev/work/localvoxtral/Package.swift", kind: .read)]
                ),
                origin: origin,
                snippets: [
                    ClaudeContentSnippet(
                        label: "Bash",
                        kind: .toolOutput,
                        text: "Test Suite 'All tests' passed at 2026-09-22 10:00:00."
                    ),
                ]
            )
            let snapshot = try XCTUnwrap(registry.snapshot(sessionID: "r1"))
            viewModel.claudeSessionJoinResolver = ClaudeSessionJoinResolver(registry: registry)
            viewModel.claudeSessionJoin = ClaudeSessionJoin(
                target: ghostty,
                snapshot: snapshot,
                windowID: 101,
                mechanism: .remoteSSHConnection
            )
        }
    }

    // MARK: - Golden comparison

    private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/PolishRequestGoldens", isDirectory: true)

    private func assertGolden(
        _ name: String,
        _ scenario: Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let golden = try await runScenario(scenario)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let actual = String(decoding: try encoder.encode(golden), as: UTF8.self) + "\n"
        let fixtureURL = Self.fixtureDirectory.appendingPathComponent("\(name).json")

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            try FileManager.default.createDirectory(
                at: Self.fixtureDirectory, withIntermediateDirectories: true
            )
            try actual.write(to: fixtureURL, atomically: true, encoding: .utf8)
            printForRecovery(name: name, contents: actual)
            XCTFail(
                "no fixture for \(name): recorded \(fixtureURL.lastPathComponent); commit it after checking it",
                file: file, line: line
            )
            return
        }
        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        guard expected != actual else { return }

        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        let firstDifference = zip(expectedLines, actualLines).enumerated()
            .first { $0.element.0 != $0.element.1 }?.offset
            ?? min(expectedLines.count, actualLines.count)
        let expectedLine = expectedLines.indices.contains(firstDifference)
            ? expectedLines[firstDifference] : "<end of fixture>"
        let actualLine = actualLines.indices.contains(firstDifference)
            ? actualLines[firstDifference] : "<end of output>"
        printForRecovery(name: name, contents: actual)
        XCTFail(
            """
            \(name) no longer matches its fixture at line \(firstDifference + 1):
              fixture: \(expectedLine)
              actual:  \(actualLine)
            A refactor must not change what reaches the model. If the change is intended, delete the fixture and re-run to record it.
            """,
            file: file, line: line
        )
    }

    /// Flushed on both sides: XCTest reports the failure on unbuffered
    /// stderr, and with the two streams merged into one log a pending stdout
    /// buffer would otherwise carry the failure text in the middle of a line.
    private func printForRecovery(name: String, contents: String) {
        fflush(stdout)
        print("===== POLISH GOLDEN BEGIN \(name) =====")
        print(contents, terminator: "")
        print("===== POLISH GOLDEN END \(name) =====")
        fflush(stdout)
    }
}

// MARK: - Golden projections

extension PolishRequestGoldenTests.Golden.Configuration {
    init(_ configuration: LLMPolishingConfiguration) {
        endpointURL = configuration.endpointURL.absoluteString
        apiKeyLength = configuration.apiKey.count
        model = configuration.model
        requestShape = configuration.requestShape.rawValue
        samplingTemperature = configuration.samplingDefaults?.temperature
        samplingTopP = configuration.samplingDefaults?.topP
        samplingTopK = configuration.samplingDefaults?.topK
        samplingMinP = configuration.samplingDefaults?.minP
        samplingPresencePenalty = configuration.samplingDefaults?.presencePenalty
        chatTemplateArguments = configuration.chatTemplateArguments
        thinkingBudgetTokens = configuration.thinkingBudgetTokens
        passthroughExtraParameters = configuration.passthroughExtraParameters
        mistralReasoningEffort = configuration.mistralReasoningEffort?.rawValue
    }
}

extension PolishRequestGoldenTests.Golden.Request {
    init(_ request: LLMPolishingRequest) {
        inputText = request.inputText
        systemPrompt = request.systemPrompt
        userPrompts = request.userPrompts
        maxTokens = request.maxTokens
        timeoutSeconds = request.timeoutSeconds
        prefersDeepReasoning = request.prefersDeepReasoning
    }
}

extension PolishRequestGoldenTests.Golden.Record {
    @MainActor
    init(_ record: DictationSessionRecord) {
        rawText = record.rawText
        polishedText = record.polishedText
        polishingDurationSeconds = record.polishingDurationSeconds
        provider = record.provider
        model = record.model
        outputMode = record.outputMode
        targetAppBundleID = record.targetAppBundleID
        status = record.status
        commitSucceeded = record.commitSucceeded
        polishProfile = record.polishProfile
        polishContextSummary = record.polishContextSummary
    }
}
