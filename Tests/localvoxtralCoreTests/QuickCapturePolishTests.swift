import Foundation
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// #970: a capture is polished once before it is routed, with every
/// project's names and confirmed terms.
@MainActor
final class QuickCapturePolishTests: XCTestCase {
    private var fileURL: URL!
    private let github = FakeQuickCaptureGitHub()
    private var polishedRecords: [(id: UUID, text: String, seconds: Double)] = []
    private var routed: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private let raw = "put slash reload plugins in the local Voxroll documentation"
    private let polished = "Put /reload-plugins in the localvoxtral documentation."

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-polish-\(UUID().uuidString)")
            .appendingPathComponent("quick-captures.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func model(
        classifier: ScriptedQuickCaptureClassifier,
        runner: FakeQuickCaptureDraftRunner,
        polisher: FakeQuickCapturePolisher?
    ) -> QuickCaptureInboxModel {
        let model = QuickCaptureFixture.model(
            fileURL: fileURL, answer: [:], github: github, runner: runner, classifier: classifier,
            polisher: polisher, polishVocabulary: { $0.map(\.name) + ["localvoxtral"] },
            now: { [unowned self] in self.clock }
        )
        model.onPolished = { [weak self] id, text, seconds in self?.polishedRecords.append((id, text, seconds)) }
        model.onRouted = { [weak self] _, destination in self?.routed.append(destination) }
        return model
    }

    private func prompts(_ runner: FakeQuickCaptureDraftRunner) -> String {
        runner.arguments.withLock { $0.flatMap { $0 }.joined(separator: " ") }
    }

    // MARK: The pipeline

    func testTheRouterTheDrafterAndHistoryGetThePolishedWords() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95]])
        let runner = FakeQuickCaptureDraftRunner()
        let polisher = FakeQuickCapturePolisher { [polished] _ in polished }
        let model = model(classifier: classifier, runner: runner, polisher: polisher)
        let recordID = UUID()

        await model.capture(text: raw, historyRecordID: recordID).value

        XCTAssertEqual(polisher.calls.map(\.text), [raw])
        XCTAssertEqual(polisher.calls.first?.vocabulary, ["reach", "website", "localvoxtral"])
        XCTAssertEqual(classifier.captures.withLock { $0 }, [polished])
        XCTAssertTrue(prompts(runner).contains(polished))
        XCTAssertFalse(prompts(runner).contains("Voxroll"), "the drafter never reads the raw words")
        XCTAssertEqual(model.items.first?.text, polished)
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).items.first?.text, polished)
        XCTAssertEqual(polishedRecords.map(\.id), [recordID])
        XCTAssertEqual(polishedRecords.first?.text, polished)
        XCTAssertEqual(polishedRecords.first?.seconds, 1.5)
        XCTAssertEqual(routed, ["reach"])
    }

    func testAFailedPolishRoutesTheRawWords() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95]])
        let runner = FakeQuickCaptureDraftRunner()
        let polisher = FakeQuickCapturePolisher { _ in nil }
        let model = model(classifier: classifier, runner: runner, polisher: polisher)

        await model.capture(text: raw, historyRecordID: UUID()).value

        XCTAssertEqual(polisher.calls.count, 1)
        XCTAssertEqual(classifier.captures.withLock { $0 }, [raw])
        XCTAssertEqual(model.items.first?.text, raw)
        XCTAssertTrue(polishedRecords.isEmpty, "History keeps no polished text")
        XCTAssertEqual(routed, ["reach"])
    }

    /// A capture is never lost: the file holds the raw words while the
    /// polish runs, and nothing routes before it answers.
    func testTheFileHoldsTheRawWordsWhileThePolishRuns() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95]])
        let polisher = FakeQuickCapturePolisher(gated: true) { [polished] _ in polished }
        let model = model(classifier: classifier, runner: FakeQuickCaptureDraftRunner(), polisher: polisher)

        let task = model.capture(text: raw, historyRecordID: UUID())
        await polisher.gate?.waitForSleepers(1)

        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).items.first?.text, raw)
        XCTAssertEqual(model.items.first?.state, .routing)
        XCTAssertTrue(classifier.captures.withLock { $0 }.isEmpty)

        polisher.gate?.wakeAll()
        await task.value
        XCTAssertEqual(QuickCaptureInboxFile.load(from: fileURL).items.first?.text, polished)
    }

    func testACaptureDiscardedDuringThePolishIsNotRouted() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95]])
        let polisher = FakeQuickCapturePolisher(gated: true) { [polished] _ in polished }
        let model = model(classifier: classifier, runner: FakeQuickCaptureDraftRunner(), polisher: polisher)

        let task = model.capture(text: raw, historyRecordID: UUID())
        await polisher.gate?.waitForSleepers(1)
        model.discard(try XCTUnwrap(model.items.first?.id))
        polisher.gate?.wakeAll()
        await task.value

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(classifier.captures.withLock { $0 }.isEmpty)
        XCTAssertTrue(polishedRecords.isEmpty)
    }

    /// "Also" still joins the latest capture, from the polished words or,
    /// when the polish reworded the start, from the raw ones.
    func testAFollowUpStillJoinsAfterThePolish() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95]])
        let runner = FakeQuickCaptureDraftRunner()
        let polisher = FakeQuickCapturePolisher { text in
            switch text {
            case "also the settings window": return "Also, the settings window."
            case "also the about box": return "The about box too."
            default: return text
            }
        }
        let model = model(classifier: classifier, runner: runner, polisher: polisher)
        await model.capture(text: "Add a dark mode", historyRecordID: UUID()).value

        clock += 600
        await model.capture(text: "also the settings window", historyRecordID: UUID()).value
        clock += 60
        await model.capture(text: "also the about box", historyRecordID: UUID()).value

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.followUps?.map(\.text), ["Also, the settings window.", "The about box too."])
        XCTAssertEqual(classifier.captures.withLock { $0 }, ["Add a dark mode"], "the words alone decided both joins")
        XCTAssertTrue(prompts(runner).contains("Add what the user said next: Also, the settings window."))
    }

    /// Captures are placed in the order they were made: an "also" whose
    /// polish answers first waits for the capture before it, then joins it.
    func testAFollowUpWhosePolishEndsFirstStillJoinsTheCaptureBeforeIt() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["reach": 0.95]])
        let runner = FakeQuickCaptureDraftRunner()
        let polisher = FakeQuickCapturePolisher(gatedCalls: [0, 1]) { text in
            text == "add a dark mode" ? "Add a dark mode." : "Also, the settings window."
        }
        let model = model(classifier: classifier, runner: runner, polisher: polisher)
        let second = UUID()
        var secondPolished: CheckedContinuation<Void, Never>?
        model.onPolished = { id, _, _ in if id == second { secondPolished?.resume() } }

        let first = model.capture(text: "add a dark mode", historyRecordID: UUID())
        clock += 60
        let followUp = model.capture(text: "also the settings window", historyRecordID: second)
        let firstGate = try XCTUnwrap(polisher.callGates[0])
        let secondGate = try XCTUnwrap(polisher.callGates[1])
        await firstGate.waitForSleepers(1)
        await secondGate.waitForSleepers(1)

        await withCheckedContinuation { continuation in
            secondPolished = continuation
            secondGate.wakeAll()
        }
        XCTAssertTrue(classifier.captures.withLock { $0 }.isEmpty, "the follow-up waits for the first capture")
        firstGate.wakeAll()
        await first.value
        await followUp.value

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.text, "Add a dark mode.")
        XCTAssertEqual(model.items.first?.followUps?.map(\.text), ["Also, the settings window."])
        XCTAssertEqual(classifier.captures.withLock { $0 }, ["Add a dark mode."])
    }

    // MARK: Vocabulary

    private func confirmed(_ terms: [String], in project: LearnedTermProjectIdentity, _ memory: inout LearnedTerms) {
        for day in 0..<LearnedTerms.confirmedDictations {
            memory.record(
                terms.map { LearnedTermObservation(term: $0, source: .repository) },
                project: project,
                now: Date(timeIntervalSince1970: 1_000_000 + Double(day) * 60)
            )
        }
    }

    func testTheVocabularyHoldsEveryProjectsNamesAndConfirmedTermsButNoProposals() {
        let reach = LearnedTermProjectIdentity(key: "/w/reach", name: "reach")
        let hosted = LearnedTermProjectIdentity(key: "remote:reach", name: "reach")
        let site = LearnedTermProjectIdentity(key: "remote:website", name: "website")
        var memory = LearnedTerms()
        confirmed(["GlyphAtlasCache"], in: reach, &memory)
        confirmed(["PageComposer"], in: hosted, &memory)
        confirmed(["Astro"], in: site, &memory)
        memory.record(
            [LearnedTermObservation(term: "OnceOnly", source: .repository)], project: site,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        memory.recordProposal(["AgentGuess"], agent: .claude, project: site, now: Date(timeIntervalSince1970: 1_000_000))
        let projects = [
            QuickCaptureProject(
                key: "/w/reach", name: "reach", summary: nil, terms: [], userLine: nil,
                keys: ["/w/reach", "remote:reach"], repository: "o/reach-app"
            ),
            QuickCaptureProject(
                key: "remote:website", name: "website", summary: nil, terms: ["OnceOnly", "AgentGuess"], userLine: nil,
                repository: "o/Website"
            ),
        ]

        let terms = QuickCapturePolishVocabulary.terms(projects: projects, learned: memory)

        XCTAssertEqual(terms, ["reach", "reach-app", "website", "GlyphAtlasCache", "PageComposer", "Astro"])
    }

    func testTheVocabularyIsCappedPerProjectAndInTotal() {
        var memory = LearnedTerms()
        var projects: [QuickCaptureProject] = []
        for index in 0..<10 {
            let identity = LearnedTermProjectIdentity(key: "/w/p\(index)", name: "p\(index)")
            confirmed((0..<15).map { "Term\(index)x\($0)" }, in: identity, &memory)
            projects.append(QuickCaptureProject(key: identity.key, name: identity.name, summary: nil, terms: [], userLine: nil))
        }

        let terms = QuickCapturePolishVocabulary.terms(projects: projects, learned: memory)

        XCTAssertEqual(terms.count, QuickCapturePolishVocabulary.maxTerms)
        XCTAssertEqual(Array(terms.prefix(10)), (0..<10).map { "p\($0)" }, "every name before any term")
        XCTAssertEqual(terms.filter { $0.hasPrefix("Term0x") }.count, QuickCapturePolishVocabulary.maxTermsPerProject)
        XCTAssertEqual(Set(terms).count, terms.count)
    }

    // MARK: The request's vocabulary

    /// The owner's report: the matcher does not respell "local Voxroll"
    /// itself. It offers localvoxtral to the model as a candidate term, and
    /// the model decides.
    func testLocalVoxrollIsLeftToTheModelWithLocalvoxtralAsACandidate() {
        let prepared = QuickCapturePolishPrompt.prepare(
            transcript: raw, vocabulary: ["localvoxtral", "reach"], rendersDictionary: true
        )

        XCTAssertEqual(prepared.workingText, raw)
        XCTAssertEqual(
            prepared.dictionarySection,
            "\(RepoVocabularyMatcher.verificationCandidatesHeader)\n- localvoxtral"
        )
    }

    func testAnExactTermIsListedUnderTheLearnedHeaderAndATemplateWithoutTheSlotGetsNoSection() {
        let transcript = "fix the localvoxtral popover"
        let prepared = QuickCapturePolishPrompt.prepare(
            transcript: transcript, vocabulary: ["localvoxtral"], rendersDictionary: true
        )
        XCTAssertEqual(prepared.dictionarySection, "\(RepoVocabularyMatcher.learnedVocabularyHeader)\n- localvoxtral: localvoxtral")

        let noSlot = QuickCapturePolishPrompt.prepare(
            transcript: transcript, vocabulary: ["localvoxtral"], rendersDictionary: false
        )
        XCTAssertEqual(noSlot.workingText, transcript)
        XCTAssertEqual(noSlot.dictionarySection, "")
    }
}
