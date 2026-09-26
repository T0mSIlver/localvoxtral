import XCTest
@testable import localvoxtralCore

@MainActor
private final class RecordingPresenter: CorrectionLearningPresenting {
    var shown: [String] = []
    var undo: (@MainActor () -> Void)?

    func showLearned(term: String, undo: @escaping @MainActor () -> Void) {
        shown.append(term)
        self.undo = undo
    }
}

/// The learner around `CorrectionDiffClassifier`: which prompt a dictation is
/// compared with, for how long, and what the user is told.
@MainActor
final class CorrectionLearningTests: XCTestCase {
    private let project = LearnedTermProjectResolver.Identity(
        key: "/Users/t/work/localvoxtral", name: "localvoxtral"
    )
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var speakerTerms: [String] = []

    private func makeLearner() -> (CorrectionLearning, LearnedTermStore, RecordingPresenter) {
        let store = LearnedTermStore(fileURL: nil, now: { [start] in start })
        let learner = CorrectionLearning(
            store: store,
            knownTerms: { [unowned self] in self.speakerTerms },
            now: { [unowned self] in self.clock }
        )
        let presenter = RecordingPresenter()
        learner.presenter = presenter
        return (learner, store, presenter)
    }

    func testFixInTheSubmittedPromptIsLearnedAndShownOnce() async {
        let (learner, store, presenter) = makeLearner()
        learner.expect(inserted: "please fix the kwen tokenizer", sessionID: "s1", project: project)
        clock += 20
        learner.promptSubmitted(sessionID: "s1", prompt: "please fix the Qwen tokenizer")
        store.waitForPendingWrites()

        XCTAssertEqual(store.confirmedTerms(projectKey: project.key), ["Qwen"])
        XCTAssertEqual(presenter.shown, ["Qwen"])
        XCTAssertTrue(learner.pending.isEmpty, "a prompt is compared once")

        // The same fix in a later dictation confirms it again, silently.
        learner.expect(inserted: "the kwen server is down", sessionID: "s1", project: project)
        learner.promptSubmitted(sessionID: "s1", prompt: "the Qwen server is down")
        store.waitForPendingWrites()
        XCTAssertEqual(presenter.shown, ["Qwen"])
        XCTAssertEqual(store.snapshot().projects.first?.terms.first?.dictations, 2)
    }

    func testUndoForgetsTheTerm() async {
        let (learner, store, presenter) = makeLearner()
        learner.expect(inserted: "please fix the kwen tokenizer", sessionID: "s1", project: project)
        learner.promptSubmitted(sessionID: "s1", prompt: "please fix the Qwen tokenizer")
        store.waitForPendingWrites()

        presenter.undo?()
        store.waitForPendingWrites()
        XCTAssertEqual(store.summary().terms, 0)
    }

    func testPromptAfterTheWindowTeachesNothing() async {
        let (learner, store, presenter) = makeLearner()
        learner.expect(inserted: "please fix the kwen tokenizer", sessionID: "s1", project: project)
        clock += CorrectionLearning.window + 1
        learner.promptSubmitted(sessionID: "s1", prompt: "please fix the Qwen tokenizer")
        store.waitForPendingWrites()

        XCTAssertEqual(store.summary().terms, 0)
        XCTAssertEqual(presenter.shown, [])
    }

    /// Another session's prompt is not this dictation's fix, and does not use
    /// up the wait for the session the dictation went into.
    func testAnotherSessionsPromptIsNotCompared() async {
        let (learner, store, _) = makeLearner()
        learner.expect(inserted: "please fix the kwen tokenizer", sessionID: "s1", project: project)
        learner.promptSubmitted(sessionID: "s2", prompt: "please fix the Qwen tokenizer")
        store.waitForPendingWrites()
        XCTAssertEqual(store.summary().terms, 0)

        learner.promptSubmitted(sessionID: "s1", prompt: "please fix the Qwen tokenizer")
        store.waitForPendingWrites()
        XCTAssertEqual(store.confirmedTerms(projectKey: project.key), ["Qwen"])
    }

    /// Two dictations before one send land in one prompt.
    func testTwoDictationsBeforeOneSendAreComparedTogether() async {
        let (learner, store, _) = makeLearner()
        learner.expect(inserted: "the kwen tokenizer", sessionID: "s1", project: project)
        clock += 30
        learner.expect(inserted: "drops the BOS token", sessionID: "s1", project: project)
        learner.promptSubmitted(sessionID: "s1", prompt: "the Qwen tokenizer drops the BOS token")
        store.waitForPendingWrites()

        XCTAssertEqual(store.confirmedTerms(projectKey: project.key), ["Qwen"])
    }

    func testRewordedPromptTeachesNothing() async {
        let (learner, store, presenter) = makeLearner()
        learner.expect(inserted: "fix the bug in the parser", sessionID: "s1", project: project)
        learner.promptSubmitted(sessionID: "s1", prompt: "fix the issue in the parser")
        store.waitForPendingWrites()

        XCTAssertEqual(store.summary().terms, 0)
        XCTAssertEqual(presenter.shown, [])
    }

    /// Turning a remembered spelling back into what was said forgets it.
    func testRevertingALearnedSpellingForgetsIt() async {
        let (learner, store, presenter) = makeLearner()
        store.recordCorrection("SessionStart", project: project)
        store.waitForPendingWrites()

        learner.expect(inserted: "hook the SessionStart event", sessionID: "s1", project: project)
        learner.promptSubmitted(sessionID: "s1", prompt: "hook the session start event")
        store.waitForPendingWrites()

        XCTAssertEqual(store.summary().terms, 0)
        XCTAssertEqual(presenter.shown, [])
    }

    /// A spelling already in Names and terms is the user's everywhere.
    func testListedTermIsNotRememberedAgain() async {
        speakerTerms = ["Qwen"]
        let (learner, store, presenter) = makeLearner()
        learner.expect(inserted: "please fix the kwen tokenizer", sessionID: "s1", project: project)
        learner.promptSubmitted(sessionID: "s1", prompt: "please fix the Qwen tokenizer")
        store.waitForPendingWrites()

        XCTAssertEqual(store.summary().terms, 0)
        XCTAssertEqual(presenter.shown, [])
    }

    /// Enter pressed as the last word appears can beat the stop's commit.
    func testPromptArrivingJustBeforeTheCommitIsStillCompared() async {
        let (learner, store, _) = makeLearner()
        learner.promptSubmitted(sessionID: "s1", prompt: "please fix the Qwen tokenizer")
        clock += CorrectionLearning.earlyPromptGrace - 1
        learner.expect(inserted: "please fix the kwen tokenizer", sessionID: "s1", project: project)
        store.waitForPendingWrites()

        XCTAssertEqual(store.confirmedTerms(projectKey: project.key), ["Qwen"])
        XCTAssertTrue(learner.pending.isEmpty)
        XCTAssertTrue(learner.earlyPrompts.isEmpty)
    }

    func testAnEarlierPromptPastTheGraceIsNotCompared() async {
        let (learner, store, _) = makeLearner()
        learner.promptSubmitted(sessionID: "s1", prompt: "please fix the Qwen tokenizer")
        clock += CorrectionLearning.earlyPromptGrace + 1
        learner.expect(inserted: "please fix the kwen tokenizer", sessionID: "s1", project: project)
        store.waitForPendingWrites()

        XCTAssertEqual(store.summary().terms, 0)
        XCTAssertNotNil(learner.pending["s1"], "the dictation still waits for its own prompt")
    }

    /// The store keeps no spelling past 60 characters, so none is announced.
    func testAFixTooLongToRememberIsNotAnnounced() async {
        let (learner, store, presenter) = makeLearner()
        let long = "Aaaaaaaaaaaaaaa.Bbbbbbbbbbbbbbb.Cccccccccccccccc.Dddddddddddddddd.ts"
        learner.expect(
            inserted: "open aaaaaaaaaaaaaaa bbbbbbbbbbbbbbb cccccccccccccccc dddddddddddddddd now",
            sessionID: "s1",
            project: project
        )
        learner.promptSubmitted(sessionID: "s1", prompt: "open \(long) now")
        store.waitForPendingWrites()

        XCTAssertEqual(store.summary().terms, 0)
        XCTAssertEqual(presenter.shown, [])
    }

    func testPendingSessionsAreCapped() async {
        let (learner, _, _) = makeLearner()
        for index in 0...CorrectionLearning.maxPending {
            clock += 1
            learner.expect(inserted: "text \(index)", sessionID: "s\(index)", project: project)
        }
        XCTAssertEqual(learner.pending.count, CorrectionLearning.maxPending)
        XCTAssertNil(learner.pending["s0"], "the oldest wait goes first")
    }
}
