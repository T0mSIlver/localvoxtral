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

    /// A session in a linked worktree outside its main checkout is in no
    /// group by its directory alone; its git root and main checkout put it
    /// in the checkout's (#1155).
    func testASessionInAWorktreeOutsideItsCheckoutReadsTheCheckoutsGroupFromItsRoot() async {
        let learned = learned()
        let workspace = joined("/w/acme-feature/Sources")
        XCTAssertNil(learned.group(ofJoinedWorkspace: workspace))
        let root = LearnedTermProjectResolver.RepositoryRoot.root("/w/acme-feature", mainCheckout: "/w/acme")
        XCTAssertEqual(learned.group(ofJoinedWorkspace: workspace, repositoryRoot: root), .work)

        var snapshot = ClaudeSessionSnapshot(
            sessionID: "s1", origin: .localAuthenticated(peerUID: 501), agent: .claude, firstSeen: now)
        snapshot.workspace = workspace
        var join = ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: 4242, bundleID: "com.apple.Terminal"),
            snapshot: snapshot, windowID: 101, mechanism: .ttyDevice)
        XCTAssertNil(learned.group(ofJoin: join))
        join.repositoryRoot = root
        XCTAssertEqual(learned.group(ofJoin: join), .work)
    }

    /// A checkout linked to its repository after the user picked a group
    /// reads it from the repository's record, and the reverse.
    func testAGroupReachesEveryCheckoutOfItsRepository() async {
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/acme", name: "acme", terms: [term("Kubrix")], lastSeen: now),
        ])
        XCTAssertTrue(learned.recordOriginRepository("acme-corp/acme", projectKey: "/w/acme"))
        let row = ListedProjects.projects(from: learned, now: now)
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
