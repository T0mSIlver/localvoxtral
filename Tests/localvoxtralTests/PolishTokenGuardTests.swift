import Foundation
import XCTest
@testable import localvoxtral

final class PolishTokenGuardTests: XCTestCase {
    // MARK: - Recognizer

    func testProtectedTokensRecognizesEachClass() {
        let cases: [(input: String, expected: [String])] = [
            // Backtick span (backticks included, no nesting).
            ("run `git status` please", ["`git status`"]),
            // URL with trailing sentence punctuation trimmed.
            ("see https://example.com/docs, ok", ["https://example.com/docs"]),
            // Path with slashes; the inner filename span is suppressed.
            ("edit src/auth/useAuth.ts now", ["src/auth/useAuth.ts"]),
            ("run ./scripts/foo.sh here", ["./scripts/foo.sh"]),
            ("cat ~/Library/Prefs done", ["~/Library/Prefs"]),
            // Absolute path keeps its leading slash.
            ("tail /tmp/app.log now", ["/tmp/app.log"]),
            // The `/host/path` sub-span inside a URL is dropped by containment:
            // the URL alone is the protected token.
            ("read https://api.example.com/v1/users for details", ["https://api.example.com/v1/users"]),
            // Standalone dotted filename.
            ("open README.md now", ["README.md"]),
            // CLI flags.
            ("use --force here", ["--force"]),
            ("pass --opt=value ok", ["--opt=value"]),
            ("add -f flag", ["-f"]),
            // Sentence punctuation after an =value tail is trimmed, not swallowed.
            ("run with --mode=fast.", ["--mode=fast"]),
            // Environment variable.
            ("echo $HOME now", ["$HOME"]),
            ("set $PATH_VAR too", ["$PATH_VAR"]),
            // Hex hash (has a digit).
            ("commit a1b2c3d done", ["a1b2c3d"]),
            // Version literals.
            ("bump 1.2.3 today", ["1.2.3"]),
            ("tag v2.5 now", ["v2.5"]),
            // Ordering follows first appearance; inner filename suppressed.
            ("run --force on src/app.ts", ["--force", "src/app.ts"]),
        ]

        for testCase in cases {
            XCTAssertEqual(
                PolishTokenGuard.protectedTokens(in: testCase.input),
                testCase.expected,
                "input: \(testCase.input)"
            )
        }
    }

    func testProtectedTokensRejectsNonTokens() {
        let negatives = [
            "well-known issue and a follow-up",       // hyphenated prose, not a flag
            "that is the end of file.",               // sentence-ending period, no ext
            "pi is roughly 3.14 approx",              // pure decimal, not a version/filename
            "we shipped 2.5 times faster",            // two-component prose number
            "c'est l'idée qu'on a partagée",          // French apostrophes
            "the decade faded fast",                  // all-letter word, not a hex hash
            "use e.g. the second option",             // abbreviation, not a filename
            "It works.Then we ship",                  // missing space the polish must be free to fix
            "open README.MD now",                     // uppercase ext: accepted recognition loss
        ]

        for input in negatives {
            XCTAssertEqual(
                PolishTokenGuard.protectedTokens(in: input),
                [],
                "input should have no protected tokens: \(input)"
            )
        }
    }

    // MARK: - verifyAndRepair

    func testVerifyAndRepairCleanPassThrough() {
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "Use --force.",
            original: "use --force"
        )
        XCTAssertEqual(result.outcome, .clean)
        XCTAssertEqual(result.text, "Use --force.")
    }

    func testVerifyAndRepairWithNoTokensIsClean() {
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "Hello world.",
            original: "hello world"
        )
        XCTAssertEqual(result.outcome, .clean)
        XCTAssertEqual(result.text, "Hello world.")
    }

    func testVerifyAndRepairRepairsCaseMangledPath() {
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "Open src/auth/useauth.ts.",
            original: "open src/Auth/useAuth.ts"
        )
        XCTAssertEqual(result.outcome, .repaired(count: 1))
        XCTAssertEqual(result.text, "Open src/Auth/useAuth.ts.")
    }

    func testVerifyAndRepairRepairsEnDashMangledFlag() {
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "run \u{2013} force",
            original: "run --force"
        )
        XCTAssertEqual(result.outcome, .repaired(count: 1))
        XCTAssertEqual(result.text, "run --force")
    }

    func testVerifyAndRepairFallsBackWhenTokenDeleted() {
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "run now",
            original: "run --force now"
        )
        XCTAssertEqual(result.outcome, .fallback(missing: ["--force"]))
        XCTAssertEqual(result.text, "run --force now")
    }

    func testVerifyAndRepairRepairsMultipleTokens() {
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "run \u{2013} force on src/app.ts",
            original: "run --force on src/App.ts"
        )
        XCTAssertEqual(result.outcome, .repaired(count: 2))
        XCTAssertEqual(result.text, "run --force on src/App.ts")
    }

    func testVerifyAndRepairDiscardsPartialRepairsWhenAnyTokenMissing() {
        // The flag is repairable (en dash), but the path is gone entirely: the
        // whole polish is discarded, partial repairs and all.
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "run \u{2013} force on the file",
            original: "run --force on src/App.ts"
        )
        XCTAssertEqual(result.outcome, .fallback(missing: ["src/App.ts"]))
        XCTAssertEqual(result.text, "run --force on src/App.ts")
    }

    func testVerifyAndRepairFlagWithAppendedCharsIsNotPreserved() {
        // "--forceful" contains "--force" but with a body char appended: that
        // is corruption, not survival, and it is not a repairable near-miss
        // either — the polish must be discarded.
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "run --forceful now",
            original: "run --force now"
        )
        XCTAssertEqual(result.outcome, .fallback(missing: ["--force"]))
        XCTAssertEqual(result.text, "run --force now")
    }

    func testVerifyAndRepairPathWithAppendedExtensionCharIsNotPreserved() {
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "open src/App.tsx",
            original: "open src/App.ts"
        )
        XCTAssertEqual(result.outcome, .fallback(missing: ["src/App.ts"]))
        XCTAssertEqual(result.text, "open src/App.ts")
    }

    func testVerifyAndRepairTokenFollowedBySentencePeriodStaysClean() {
        // '.' is not a body char: a sentence period straight after the token
        // is a standalone occurrence, not appended-char corruption.
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "open src/App.ts. Done",
            original: "open src/App.ts"
        )
        XCTAssertEqual(result.outcome, .clean)
        XCTAssertEqual(result.text, "open src/App.ts. Done")
    }

    func testVerifyAndRepairAbsolutePathDroppedSlashFallsBack() {
        // The model dropped the leading slash, silently turning an absolute
        // path relative. Canonicalization never re-adds a slash, so this is
        // unrepairable: the polish is discarded.
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "Tail tmp/app.log now.",
            original: "tail /tmp/app.log now"
        )
        XCTAssertEqual(result.outcome, .fallback(missing: ["/tmp/app.log"]))
        XCTAssertEqual(result.text, "tail /tmp/app.log now")
    }

    func testVerifyAndRepairDoesNotRevertSentenceSpacingFix() {
        // "works.Then" is STT output missing a space, not a filename: the
        // polish inserts the space and the guard must leave that fix alone
        // (a protected "works.Then" would make the space-stripping repair
        // put the broken form back).
        let result = PolishTokenGuard.verifyAndRepair(
            polished: "It works. Then we ship.",
            original: "It works.Then we ship"
        )
        XCTAssertEqual(result.outcome, .clean)
        XCTAssertEqual(result.text, "It works. Then we ship.")
    }

    func testVerifyAndRepairIsIdempotentOnRepairedOutput() {
        let original = "run --force on src/App.ts"
        let first = PolishTokenGuard.verifyAndRepair(
            polished: "run \u{2013} force on src/app.ts",
            original: original
        )
        XCTAssertEqual(first.outcome, .repaired(count: 2))

        // Running the guard again on its own repaired output is a no-op.
        let second = PolishTokenGuard.verifyAndRepair(polished: first.text, original: original)
        XCTAssertEqual(second.outcome, .clean)
        XCTAssertEqual(second.text, first.text)
    }
}

// MARK: - View-model integration

@MainActor
final class DictationViewModelPolishTokenGuardTests: XCTestCase {
    // DictationViewModel owns app-lifetime services; retain test instances for
    // the process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    /// The guard repairs an en-dash-mangled flag: the committed and persisted
    /// text keep `--force` byte-exact even though the model returned `– force`.
    func testPolishTokenGuardRepairsMangledFlagInCommittedText() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = MangleFlagPolishingService(replacement: "\u{2013} force")
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        viewModel.llmPolishingService = polishingService
        var savedRecord: DictationSessionRecord?
        viewModel.debugSavedSessionRecordSink = { savedRecord = $0 }
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "run --force now"

        viewModel.finishStoppedSession(promotePendingSegment: false)
        await waitUntilStoppedSessionCompletes(viewModel)

        XCTAssertEqual(viewModel.currentDictationEventText, "run --force now")
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.displayText, "run --force now")
        XCTAssertFalse(viewModel.currentDictationEventText.contains("\u{2013} force"))
        // Nothing changed vs the raw text, so no polished text is persisted.
        XCTAssertEqual(savedRecord?.rawText, "run --force now")
        XCTAssertNil(savedRecord?.polishedText)
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
    }

    /// The fallback path end to end: the model deletes the protected flag, so
    /// the polish is discarded and the pre-polish working text (with the
    /// replacement dictionary applied) is committed and persisted.
    func testPolishTokenGuardFallbackKeepsPrePolishWorkingText() async {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.replacementDictionaryEnabled = true
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"

        let overlayCoordinator = MockOverlayCoordinator()
        let polishingService = DeleteFlagPolishingService()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlayCoordinator,
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            replacementDictionary: ReplacementDictionary(entries: [
                ReplacementEntry(replaceWith: "immediately", matches: ["now"]),
            ])
        )
        viewModel.llmPolishingService = polishingService
        var savedRecord: DictationSessionRecord?
        viewModel.debugSavedSessionRecordSink = { savedRecord = $0 }
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "run --force now"

        viewModel.finishStoppedSession(promotePendingSegment: false)
        await waitUntilStoppedSessionCompletes(viewModel)

        // The model dropped --force; the guard discards that polish and keeps
        // the replacement-applied working text, which still carries --force.
        XCTAssertEqual(viewModel.currentDictationEventText, "run --force immediately")
        XCTAssertEqual(overlayCoordinator.refreshCalls.last?.displayText, "run --force immediately")
        XCTAssertEqual(savedRecord?.rawText, "run --force now")
        XCTAssertEqual(savedRecord?.polishedText, "run --force immediately")
        XCTAssertEqual(overlayCoordinator.commitCallCount, 1)
    }

    // MARK: - Polish profile selection

    /// A terminal-like captured target with the agent profile enabled requests
    /// the AGENT prompt templates and records the profile on the session.
    func testAgentProfileSelectedForTerminalTarget() async {
        let mockConfig = MockAppConfigStore()
        let savedRecord = await runProfileSelectionSession(
            appConfigStore: mockConfig,
            agentProfileEnabled: true,
            capturedBundleID: "com.apple.Terminal"
        )

        XCTAssertEqual(mockConfig.requestedProfiles, [.agent])
        XCTAssertEqual(savedRecord?.polishProfile, "agent")
    }

    /// A user-listed terminal bundle (via terminal_apps.toml) also selects the
    /// agent profile even though it is not on the built-in allowlist.
    func testAgentProfileSelectedForUserListedTerminalBundle() async {
        let mockConfig = MockAppConfigStore(terminalAppBundleIDs: ["com.acme.ide"])
        let savedRecord = await runProfileSelectionSession(
            appConfigStore: mockConfig,
            agentProfileEnabled: true,
            capturedBundleID: "com.acme.ide"
        )

        XCTAssertEqual(mockConfig.requestedProfiles, [.agent])
        XCTAssertEqual(savedRecord?.polishProfile, "agent")
    }

    /// A non-terminal captured target keeps the standard profile.
    func testStandardProfileForNonTerminalTarget() async {
        let mockConfig = MockAppConfigStore()
        let savedRecord = await runProfileSelectionSession(
            appConfigStore: mockConfig,
            agentProfileEnabled: true,
            capturedBundleID: "com.acme.notes"
        )

        XCTAssertEqual(mockConfig.requestedProfiles, [.standard])
        XCTAssertEqual(savedRecord?.polishProfile, "standard")
    }

    /// The agent profile toggle off keeps the standard profile even in a
    /// terminal target.
    func testAgentProfileDisabledKeepsStandardEvenInTerminal() async {
        let mockConfig = MockAppConfigStore()
        let savedRecord = await runProfileSelectionSession(
            appConfigStore: mockConfig,
            agentProfileEnabled: false,
            capturedBundleID: "com.apple.Terminal"
        )

        XCTAssertEqual(mockConfig.requestedProfiles, [.standard])
        XCTAssertEqual(savedRecord?.polishProfile, "standard")
    }

    /// Drives an overlay stop-commit with polishing enabled through
    /// `finishStoppedSession` (never `beginDictationSession`, so no real
    /// connect-timeout is armed — mirrors the token-guard suite) and returns
    /// the persisted record.
    private func runProfileSelectionSession(
        appConfigStore: MockAppConfigStore,
        agentProfileEnabled: Bool,
        capturedBundleID: String?
    ) async -> DictationSessionRecord? {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "https://example.com/v1/chat/completions"
        settings.agentPolishProfileEnabled = agentProfileEnabled

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = appConfigStore
        viewModel.llmPolishingService = IdentityPolishingService()
        viewModel.debugResolveTargetAppBundleIDOverride = { capturedBundleID }
        var savedRecord: DictationSessionRecord?
        viewModel.debugSavedSessionRecordSink = { savedRecord = $0 }
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "fix the bug in the auth module"

        viewModel.finishStoppedSession(promotePendingSegment: false)
        await waitUntilStoppedSessionCompletes(viewModel)
        return savedRecord
    }

    // MARK: - Helpers

    private func waitUntilStoppedSessionCompletes(_ viewModel: DictationViewModel) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSettings(outputMode: DictationOutputMode) -> SettingsStore {
        let suiteName = "localvoxtral.DictationViewModelPolishTokenGuardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = outputMode
        return settings
    }

    private func retainForTestProcessLifetime(_ viewModel: DictationViewModel) {
        Self.retainedViewModels.append(viewModel)
    }
}

/// Returns the input with `--force` rewritten to a mangled variant, as a small
/// polish model that folds `--` into a dash might.
private actor MangleFlagPolishingService: LLMPolishingServicing {
    private let replacement: String

    init(replacement: String) {
        self.replacement = replacement
    }

    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        let polished = request.inputText.replacingOccurrences(of: "--force", with: replacement)
        return LLMPolishingResult(
            rawText: request.inputText,
            polishedText: polished,
            durationSeconds: 0.01
        )
    }
}

/// Returns the input unchanged — a no-op polish for profile-selection tests
/// that only care which prompt profile the session requested.
private actor IdentityPolishingService: LLMPolishingServicing {
    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        LLMPolishingResult(
            rawText: request.inputText,
            polishedText: request.inputText,
            durationSeconds: 0.01
        )
    }
}

/// Drops `--force` from the input entirely, exercising the unrepairable
/// fallback path.
private actor DeleteFlagPolishingService: LLMPolishingServicing {
    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        let polished = request.inputText.replacingOccurrences(of: "--force ", with: "")
        return LLMPolishingResult(
            rawText: request.inputText,
            polishedText: polished,
            durationSeconds: 0.01
        )
    }
}

private final class MockAppConfigStore: AppConfigServing {
    private let replacementDictionary: ReplacementDictionary
    private let promptTemplates: LLMPromptTemplates
    private let agentPromptTemplates: LLMPromptTemplates
    private let terminalAppBundleIDs: [String]
    /// Records every profile passed to `loadLLMPromptTemplates(profile:)`, so
    /// profile-selection tests can assert which prompt the session requested.
    private(set) var requestedProfiles: [PolishPromptProfile] = []

    init(
        replacementDictionary: ReplacementDictionary = ReplacementDictionary(entries: []),
        promptTemplates: LLMPromptTemplates = LLMPromptTemplates(
            systemContent: "system",
            userContent: "{{input_text}}"
        ),
        agentPromptTemplates: LLMPromptTemplates = LLMPromptTemplates(
            systemContent: "agent-system",
            userContent: "{{input_text}}"
        ),
        terminalAppBundleIDs: [String] = []
    ) {
        self.replacementDictionary = replacementDictionary
        self.promptTemplates = promptTemplates
        self.agentPromptTemplates = agentPromptTemplates
        self.terminalAppBundleIDs = terminalAppBundleIDs
    }

    func configDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        replacementDictionary
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        promptTemplates
    }

    func loadLLMPromptTemplates(profile: PolishPromptProfile) -> LLMPromptTemplates {
        requestedProfiles.append(profile)
        switch profile {
        case .standard:
            return promptTemplates
        case .agent:
            return agentPromptTemplates
        }
    }

    func loadTerminalAppBundleIDs() -> [String] {
        terminalAppBundleIDs
    }
}

private struct BufferCall {
    let displayText: String
    let commitText: String
}

@MainActor
private final class MockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitOutcome: OverlayBufferCommitOutcome = .succeeded

    var startSessionAnchors: [OverlayAnchor?] = []
    var beginFinalizingCalls: [BufferCall] = []
    var refreshCalls: [BufferCall] = []
    var commitCallCount = 0
    var dismissAfterHoldCallCount = 0
    var lastDismissAfterHoldMinimumVisibility: TimeInterval?
    var resetCallCount = 0
    var captureLiveCommitTargetAppPIDCallCount = 0
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor: OverlayAnchor?) {
        startSessionAnchors.append(preResolvedAnchor)
    }

    func beginFinalizing(displayBufferText: String, commitBufferText: String) {
        beginFinalizingCalls.append(
            BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        )
    }

    func refresh(displayBufferText: String, commitBufferText: String) {
        refreshCalls.append(
            BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        )
    }

    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting,
        autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome {
        commitCallCount += 1
        return commitOutcome
    }

    func dismissAfterHold(minimumVisibility: TimeInterval) {
        dismissAfterHoldCallCount += 1
        lastDismissAfterHoldMinimumVisibility = minimumVisibility
    }

    func reset() {
        resetCallCount += 1
    }

    func captureLiveCommitTargetAppPID() {
        captureLiveCommitTargetAppPIDCallCount += 1
    }
}
