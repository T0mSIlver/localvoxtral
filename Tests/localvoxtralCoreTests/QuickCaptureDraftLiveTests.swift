import Foundation
import XCTest

@testable import localvoxtralCore

/// Drafts issues for labelled captures through the production drafter and
/// runner (#731), one markdown file per capture for the owner to grade.
/// Spends real agent tokens, so it runs only through
/// `scripts/linux/quick-capture-drafts.sh`, on Linux.
///
/// `QC_CAPTURES` holds `{"id", "expected", "text"}` lines, `QC_PROJECTS`
/// the replay's project list, `QC_IDS` the capture ids to draft (comma
/// separated), `QC_AGENT` `claude` or `vibe`, `QC_OUT` the output directory.
/// Each capture is drafted in the project it was labelled with, so the
/// grade measures the draft, not the routing.
final class QuickCaptureDraftLiveTests: XCTestCase {
    private struct Capture: Decodable {
        let id: String
        let expected: String
        let text: String
    }

    private struct ProjectEntry: Decodable {
        let key: String
        let name: String
    }

    func testDrafts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LV_QUICK_CAPTURE_DRAFTS"] == "1" else {
            throw XCTSkip("spends tokens: run through scripts/linux/quick-capture-drafts.sh")
        }
        let ids = try XCTUnwrap(environment["QC_IDS"]).split(separator: ",").map(String.init)
        let agent = try XCTUnwrap(environment["QC_AGENT"].flatMap(ProjectTermProposal.Agent.init(rawValue:)))
        let out = URL(fileURLWithPath: try XCTUnwrap(environment["QC_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let captures = try String(contentsOfFile: try XCTUnwrap(environment["QC_CAPTURES"]), encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Capture.self, from: Data($0.utf8)) }
        let projects = try JSONDecoder().decode(
            [ProjectEntry].self,
            from: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(environment["QC_PROJECTS"])))
        ).map { QuickCaptureProject(key: $0.key, name: $0.name, summary: nil, terms: [], userLine: nil) }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let drafter = QuickCaptureDrafter(
            runner: QuickCaptureDraftProcessRunner(
                environment: environment.filter { ["HOME", "PATH", "LANG"].contains($0.key) },
                vibeHome: out.appendingPathComponent("vibe-home"),
                userVibeDirectory: home.appendingPathComponent(".vibe")
            ),
            openIssues: QuickCaptureDrafter.ghOpenIssues(
                environment: environment.filter { ["HOME", "PATH", "LANG"].contains($0.key) }
            )
        )
        for id in ids {
            let capture = try XCTUnwrap(captures.first { $0.id == id }, id)
            let project = try XCTUnwrap(projects.first { $0.name == capture.expected }, capture.expected)
            let started = Date()
            let outcome = await drafter.draft(
                capture: capture.text, route: .project(project.key), projects: projects, agents: [agent]
            )
            let seconds = Int(Date().timeIntervalSince(started))
            var file = "# \(id) → \(project.name)\n\nCapture:\n\n> \(capture.text)\n\n"
            switch outcome {
            case .draft(let draft, let usage):
                let related = draft.issue.map { " #\($0)" } ?? ""
                file += "Run: \(agent.rawValue), \(seconds) s, \(usage?.summary ?? "usage not reported"), relation \(draft.relation.rawValue)\(related)\n\n"
                file += "## \(draft.title)\n\n\(draft.body)\n"
                print("QC draft \(id) \(project.name) ok \(seconds)s \(usage?.summary ?? "-") relation=\(draft.relation.rawValue)\(related) title=\(draft.title)")
            case .failed(let failure):
                file += "Run: \(agent.rawValue), \(seconds) s, FAILED \(failure)\n"
                print("QC draft \(id) \(project.name) FAILED \(failure) \(seconds)s")
            case .notRun(let reason):
                file += "Not run: \(reason)\n"
                print("QC draft \(id) \(project.name) NOT RUN \(reason)")
            }
            try file.write(to: out.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
    }
}
