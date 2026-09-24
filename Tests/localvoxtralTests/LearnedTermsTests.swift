import XCTest
@testable import localvoxtral

/// The rules of what the app remembers: one confirmation per dictation, per
/// project, decayed and capped. Pure value, no disk — `LearnedTermStoreTests`
/// owns the file.
final class LearnedTermsTests: XCTestCase {
    private let project = LearnedTermProjectResolver.Identity(
        key: "/Users/t/work/localvoxtral", name: "localvoxtral"
    )
    private let other = LearnedTermProjectResolver.Identity(
        key: "/Users/t/work/herdr", name: "herdr"
    )
    private let day = TimeInterval(86_400)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func observation(
        _ term: String, _ source: PolishContextSource = .repository
    ) -> LearnedTermObservation {
        LearnedTermObservation(term: term, source: source)
    }

    // MARK: - Counting

    /// One dictation is one confirmation, however many sources agreed on the
    /// term. Otherwise "seen in three dictations" would be reachable inside a
    /// single sentence and the threshold would mean nothing.
    func testTermResolvedBySeveralSourcesInOneDictationCountsOnce() {
        var terms = LearnedTerms()
        terms.record(
            [observation("Voxtral", .repository), observation("Voxtral", .terminal)],
            project: project,
            now: start
        )

        let stored = terms.confirmed(projectKey: project.key, minimumDictations: 1)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.dictations, 1)
        XCTAssertEqual(stored.first?.sources, ["repository", "terminal"])
    }

    func testRepeatedDictationsConfirmTheTerm() {
        var terms = LearnedTerms()
        for index in 0..<3 {
            terms.record(
                [observation("polishd")], project: project, now: start + Double(index) * day
            )
        }

        XCTAssertEqual(
            terms.confirmedTerms(projectKey: project.key), ["polishd"],
            "three dictations is the confirmation bar"
        )
        XCTAssertEqual(terms.confirmed(projectKey: project.key).first?.firstSeen, start)
        XCTAssertEqual(terms.confirmed(projectKey: project.key).first?.lastSeen, start + 2 * day)
    }

    func testTermBelowTheBarIsRememberedButNotConfirmed() {
        var terms = LearnedTerms()
        terms.record([observation("polishd")], project: project, now: start)
        terms.record([observation("polishd")], project: project, now: start + day)

        XCTAssertEqual(terms.termCount, 1)
        XCTAssertTrue(
            terms.confirmedTerms(projectKey: project.key).isEmpty,
            "twice can be the same mistake twice"
        )
    }

    /// Case and spacing variants are the same name: "SwiftUI" said three ways
    /// is three confirmations of one term, not three unconfirmed terms.
    func testSpellingVariantsFoldIntoOneTerm() {
        var terms = LearnedTerms()
        terms.record([observation("SwiftUI")], project: project, now: start)
        terms.record([observation("swiftui")], project: project, now: start + day)
        terms.record([observation("SWIFTUI")], project: project, now: start + 2 * day)

        XCTAssertEqual(
            terms.confirmedTerms(projectKey: project.key), ["SwiftUI"],
            "the first spelling seen is the one kept"
        )
    }

    // MARK: - Projects

    func testProjectsDoNotShareTerms() {
        var terms = LearnedTerms()
        for index in 0..<3 {
            terms.record([observation("Voxtral")], project: project, now: start + Double(index) * day)
            terms.record([observation("herdr pane")], project: other, now: start + Double(index) * day)
        }

        XCTAssertEqual(terms.confirmedTerms(projectKey: project.key), ["Voxtral"])
        XCTAssertEqual(terms.confirmedTerms(projectKey: other.key), ["herdr pane"])
    }

    /// The Settings pane offers terms for the ONE hand-written list, which is
    /// global: a name said in two projects outranks one said in a single repo.
    func testConfirmedEverywhereAddsUpTheSameNameAcrossProjects() {
        var terms = LearnedTerms()
        for index in 0..<3 {
            terms.record([observation("Qwen")], project: project, now: start + Double(index) * day)
            terms.record([observation("Qwen")], project: other, now: start + Double(index) * day)
            terms.record([observation("Ghostty")], project: project, now: start + Double(index) * day)
        }

        let ranked = terms.confirmedEverywhere()
        XCTAssertEqual(ranked.map(\.term), ["Qwen", "Ghostty"])
        XCTAssertEqual(ranked.first?.dictations, 6)
    }

    // MARK: - Decay and caps

    func testTermNotHeardWithinTheDecayWindowIsForgotten() {
        var terms = LearnedTerms()
        for index in 0..<3 {
            terms.record([observation("Voxtral")], project: project, now: start + Double(index) * day)
        }
        terms.record(
            [observation("Mistral")],
            project: project,
            // Three days past the window measured from Voxtral's LAST
            // sighting, not its first: the cutoff is relative to now.
            now: start + Double(LearnedTerms.staleAfterDays + 3) * day
        )

        XCTAssertEqual(
            terms.confirmed(projectKey: project.key, minimumDictations: 1).map(\.term),
            ["Mistral"]
        )
    }

    /// Decay also applies to a memory that is only being read back: a file
    /// left alone for a season must not ground today's dictation.
    func testPruneForgetsStaleTermsWithoutAWrite() {
        var terms = LearnedTerms()
        terms.record([observation("Voxtral")], project: project, now: start)
        terms.prune(now: start + Double(LearnedTerms.staleAfterDays + 1) * day)

        XCTAssertEqual(terms.termCount, 0)
        XCTAssertTrue(terms.projects.isEmpty, "a project with nothing left is not a project")
    }

    func testProjectKeepsItsStrongestTermsAtTheCap() {
        var terms = LearnedTerms()
        // One extra term over the cap, each seen once, plus one seen twice.
        let overflow = LearnedTerms.maxTermsPerProject + 1
        for index in 0..<overflow {
            terms.record([observation("term\(index)")], project: project, now: start)
        }
        terms.record([observation("term0")], project: project, now: start + day)

        XCTAssertEqual(terms.projects.first?.terms.count, LearnedTerms.maxTermsPerProject)
        XCTAssertTrue(
            terms.confirmed(projectKey: project.key, minimumDictations: 2).map(\.term)
                .contains("term0"),
            "the term with the most confirmations survives the cap"
        )
    }

    func testLeastRecentlyDictatedProjectIsEvictedAtTheCap() {
        var terms = LearnedTerms()
        for index in 0...LearnedTerms.maxProjects {
            terms.record(
                [observation("term")],
                project: LearnedTermProjectResolver.Identity(key: "/p\(index)", name: "p\(index)"),
                now: start + Double(index) * day
            )
        }

        XCTAssertEqual(terms.projects.count, LearnedTerms.maxProjects)
        XCTAssertFalse(
            terms.projects.contains { $0.key == "/p0" },
            "the oldest project goes first"
        )
    }

    // MARK: - Sanitizing

    func testUnusableSpellingsAreNotRemembered() {
        var terms = LearnedTerms()
        terms.record(
            [
                observation("  "),
                observation(String(repeating: "x", count: LearnedTerms.maxTermCharacters + 1)),
                observation("Claude   Code"),
            ],
            project: project,
            now: start
        )

        XCTAssertEqual(
            terms.confirmed(projectKey: project.key, minimumDictations: 1).map(\.term),
            ["Claude Code"]
        )
    }

    // MARK: - Hand corrections

    /// A fix the user made by hand is confirmed at once: the three-dictation
    /// bar guards against polish repeating a mistake, which a hand fix is not.
    func testCorrectionIsConfirmedAtOnce() {
        var terms = LearnedTerms()
        XCTAssertTrue(terms.recordCorrection("Qwen", project: project, now: start))

        XCTAssertEqual(terms.confirmedTerms(projectKey: project.key), ["Qwen"])
        XCTAssertEqual(terms.confirmedTerms(projectKey: other.key), [])
        let stored = terms.projects.first?.terms.first
        XCTAssertEqual(stored?.sources, [LearnedTerm.correctionSource])
        XCTAssertEqual(stored?.dictations, 1)
    }

    /// Correcting a spelling polish was still counting confirms it, keeps its
    /// history, and takes the user's spelling.
    func testCorrectionConfirmsATermPolishWasCounting() {
        var terms = LearnedTerms()
        terms.record([observation("qwen")], project: project, now: start)
        XCTAssertEqual(terms.confirmedTerms(projectKey: project.key), [])

        XCTAssertTrue(terms.recordCorrection("Qwen", project: project, now: start + day))
        let stored = terms.projects.first?.terms.first
        XCTAssertEqual(stored?.term, "Qwen")
        XCTAssertEqual(stored?.dictations, 2)
        XCTAssertEqual(stored?.sources, ["repository", LearnedTerm.correctionSource])
        XCTAssertEqual(terms.confirmedTerms(projectKey: project.key), ["Qwen"])
    }

    /// The same fix again is nothing new to tell the user.
    func testRepeatedCorrectionIsNotNews() {
        var terms = LearnedTerms()
        XCTAssertTrue(terms.recordCorrection("Qwen", project: project, now: start))
        XCTAssertFalse(terms.recordCorrection("qwen", project: project, now: start + day))
        XCTAssertEqual(terms.projects.first?.terms.count, 1)
    }

    /// Forget removes the term whatever its count, so three more dictations
    /// cannot quietly bring an undone term back.
    func testForgetRemovesTheTermWhateverTaughtIt() {
        var terms = LearnedTerms()
        for offset in 0..<3 {
            terms.record([observation("SessionStart")], project: project, now: start + Double(offset) * day)
        }
        terms.recordCorrection("Qwen", project: project, now: start)

        terms.forget("sessionstart", projectKey: project.key)
        terms.forget("Qwen", projectKey: other.key)
        XCTAssertEqual(terms.projects.first?.terms.map(\.term), ["Qwen"])

        terms.forget("Qwen", projectKey: project.key)
        XCTAssertTrue(terms.projects.isEmpty)
    }

    /// A hand-confirmed term outranks polish-learned ones, so the per-project
    /// cap never evicts it first.
    func testCorrectionOutranksCountedTerms() {
        var terms = LearnedTerms()
        for offset in 0..<5 {
            terms.record([observation("Voxtral")], project: project, now: start + Double(offset) * day)
        }
        terms.recordCorrection("Qwen", project: project, now: start)
        XCTAssertEqual(terms.confirmedTerms(projectKey: project.key), ["Qwen", "Voxtral"])
    }

    /// A file written before the flag existed still decodes, its terms not
    /// hand-confirmed.
    func testFileWithoutTheCorrectionFlagDecodes() throws {
        let json = """
        {"version":1,"projects":[{"key":"/r","name":"r","lastSeen":"2026-09-20T00:00:00Z",
        "terms":[{"term":"Voxtral","sources":["repository"],"dictations":1,
        "firstSeen":"2026-09-20T00:00:00Z","lastSeen":"2026-09-20T00:00:00Z"}]}]}
        """
        let terms = LearnedTermStore.terms(fromFileContents: Data(json.utf8))
        XCTAssertEqual(terms.termCount, 1)
        XCTAssertEqual(terms.projects.first?.terms.first?.isConfirmedByCorrection, false)
    }
}
