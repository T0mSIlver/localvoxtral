import XCTest
@testable import localvoxtral

/// What a finished dictation teaches the app. The rules of the memory are
/// `LearnedTermsTests`' subject; what is pinned here is WHICH of a commit's
/// grounding decisions reach it — the entries the merge pre-applied, and
/// nothing else.
@MainActor
final class LearnedTermWiringTests: XCTestCase {
    private func makeViewModel(
        outcome: RepoVocabularyMatcher.GroundingOutcome?,
        repositoryRoot: String? = nil,
        service: any LLMPolishingServicing = FakePolishingService()
    ) -> (DictationViewModel, LearnedTermStore) {
        let settings = makeSettings(outputMode: .overlayBuffer)
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
        viewModel.llmPolishingService = service
        viewModel.stubCommitTarget { "com.apple.Terminal" }
        viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding(
            outcome: outcome, root: repositoryRoot
        )
        let store = LearnedTermStore(fileURL: nil)
        viewModel.learnedTermStore = store
        retainForTestProcessLifetime(viewModel)
        return (viewModel, store)
    }

    /// Grounding, the merge and the learned terms all land inside
    /// `polishAndCommitTask`, so the commit is awaited before anything is read.
    private func commit(_ viewModel: DictationViewModel, text: String) async {
        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = text
        viewModel.finishStoppedSession(promotePendingSegment: false)
        XCTAssertNotNil(
            viewModel.polishAndCommitTask,
            "the commit these tests assert on is the polish task"
        )
        await awaitStoppedSessionCommit(viewModel)
        viewModel.learnedTermStore?.waitForPendingWrites()
    }

    /// Seeds sightings of one term and waits for them to land.
    ///
    /// `LearnedTermStore.record` folds on its own `.utility` queue while
    /// `snapshot()` reads straight out of memory, so an unawaited seed is
    /// invisible to the commit path's read — which then grounds the dictation
    /// against nothing (#392).
    private func seed(
        _ store: LearnedTermStore,
        term: String,
        source: PolishContextSource = .repository,
        dictations: Int
    ) {
        for _ in 0..<dictations {
            store.record(
                [LearnedTermObservation(term: term, source: source)],
                project: LearnedTermProjectResolver.shared
            )
        }
        store.waitForPendingWrites()
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

    // MARK: - Reading the memory back

    /// The point of the whole feature: a spelling confirmed in this project
    /// corrects a later dictation with no repo, screen or session hit at all.
    func testConfirmedTermGroundsALaterDictationWithNoLiveSource() async {
        let recording = FakePolishingService()
        let (viewModel, store) = makeViewModel(outcome: nil, service: recording)
        seed(store, term: "useAuth.ts", dictations: 3)

        await commit(viewModel, text: "open useauth.ts please")

        let request = await recording.lastRequest
        XCTAssertEqual(
            request?.inputText, "open useAuth.ts please",
            "the remembered spelling is placed before the model call, like any other source"
        )
    }

    /// Below the bar, nothing is used: two sightings can be the same mistake
    /// twice, and a mistake that grounds is a mistake that spreads.
    func testUnconfirmedTermDoesNotGroundADictation() async {
        let recording = FakePolishingService()
        let (viewModel, store) = makeViewModel(outcome: nil, service: recording)
        seed(store, term: "useAuth.ts", dictations: 2)

        await commit(viewModel, text: "open useauth.ts please")

        let request = await recording.lastRequest
        XCTAssertEqual(request?.inputText, "open useauth.ts please")
    }

    /// Matching the memory refreshes the term without claiming to be where the
    /// spelling came from — otherwise every project's provenance would decay
    /// into "learned".
    func testGroundingFromMemoryRefreshesWithoutRewritingProvenance() async {
        let (viewModel, store) = makeViewModel(outcome: nil)
        seed(store, term: "useAuth.ts", dictations: 3)

        await commit(viewModel, text: "open useauth.ts please")

        let stored = store.snapshot()
            .confirmed(projectKey: LearnedTermProjectResolver.shared.key).first
        XCTAssertEqual(stored?.dictations, 4)
        XCTAssertEqual(stored?.sources, ["repository"])
    }

    // MARK: - Helpers

}
