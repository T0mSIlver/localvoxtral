import XCTest
@testable import localvoxtral

/// What the per-term view shows and changes (#522): the applied counter, the
/// pin, and the sheet's order and wording. The rest of the memory's rules are
/// `LearnedTermsTests`'.
final class LearnedTermsViewTests: XCTestCase {
    private let project = LearnedTermProjectResolver.Identity(
        key: "/Users/t/work/localvoxtral", name: "localvoxtral"
    )
    private let day = TimeInterval(86_400)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ term: String,
        _ source: PolishContextSource = .repository,
        in terms: inout LearnedTerms,
        at now: Date,
        project: LearnedTermProjectResolver.Identity? = nil
    ) {
        terms.record(
            [LearnedTermObservation(term: term, source: source)],
            project: project ?? self.project,
            now: now
        )
    }

    private func stored(_ terms: LearnedTerms, _ term: String) -> LearnedTerm? {
        terms.projects.first { $0.key == project.key }?.terms.first { $0.term == term }
    }

    // MARK: - Applied

    func testOnlyTheMemoryApplyingATermCountsAsApplied() {
        var terms = LearnedTerms()
        for index in 0..<3 {
            record("Voxtral", in: &terms, at: start + Double(index) * day)
        }
        XCTAssertEqual(stored(terms, "Voxtral")?.appliedCount, 0, "a live source resolving it is not the memory")

        record("Voxtral", .learned, in: &terms, at: start + 5 * day)
        record("Voxtral", .learned, in: &terms, at: start + 6 * day)

        XCTAssertEqual(stored(terms, "Voxtral")?.appliedCount, 2)
        XCTAssertEqual(stored(terms, "Voxtral")?.lastApplied, start + 6 * day)
        XCTAssertEqual(stored(terms, "Voxtral")?.dictations, 5)
    }

    func testOneDictationAppliesATermOnce() {
        var terms = LearnedTerms()
        terms.record(
            [
                LearnedTermObservation(term: "Voxtral", source: .learned),
                LearnedTermObservation(term: "voxtral", source: .learned),
            ],
            project: project,
            now: start
        )
        XCTAssertEqual(stored(terms, "Voxtral")?.appliedCount, 1)
    }

    // MARK: - Pin

    func testPinnedTermIsConfirmedBelowTheBar() {
        var terms = LearnedTerms()
        record("Voxtral", in: &terms, at: start)
        XCTAssertTrue(terms.confirmedTerms(projectKey: project.key).isEmpty)

        XCTAssertTrue(terms.setPinned(true, term: "voxtral", projectKey: project.key))

        XCTAssertEqual(terms.confirmedTerms(projectKey: project.key), ["Voxtral"])
    }

    func testPinnedTermSurvivesDecay() {
        var terms = LearnedTerms()
        record("Voxtral", in: &terms, at: start)
        record("Mistral", in: &terms, at: start)
        terms.setPinned(true, term: "Voxtral", projectKey: project.key)

        terms.prune(now: start + Double(LearnedTerms.staleAfterDays + 1) * day)

        XCTAssertEqual(terms.projects.first?.terms.map(\.term), ["Voxtral"])
    }

    func testPinnedTermSurvivesTheTermCap() {
        var terms = LearnedTerms()
        record("pinned", in: &terms, at: start)
        terms.setPinned(true, term: "pinned", projectKey: project.key)
        for index in 0..<LearnedTerms.maxTermsPerProject {
            record("term\(index)", in: &terms, at: start + day)
            record("term\(index)", in: &terms, at: start + 2 * day)
        }

        XCTAssertEqual(terms.projects.first?.terms.count, LearnedTerms.maxTermsPerProject)
        XCTAssertNotNil(stored(terms, "pinned"), "stronger counts do not evict a pin")
    }

    func testProjectWithAPinIsEvictedLast() {
        var terms = LearnedTerms()
        record("Voxtral", in: &terms, at: start)
        terms.setPinned(true, term: "Voxtral", projectKey: project.key)
        for index in 0..<LearnedTerms.maxProjects {
            record(
                "term", in: &terms, at: start + Double(index + 1) * day,
                project: LearnedTermProjectResolver.Identity(key: "/p\(index)", name: "p\(index)")
            )
        }

        XCTAssertEqual(terms.projects.count, LearnedTerms.maxProjects)
        XCTAssertNotNil(stored(terms, "Voxtral"))
        XCTAssertFalse(terms.projects.contains { $0.key == "/p0" })
    }

    func testUnpinClearsTheFlagAndUnknownTermsAreRefused() {
        var terms = LearnedTerms()
        record("Voxtral", in: &terms, at: start)
        terms.setPinned(true, term: "Voxtral", projectKey: project.key)
        terms.setPinned(false, term: "Voxtral", projectKey: project.key)

        XCTAssertNil(stored(terms, "Voxtral")?.pinned, "an unpinned term encodes as it did before pins")
        XCTAssertFalse(terms.setPinned(true, term: "Mistral", projectKey: project.key))
        XCTAssertFalse(terms.setPinned(true, term: "Voxtral", projectKey: "/elsewhere"))
    }

    func testFileWithoutTheNewFieldsDecodes() throws {
        let json = """
        {"version":1,"projects":[{"key":"/r","name":"r","lastSeen":"2026-09-20T00:00:00Z",
        "terms":[{"term":"Voxtral","sources":["repository"],"dictations":3,
        "firstSeen":"2026-09-20T00:00:00Z","lastSeen":"2026-09-20T00:00:00Z"}]}]}
        """
        let term = LearnedTermStore.terms(fromFileContents: Data(json.utf8)).projects.first?.terms.first
        XCTAssertEqual(term?.appliedCount, 0)
        XCTAssertNil(term?.lastApplied)
        XCTAssertEqual(term?.isPinned, false)
    }

    func testStorePinsAndForgetsOneTerm() {
        let store = LearnedTermStore(fileURL: nil)
        store.record([LearnedTermObservation(term: "Voxtral", source: .repository)], project: project)
        store.record([LearnedTermObservation(term: "Mistral", source: .repository)], project: project)
        store.setPinned(true, term: "Voxtral", projectKey: project.key)
        store.forget("Mistral", projectKey: project.key)
        store.waitForPendingWrites()

        let terms = store.snapshot().projects.first?.terms
        XCTAssertEqual(terms?.map(\.term), ["Voxtral"])
        XCTAssertEqual(terms?.first?.isPinned, true)
    }

    // MARK: - Sheet

    func testSheetListsProjectsByRecencyWithTheSharedBucketLast() {
        var terms = LearnedTerms()
        record("Qwen", in: &terms, at: start + 9 * day, project: LearnedTermProjectResolver.shared)
        record("herdr", in: &terms, at: start, project: .init(key: "/h", name: "herdr"))
        record("Voxtral", in: &terms, at: start + day)

        XCTAssertEqual(
            LearnedTermsSheet.displayOrder(terms).map(\.name),
            ["localvoxtral", "herdr", LearnedTermProjectResolver.shared.name]
        )
    }

    func testSheetListsPinnedTermsFirst() {
        var terms = LearnedTerms()
        for index in 0..<3 {
            record("Voxtral", in: &terms, at: start + Double(index) * day)
        }
        record("Mistral", in: &terms, at: start)
        terms.setPinned(true, term: "Mistral", projectKey: project.key)

        XCTAssertEqual(LearnedTermsSheet.displayOrder(terms).first?.terms.map(\.term), ["Mistral", "Voxtral"])
    }

    func testSheetDetailLine() {
        func term(dictations: Int, applied: Int?, pinned: Bool? = nil) -> LearnedTerm {
            LearnedTerm(
                term: "Voxtral", sources: [], dictations: dictations, firstSeen: start, lastSeen: start,
                applied: applied, lastApplied: applied == nil ? nil : start, pinned: pinned
            )
        }
        XCTAssertEqual(
            LearnedTermsSheet.detailParts(for: term(dictations: 1, applied: nil)).text,
            "Learning: heard in 1 of 3 dictations"
        )
        XCTAssertEqual(LearnedTermsSheet.detailParts(for: term(dictations: 3, applied: nil)).text, "Not applied yet")
        XCTAssertEqual(
            LearnedTermsSheet.detailParts(for: term(dictations: 1, applied: nil, pinned: true)).text,
            "Not applied yet",
            "a pinned term is in use"
        )
        let once = LearnedTermsSheet.detailParts(for: term(dictations: 4, applied: 1))
        XCTAssertEqual(once.text, "Applied once,")
        XCTAssertEqual(once.lastApplied, start)
        XCTAssertEqual(LearnedTermsSheet.detailParts(for: term(dictations: 9, applied: 6)).text, "Applied 6 times, last")
    }

    /// #609: a proposal says which agent proposed it until use or a pin
    /// confirms it, then reads like any learned term.
    func testSheetDetailLineForAnAgentsProposal() {
        func proposal(_ agent: ProjectTermProposal.Agent, dictations: Int, pinned: Bool? = nil) -> LearnedTerm {
            LearnedTerm(
                term: "inkwell", sources: [agent.source], dictations: dictations,
                firstSeen: start, lastSeen: start, pinned: pinned
            )
        }
        XCTAssertEqual(
            LearnedTermsSheet.detailParts(for: proposal(.claude, dictations: 0)).text,
            "Proposed by Claude Code: heard in 0 of 3 dictations"
        )
        XCTAssertEqual(
            LearnedTermsSheet.detailParts(for: proposal(.vibe, dictations: 2)).text,
            "Proposed by Mistral Vibe: heard in 2 of 3 dictations"
        )
        XCTAssertEqual(LearnedTermsSheet.detailParts(for: proposal(.claude, dictations: 0, pinned: true)).text, "Not applied yet")
    }
}
