import XCTest
@testable import localvoxtral

/// What a finished dictation teaches the app. The rules of the memory are
/// `LearnedTermsTests`' subject; what is pinned here is WHICH of a commit's
/// grounding decisions reach it — the entries the merge pre-applied, and
/// nothing else.
@MainActor
final class LearnedTermWiringTests: XCTestCase {
    private static var retainedViewModels: [DictationViewModel] = []

    private func makeViewModel(
        outcome: RepoVocabularyMatcher.GroundingOutcome?,
        repositoryRoot: String? = nil
    ) -> (DictationViewModel, LearnedTermStore) {
        let settings = makeSettings()
        settings.llmPolishingEnabled = true
        settings.agentPolishProfileEnabled = false
        settings.polishingBackendMode = .externalURL
        settings.llmPolishingEndpointURL = "http://127.0.0.1:8472/v1/chat/completions"
        settings.repoVocabularyEnabled = true

        let template = LLMPromptTemplates(
            systemContent: "system",
            userContent: "Clean this up.\n{{replacement_dictionary}}\nWorking text:\n{{input_text}}"
        )
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore(
            promptTemplates: template,
            agentPromptTemplates: template
        )
        viewModel.llmPolishingService = IdentityPolishingService()
        viewModel.debugResolveTargetAppBundleIDOverride = { "com.apple.Terminal" }
        viewModel.debugRepoVocabularyEntriesOverride = { _ in outcome }
        viewModel.debugRepoVocabularyRootOverride = repositoryRoot
        let store = LearnedTermStore(fileURL: nil)
        viewModel.learnedTermStore = store
        Self.retainedViewModels.append(viewModel)
        return (viewModel, store)
    }

    private func commit(_ viewModel: DictationViewModel, text: String) async {
        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = text
        viewModel.finishStoppedSession(promotePendingSegment: false)
        await waitUntilStoppedSessionCompletes(viewModel)
        viewModel.learnedTermStore?.waitForPendingWrites()
    }

    /// A spelling the merge pre-applied is remembered, under the shared
    /// project: this dictation had no joined session and no resolvable
    /// terminal directory.
    func testPreAppliedSpellingIsRemembered() async {
        let (viewModel, store) = makeViewModel(
            outcome: RepoVocabularyMatcher.GroundingOutcome(
                entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["useauth.ts"])],
                isFallbackOnly: false
            )
        )

        await commit(viewModel, text: "open useauth.ts please")

        XCTAssertEqual(
            store.confirmedTerms(
                projectKey: LearnedTermProjectResolver.shared.key, minimumDictations: 1
            ),
            ["useAuth.ts"]
        )
    }

    /// A sound-alike offered to the model for verification is a question, not
    /// an answer. Remembering one would let a guess harden into vocabulary.
    func testVerificationCandidateIsNotRemembered() async {
        let (viewModel, store) = makeViewModel(
            outcome: RepoVocabularyMatcher.GroundingOutcome(
                entries: [],
                isFallbackOnly: false,
                verificationCandidates: [
                    ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use off"])
                ]
            )
        )

        await commit(viewModel, text: "open use off please")

        XCTAssertEqual(store.snapshot().termCount, 0)
    }

    /// The repository the pipeline resolved is the project the dictation
    /// teaches — not the shared bucket, which is for dictation with no project
    /// at all.
    func testTermIsRememberedUnderTheResolvedRepository() async {
        let (viewModel, store) = makeViewModel(
            outcome: RepoVocabularyMatcher.GroundingOutcome(
                entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["useauth.ts"])],
                isFallbackOnly: false
            ),
            repositoryRoot: "/Users/t/work/localvoxtral"
        )

        await commit(viewModel, text: "open useauth.ts please")

        XCTAssertEqual(
            store.confirmedTerms(
                projectKey: "/Users/t/work/localvoxtral", minimumDictations: 1
            ),
            ["useAuth.ts"]
        )
        XCTAssertTrue(
            store.confirmedTerms(
                projectKey: LearnedTermProjectResolver.shared.key, minimumDictations: 1
            ).isEmpty
        )
    }

    /// Two dictations of the same term are two confirmations, not one: the
    /// counter has to survive the commit path, not just the value type.
    func testSecondDictationConfirmsTheSameTerm() async {
        let (viewModel, store) = makeViewModel(
            outcome: RepoVocabularyMatcher.GroundingOutcome(
                entries: [ReplacementEntry(replaceWith: "polishd", matches: ["polish d"])],
                isFallbackOnly: false
            )
        )

        await commit(viewModel, text: "restart polish d now")
        await commit(viewModel, text: "restart polish d again")

        XCTAssertEqual(
            store.snapshot()
                .confirmed(projectKey: LearnedTermProjectResolver.shared.key, minimumDictations: 1)
                .first?.dictations,
            2
        )
    }

    // MARK: - Helpers

    private func waitUntilStoppedSessionCompletes(_ viewModel: DictationViewModel) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSettings() -> SettingsStore {
        let suiteName = "localvoxtral.LearnedTermWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore()
        )
        settings.dictationOutputMode = .overlayBuffer
        return settings
    }
}

@MainActor
private final class MockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor _: OverlayAnchor?, claudeJoin _: OverlayClaudeJoinBadge) {}
    func beginFinalizing(displayBufferText _: String, commitBufferText _: String) {}
    func refresh(displayBufferText _: String, commitBufferText _: String) {}

    func commitIfNeeded(
        using _: OverlayTextCommitting,
        autoCopyEnabled _: Bool
    ) -> OverlayBufferCommitOutcome {
        .succeeded
    }

    func dismissAfterHold(minimumVisibility _: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}

private final class MockAppConfigStore: AppConfigServing {
    private let promptTemplates: LLMPromptTemplates
    private let agentPromptTemplates: LLMPromptTemplates

    init(promptTemplates: LLMPromptTemplates, agentPromptTemplates: LLMPromptTemplates) {
        self.promptTemplates = promptTemplates
        self.agentPromptTemplates = agentPromptTemplates
    }

    func configDirectoryURL() -> URL { FileManager.default.temporaryDirectory }
    func loadReplacementDictionary() -> ReplacementDictionary { ReplacementDictionary(entries: []) }
    func loadLLMPromptTemplates() -> LLMPromptTemplates { promptTemplates }

    func loadLLMPromptTemplates(profile: PolishPromptProfile) -> LLMPromptTemplates {
        profile == .agent ? agentPromptTemplates : promptTemplates
    }

    func loadTerminalAppBundleIDs() -> [String] { [] }
}

/// Returns the input unchanged: what the model does with the prompt is not
/// this file's subject.
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
