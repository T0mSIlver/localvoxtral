import ClaudeContextWire
import Foundation
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// #1005: a Work project's names never reach a dictation joined to a
/// Personal project, and the reverse; with no join, every project is read.
@MainActor
final class ProjectGroupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-groups-\(UUID().uuidString)")
            .appendingPathComponent("quick-captures.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func term(_ spelling: String) -> LearnedTerm {
        LearnedTerm(term: spelling, sources: ["screen"], dictations: 3, firstSeen: now, lastSeen: now)
    }

    /// A Work checkout (`/w/acme`, term Kubrix), a Personal one
    /// (`/p/garden`, term Florabel), one in no group (`/x/scratch`, term
    /// Scribbit) and the shared bucket (Sharedterm).
    private func learned() -> LearnedTerms {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/acme", name: "acme", terms: [term("Kubrix")], lastSeen: now),
            LearnedTermProject(key: "/p/garden", name: "garden", terms: [term("Florabel")], lastSeen: now),
            LearnedTermProject(key: "/x/scratch", name: "scratch", terms: [term("Scribbit")], lastSeen: now),
            LearnedTermProject(
                key: LearnedTermProjectResolver.shared.key, name: "No project", terms: [term("Sharedterm")],
                lastSeen: now),
        ])
        learned.setGroup(.work, keys: ["/w/acme"])
        learned.setGroup(.personal, keys: ["/p/garden"])
        return learned
    }

    private func joined(_ path: String) -> ClaudeWorkspaceReference? {
        .make(rawCwd: path, origin: .localAuthenticated(peerUID: 501))
    }

    // MARK: Polish grounding

    func testPolishProjectNamesAndConfirmedTermsStayInTheJoinedGroup() async {
        let learned = learned()
        let work = learned.group(ofJoinedWorkspace: joined("/w/acme/Sources"))
        let personal = learned.group(ofJoinedWorkspace: joined("/p/garden"))
        XCTAssertEqual(work, .work, "a session below the checkout's root is in its group")
        XCTAssertEqual(personal, .personal)

        XCTAssertEqual(PolishProjectNames.names(from: learned.inGroup(work), now: now), ["acme"])
        XCTAssertEqual(PolishProjectNames.names(from: learned.inGroup(personal), now: now), ["garden"])
        XCTAssertEqual(learned.inGroup(work).confirmedEverywhere().map(\.term), ["Kubrix"])
        XCTAssertEqual(learned.inGroup(personal).confirmedEverywhere().map(\.term), ["Florabel"])
    }

    func testWithNoJoinOrAnUngroupedJoinEveryProjectIsRead() async {
        let learned = learned()
        for group in [learned.group(ofJoinedWorkspace: nil), learned.group(ofJoinedWorkspace: joined("/x/scratch"))] {
            XCTAssertNil(group)
            XCTAssertEqual(
                PolishProjectNames.names(from: learned.inGroup(group), now: now), ["acme", "garden", "scratch"])
            XCTAssertEqual(
                Set(learned.inGroup(group).confirmedEverywhere().map(\.term)),
                ["Kubrix", "Florabel", "Scribbit", "Sharedterm"])
        }
    }

    /// A checkout linked to its repository after the user picked a group
    /// reads it from the repository's record, and the reverse.
    func testAGroupReachesEveryCheckoutOfItsRepository() async {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/acme", name: "acme", terms: [term("Kubrix")], lastSeen: now),
        ])
        XCTAssertTrue(learned.recordOriginRepository("acme-corp/acme", projectKey: "/w/acme"))
        let row = QuickCaptureProjects.projects(from: learned, userLines: [:], now: now, readme: { _ in nil })
        XCTAssertEqual(row.count, 1)
        learned.setGroup(.work, keys: row[0].keys)

        learned.projects.append(LearnedTermProject(key: "/w/acme-clone", name: "acme-clone", terms: [], lastSeen: now))
        XCTAssertTrue(learned.recordOriginRepository("acme-corp/acme", projectKey: "/w/acme-clone"))

        XCTAssertEqual(learned.group(ofJoinedWorkspace: joined("/w/acme-clone")), .work)
        XCTAssertEqual(learned.inGroup(.work).confirmedEverywhere().map(\.term), ["Kubrix"])
        XCTAssertEqual(learned.inGroup(.personal).confirmedEverywhere(), [])
    }

    /// The project cap never evicts a grouped project: its next dictation
    /// would come back in no group, and its names would reach the other
    /// group's dictations again.
    func testTheProjectCapKeepsAGroupedProject() async {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/acme", name: "acme", terms: [term("Kubrix")], lastSeen: now),
        ])
        learned.setGroup(.work, keys: ["/w/acme"])
        for index in 0..<LearnedTerms.maxProjects {
            learned.record(
                [LearnedTermObservation(term: "Term\(index)", source: .repository)],
                project: .init(key: "/x/project\(index)", name: "project\(index)"),
                now: now.addingTimeInterval(Double(index + 1) * 60))
        }
        XCTAssertEqual(learned.group(ofProjectKey: "/w/acme"), .work)
    }

    // MARK: Quick capture

    private func captureModel(
        _ learned: LearnedTerms, classifier: ScriptedQuickCaptureClassifier, polisher: FakeQuickCapturePolisher
    ) -> QuickCaptureInboxModel {
        let projects = QuickCaptureProjects.projects(from: learned, userLines: [:], now: now, readme: { _ in nil })
        return QuickCaptureFixture.model(
            fileURL: fileURL, answer: [:], github: FakeQuickCaptureGitHub(), runner: FakeQuickCaptureDraftRunner(),
            projects: projects, classifier: classifier, polisher: polisher,
            polishVocabulary: { QuickCapturePolishVocabulary.terms(projects: $0, learned: learned) },
            now: { [now] in now }
        )
    }

    func testAQuickCaptureIsPolishedAndRoutedWithinItsGroup() async throws {
        let learned = learned()
        for (group, mine, theirs) in [
            (ProjectGroup.work, ["acme", "Kubrix"], ["garden", "Florabel", "scratch", "Scribbit"]),
            (.personal, ["garden", "Florabel"], ["acme", "Kubrix", "scratch", "Scribbit"]),
        ] {
            let classifier = ScriptedQuickCaptureClassifier([[:]])
            let polisher = FakeQuickCapturePolisher { $0 }
            let model = captureModel(learned, classifier: classifier, polisher: polisher)

            await model.capture(text: "fix the login page", historyRecordID: nil, group: group).value

            let vocabulary = try XCTUnwrap(polisher.calls.first?.vocabulary)
            let options = classifier.calls.withLock { $0 }.flatMap { $0 }
            let routedTo = options.compactMap(\.projectKey)
            let sent = vocabulary.joined(separator: " ") + " " + options.map(\.description).joined(separator: " ")
            XCTAssertEqual(Set(vocabulary), Set(mine), "\(group.rawValue) polish")
            XCTAssertEqual(routedTo.count, 1, "\(group.rawValue) routing offers its one project")
            for name in theirs {
                XCTAssertFalse(sent.contains(name), "\(name) reached a \(group.rawValue) capture")
            }
            XCTAssertEqual(model.items.first?.group, group)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func testAQuickCaptureWithNoJoinIsPolishedAndRoutedAmongEveryProject() async throws {
        let classifier = ScriptedQuickCaptureClassifier([[:]])
        let polisher = FakeQuickCapturePolisher { $0 }
        let model = captureModel(learned(), classifier: classifier, polisher: polisher)

        await model.capture(text: "fix the login page", historyRecordID: nil).value

        XCTAssertEqual(
            Set(try XCTUnwrap(polisher.calls.first?.vocabulary)),
            ["acme", "Kubrix", "garden", "Florabel", "scratch", "Scribbit"])
        XCTAssertEqual(
            Set(classifier.calls.withLock { $0 }.flatMap { $0 }.compactMap(\.projectKey)),
            ["/w/acme", "/p/garden", "/x/scratch"])
    }

    /// "Also" joins the latest open capture of its own group, never one
    /// from the other group.
    func testAFollowUpJoinsOnlyACaptureOfItsGroup() async throws {
        let classifier = ScriptedQuickCaptureClassifier([["acme": 0.95], ["garden": 0.95], ["garden": 0.95]])
        let model = captureModel(learned(), classifier: classifier, polisher: FakeQuickCapturePolisher { $0 })

        await model.capture(text: "Add a dark mode", historyRecordID: nil, group: .work).value
        await model.capture(text: "Water the tomatoes", historyRecordID: nil, group: .personal).value
        await model.capture(text: "also the settings window", historyRecordID: nil, group: .work).value

        let work = try XCTUnwrap(model.items.first { $0.text == "Add a dark mode" })
        let personal = try XCTUnwrap(model.items.first { $0.text == "Water the tomatoes" })
        XCTAssertEqual(work.followUps?.map(\.text), ["also the settings window"])
        XCTAssertNil(personal.followUps)
    }

    // MARK: The store

    /// The choice is in `learned-terms.json`: it outlives a relaunch and
    /// another running copy's write (#990).
    func testTheGroupSurvivesARelaunchAndAnotherCopysWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-groups-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("learned-terms.json")
        let project = LearnedTermProjectResolver.Identity(key: "/w/acme", name: "acme")
        let installed = LearnedTermStore(fileURL: url, now: { [now] in now })
        let tryBuild = LearnedTermStore(fileURL: url, now: { [now] in now })
        installed.waitForPendingWrites()
        tryBuild.waitForPendingWrites()

        installed.recordCorrection("Kubrix", project: project)
        installed.waitForPendingWrites()
        installed.setGroup(.work, keys: [project.key])
        installed.waitForPendingWrites()
        tryBuild.recordCorrection("Gizmo", project: project)
        tryBuild.waitForPendingWrites()

        let reopened = LearnedTermStore(fileURL: url, now: { [now] in now })
        reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.snapshot().group(ofProjectKey: project.key), .work)
        XCTAssertEqual(Set(reopened.confirmedTerms(projectKey: project.key)), ["Kubrix", "Gizmo"])

        reopened.setGroup(nil, keys: [project.key])
        reopened.waitForPendingWrites()
        let cleared = LearnedTermStore(fileURL: url, now: { [now] in now })
        cleared.waitForPendingWrites()
        XCTAssertNil(cleared.snapshot().group(ofProjectKey: project.key))
    }

    /// A group a later build adds decodes, so this build keeps the file.
    func testAGroupThisBuildDoesNotKnowStillDecodes() async throws {
        var learned = learned()
        learned.setGroup(ProjectGroup(rawValue: "school"), keys: ["/x/scratch"])
        let decoded = try JSONDecoder().decode(LearnedTerms.self, from: JSONEncoder().encode(learned))
        XCTAssertEqual(decoded.group(ofProjectKey: "/x/scratch")?.rawValue, "school")
        XCTAssertEqual(decoded.group(ofProjectKey: "/w/acme"), .work)
    }
}
