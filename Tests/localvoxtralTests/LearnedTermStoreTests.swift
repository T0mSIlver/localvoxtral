import XCTest
@testable import localvoxtral

/// The file around `LearnedTerms`: what survives a relaunch, what a damaged
/// file costs, and what Forget forgets.
final class LearnedTermStoreTests: XCTestCase {
    private let project = LearnedTermProjectResolver.Identity(
        key: "/Users/t/work/localvoxtral", name: "localvoxtral"
    )
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("learned-terms-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("learned-terms.json")
    }

    private func observations(_ terms: String...) -> [LearnedTermObservation] {
        terms.map { LearnedTermObservation(term: $0, source: .repository) }
    }

    func testRecordedTermsSurviveARelaunch() throws {
        let fileURL = try makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        for _ in 0..<3 {
            store.record(observations("Voxtral"), project: project)
        }
        store.waitForPendingWrites()

        let reopened = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        XCTAssertEqual(reopened.confirmedTerms(projectKey: project.key), ["Voxtral"])
        XCTAssertEqual(reopened.summary().terms, 1)
        XCTAssertEqual(reopened.summary().projects, 1)
    }

    /// Nothing resolved, nothing written: the common case is a sentence the
    /// recognizer got right, and it must not cost a file write.
    func testRecordingNothingWritesNoFile() throws {
        let fileURL = try makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.record([], project: project)
        store.waitForPendingWrites()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testForgetAllClearsTheFileAndTheMemory() throws {
        let fileURL = try makeFileURL()
        let store = LearnedTermStore(fileURL: fileURL, now: { Self.start })
        store.record(observations("Voxtral"), project: project)
        store.waitForPendingWrites()

        store.forgetAll()
        store.waitForPendingWrites()

        XCTAssertEqual(store.summary().terms, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "forgotten terms must not come back after a relaunch"
        )
    }

    /// A torn write or a hand edit starts over empty rather than refusing to
    /// start: losing what was learned costs a few dictations, refusing costs
    /// the feature.
    func testDamagedFileReadsAsEmpty() {
        XCTAssertEqual(LearnedTermStore.terms(fromFileContents: Data("{ not json".utf8)).termCount, 0)
    }

    /// A file written by a later build is not guessed at.
    func testFileFromTheFutureIsDiscarded() throws {
        let future = LearnedTerms(
            version: LearnedTerms.currentVersion + 1,
            projects: [
                LearnedTermProject(
                    key: project.key,
                    name: project.name,
                    terms: [
                        LearnedTerm(
                            term: "Voxtral", sources: ["repository"], dictations: 9,
                            firstSeen: Self.start, lastSeen: Self.start
                        )
                    ],
                    lastSeen: Self.start
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(future)

        XCTAssertEqual(LearnedTermStore.terms(fromFileContents: data).termCount, 0)
    }

    /// The store is also the read side of the feature, so what it hands back
    /// has to be the confirmed set, not everything it has ever seen.
    func testUnconfirmedTermsAreNotHandedOut() throws {
        let store = LearnedTermStore(fileURL: nil, now: { Self.start })
        store.record(observations("Voxtral", "polishd"), project: project)
        store.record(observations("Voxtral"), project: project)

        XCTAssertTrue(store.confirmedTerms(projectKey: project.key).isEmpty)
        XCTAssertEqual(store.confirmedTerms(projectKey: project.key, minimumDictations: 2), ["Voxtral"])
    }
}
