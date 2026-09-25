import XCTest
@testable import localvoxtral

@MainActor
final class TermSuggestionCadenceTests: XCTestCase {
    /// Holds each request until the test answers it, so "in flight" is a state
    /// the test controls instead of a race it hopes to win.
    private final class Service: LLMPolishingServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<String, Error>] = []
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var _requestCount = 0
        var requestCount: Int {
            get { lock.withLock { _requestCount } }
        }

        func polish(
            request: LLMPolishingRequest, configuration: LLMPolishingConfiguration
        ) async throws -> LLMPolishingResult {
            let reply = try await withCheckedThrowingContinuation { continuation in
                let waiters = lock.withLock {
                    _requestCount += 1
                    waiting.append(continuation)
                    defer { arrivals = [] }
                    return arrivals
                }
                waiters.forEach { $0.resume() }
            }
            return LLMPolishingResult(
                rawText: request.inputText, polishedText: reply, durationSeconds: 0
            )
        }

        /// Returns once `count` requests have reached the service.
        func requestArrived(count: Int) async {
            while lock.withLock({ _requestCount < count }) {
                await withCheckedContinuation { continuation in
                    let alreadyThere = lock.withLock {
                        if _requestCount >= count { return true }
                        arrivals.append(continuation)
                        return false
                    }
                    if alreadyThere { continuation.resume() }
                }
            }
        }

        func answer(_ result: Result<String, Error>) {
            lock.withLock { waiting.removeFirst() }.resume(with: result)
        }
    }

    private struct Fixture {
        let defaults: UserDefaults
        let settings: SettingsStore
        let service: Service
        let model: SpeakerTermSuggestionModel
        let cadence: TermSuggestionCadence
    }

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var dictationActive = false
    private var finished: [SpeakerTermSuggestionModel.RunOutcome] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

    private func makeFixture(hosted: Bool = true) -> Fixture {
        let suiteName = "localvoxtral.TermSuggestionCadenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore()
        )
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "http://127.0.0.1:9/v1/chat/completions"
        settings.termSuggestionInterval = .every25

        let service = Service()
        let model = SpeakerTermSuggestionModel(
            settings: settings,
            recentDictations: { ["a text", "another"].map { .init(raw: $0, final: $0) } },
            service: { service },
            unavailableReason: { hosted ? nil : "Needs a hosted polishing model." }
        )
        let launchedAt = clock
        let cadence = TermSuggestionCadence(
            settings: settings,
            model: { model },
            isDictationActive: { [unowned self] in self.dictationActive },
            launchedAt: launchedAt,
            now: { [unowned self] in self.clock }
        )
        model.onRunFinished = { [unowned self] outcome, countAtStart in
            cadence.runFinished(outcome, countAtStart: countAtStart)
            self.finished.append(outcome)
            let waiters = self.finishedWaiters
            self.finishedWaiters = []
            waiters.forEach { $0.resume() }
        }
        clock = clock.addingTimeInterval(TermSuggestionCadence.quietAfterLaunchSeconds)
        return Fixture(defaults: defaults, settings: settings, service: service, model: model, cadence: cadence)
    }

    private func runFinished(count: Int) async {
        while finished.count < count {
            await withCheckedContinuation { finishedWaiters.append($0) }
        }
    }

    private func save(_ count: Int, _ fixture: Fixture) {
        for _ in 0..<count { fixture.cadence.dictationSaved() }
    }

    // MARK: - The threshold

    func testTheRunStartsWhenTheCounterCrossesTheIntervalAndNotBefore() async {
        let fixture = makeFixture()

        save(24, fixture)
        XCTAssertEqual(fixture.model.phase, .idle)

        save(1, fixture)
        await fixture.service.requestArrived(count: 1)
        XCTAssertEqual(fixture.model.phase, .loading)
        XCTAssertEqual(fixture.service.requestCount, 1)
    }

    func testTheDefaultIsEveryFiftyDictations() {
        let suiteName = "localvoxtral.TermSuggestionCadenceTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore()
        )
        XCTAssertEqual(settings.termSuggestionInterval, .every50)
        XCTAssertEqual(settings.termSuggestionInterval.dictations, 50)
    }

    func testNeverMeansNoRunHoweverManyDictations() {
        let fixture = makeFixture()
        fixture.settings.termSuggestionInterval = .never

        save(300, fixture)

        XCTAssertEqual(fixture.model.phase, .idle)
        XCTAssertEqual(fixture.service.requestCount, 0)
    }

    func testABundledPolishingModelIsNeverAsked() {
        let fixture = makeFixture(hosted: false)

        save(25, fixture)

        XCTAssertEqual(fixture.model.phase, .idle)
        XCTAssertEqual(fixture.service.requestCount, 0)
    }

    // MARK: - One run at a time, and what resets the counter

    func testDictationsSavedWhileARunIsInFlightDoNotStartASecondOne() async {
        let fixture = makeFixture()

        save(25, fixture)
        await fixture.service.requestArrived(count: 1)
        save(25, fixture)

        XCTAssertEqual(fixture.service.requestCount, 1)
        XCTAssertEqual(fixture.settings.termSuggestionDictationsSinceRun, 50)

        fixture.service.answer(.success(#"["Qwen"]"#))
        await runFinished(count: 1)

        XCTAssertEqual(finished, [.completed])
        // The 25 saved while the request was out were never read.
        XCTAssertEqual(fixture.settings.termSuggestionDictationsSinceRun, 25)
        XCTAssertEqual(fixture.model.suggestions, ["Qwen"])
    }

    /// A dictation that STARTS during a run does not stop it.
    func testADictationStartingMidRunLeavesItRunning() async {
        let fixture = makeFixture()

        save(25, fixture)
        await fixture.service.requestArrived(count: 1)
        dictationActive = true
        fixture.service.answer(.success(#"["Qwen"]"#))
        await runFinished(count: 1)

        XCTAssertEqual(fixture.model.suggestions, ["Qwen"])
    }

    func testAFailedRunKeepsTheCounterAndWaitsTenMoreDictations() async {
        let fixture = makeFixture()

        save(25, fixture)
        await fixture.service.requestArrived(count: 1)
        fixture.service.answer(.failure(URLError(.timedOut)))
        await runFinished(count: 1)

        XCTAssertEqual(finished, [.failed])
        XCTAssertEqual(fixture.settings.termSuggestionDictationsSinceRun, 25)
        // Nobody pressed anything, so the row carries no failure text.
        XCTAssertEqual(fixture.model.phase, .idle)

        // A relaunch does not forget the wait.
        let relaunched = SettingsStore(
            defaults: fixture.defaults, environment: [:], secretStore: InMemorySecretStore()
        )
        XCTAssertEqual(relaunched.termSuggestionRetryAt, 25 + TermSuggestionCadence.retryAfterFailure)

        save(TermSuggestionCadence.retryAfterFailure - 1, fixture)
        XCTAssertEqual(fixture.service.requestCount, 1)

        save(1, fixture)
        await fixture.service.requestArrived(count: 2)
        XCTAssertEqual(fixture.service.requestCount, 2)
    }

    func testARunFromTheButtonResetsTheCounterToo() async {
        let fixture = makeFixture()
        save(20, fixture)

        fixture.model.start()
        await fixture.service.requestArrived(count: 1)
        fixture.service.answer(.success("[]"))
        await runFinished(count: 1)

        XCTAssertEqual(fixture.settings.termSuggestionDictationsSinceRun, 0)
    }

    /// A stopped run whose request fails late must not put the row of the
    /// run that replaced it back to idle: the next dictation would start a
    /// third request beside it.
    func testAStoppedRunReturningLateLeavesItsReplacementAlone() async {
        let fixture = makeFixture()

        save(25, fixture)
        await fixture.service.requestArrived(count: 1)
        fixture.model.stop()
        fixture.model.start()
        await fixture.service.requestArrived(count: 2)

        fixture.service.answer(.failure(URLError(.timedOut)))
        await runFinished(count: 2)

        XCTAssertEqual(finished, [.stopped, .notRun])
        XCTAssertEqual(fixture.model.phase, .loading)

        // The replacement read everything (it came from the button), and the
        // late return of the stopped run took nothing from its bookkeeping.
        save(3, fixture)
        fixture.service.answer(.success("[]"))
        await runFinished(count: 3)
        XCTAssertEqual(fixture.settings.termSuggestionDictationsSinceRun, 0)
    }

    /// Stop means stop: the next saved dictation must not restart the run
    /// the user just killed.
    func testStoppingABackgroundRunWaitsTenDictationsLikeAFailure() async {
        let fixture = makeFixture()

        save(25, fixture)
        await fixture.service.requestArrived(count: 1)
        fixture.model.stop()
        fixture.service.answer(.failure(CancellationError()))
        await runFinished(count: 2)

        save(TermSuggestionCadence.retryAfterFailure - 1, fixture)
        XCTAssertEqual(fixture.service.requestCount, 1)

        save(1, fixture)
        await fixture.service.requestArrived(count: 2)
    }

    // MARK: - Deferrals

    func testADictationInProgressDefersTheRunToTheNextSave() async {
        let fixture = makeFixture()
        dictationActive = true

        save(25, fixture)
        XCTAssertEqual(fixture.model.phase, .idle)

        dictationActive = false
        save(1, fixture)
        await fixture.service.requestArrived(count: 1)
        XCTAssertEqual(fixture.model.phase, .loading)
    }

    func testNoRunInsideTheFirstMinuteAfterLaunch() async {
        let fixture = makeFixture()
        clock = clock.addingTimeInterval(-1)

        save(25, fixture)
        XCTAssertEqual(fixture.model.phase, .idle)

        clock = clock.addingTimeInterval(1)
        save(1, fixture)
        await fixture.service.requestArrived(count: 1)
        XCTAssertEqual(fixture.model.phase, .loading)
    }

    func testTheCounterSurvivesARelaunch() {
        let fixture = makeFixture()
        save(7, fixture)

        let relaunched = SettingsStore(
            defaults: fixture.defaults, environment: [:], secretStore: InMemorySecretStore()
        )
        XCTAssertEqual(relaunched.termSuggestionDictationsSinceRun, 7)
        XCTAssertEqual(relaunched.termSuggestionInterval, .every25)
    }

    // MARK: - The sidebar badge

    func testChipsLandingUnseenBadgeTheRowUntilThePaneOpens() async {
        let fixture = makeFixture()

        save(25, fixture)
        await fixture.service.requestArrived(count: 1)
        fixture.service.answer(.success(#"["Qwen", "Ghostty"]"#))
        await runFinished(count: 1)
        XCTAssertEqual(fixture.model.badgeCount, 2)

        fixture.model.dismiss("Ghostty")
        XCTAssertEqual(fixture.model.badgeCount, 1)

        fixture.model.paneAppeared()
        XCTAssertEqual(fixture.model.badgeCount, 0)
    }

    func testChipsLandingWhileThePaneIsOpenDoNotBadge() async {
        let fixture = makeFixture()
        fixture.model.paneAppeared()

        save(25, fixture)
        await fixture.service.requestArrived(count: 1)
        fixture.service.answer(.success(#"["Qwen"]"#))
        await runFinished(count: 1)

        XCTAssertEqual(fixture.model.badgeCount, 0)

        fixture.model.paneDisappeared()
        XCTAssertEqual(fixture.model.badgeCount, 0)
    }

    /// The free chips count: the app refreshes them after each dictation that
    /// taught it something, not only when the pane opens.
    func testLearnedChipsBadgeTheRow() {
        let settings = makeFixture().settings
        let model = SpeakerTermSuggestionModel(
            settings: settings,
            recentDictations: { [] },
            learnedTerms: { ["Voxtral", "polishd"] },
            service: { Service() }
        )

        model.refreshLearnedSuggestions()

        XCTAssertEqual(model.badgeCount, 2)
    }
}
