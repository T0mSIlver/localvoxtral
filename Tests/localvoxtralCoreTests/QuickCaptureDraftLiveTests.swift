import Foundation
import XCTest
import Synchronization

@testable import localvoxtralCore

/// Drafts issues for labelled captures through the production drafter and
/// runner (#731), one markdown file per capture for the owner to grade.
/// Spends real agent tokens, so it runs only through
/// `scripts/linux/quick-capture-drafts.sh`, on Linux.
///
/// `QC_CAPTURES` holds `{"id", "expected", "text"}` lines, `QC_PROJECTS`
/// the replay's project list, `QC_IDS` the capture ids to draft (comma
/// separated), `QC_AGENT` `claude`, `vibe` or `opencode`, `QC_OUT` the
/// output directory.
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
            case nil:
                file += "No check due\n"
            }
            try file.write(to: out.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
        }
    }
}

/// #918's two stages on real backends, for the PR's proof: the polishing
/// model's first draft, then the agent's check of an issue, each timed and
/// costed. Spends tokens, so it runs only through
/// `scripts/linux/quick-capture-two-stage.sh`, on Linux.
///
/// `QC_ROOT` is the checkout, `QC_CAPTURES` a JSON list of captures,
/// `QC_ENDPOINT`, `QC_MODEL` and `QC_KEY_FILE` the first draft's
/// chat/completions endpoint, model and key, `QC_OUT` the output directory.
final class QuickCaptureTwoStageLiveTests: XCTestCase {
    func testTwoStageDrafts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LV_QUICK_CAPTURE_TWO_STAGE"] == "1" else {
            throw XCTSkip("spends tokens: run through scripts/linux/quick-capture-two-stage.sh")
        }
        let root = try XCTUnwrap(environment["QC_ROOT"])
        let out = URL(fileURLWithPath: try XCTUnwrap(environment["QC_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let captures = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(environment["QC_CAPTURES"])))
        )
        let key = try String(contentsOfFile: try XCTUnwrap(environment["QC_KEY_FILE"]), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = try XCTUnwrap(environment["QC_MODEL"])
        let child = environment.filter { ["HOME", "PATH", "LANG"].contains($0.key) }
        let usage = UsageLedger(fileURL: nil)
        let github = QuickCaptureGHClient(environment: child)
        let firstDrafter = QuickCaptureFirstDrafter(
            endpoint: URL(string: try XCTUnwrap(environment["QC_ENDPOINT"]))!,
            apiKey: key, model: model, extraBody: ["reasoning_effort": "low"],
            usageBackend: .mistral, usageRecorder: usage
        )
        let home = FileManager.default.homeDirectoryForCurrentUser
        let drafter = QuickCaptureDrafter(
            runner: QuickCaptureDraftProcessRunner(
                environment: child,
                vibeHome: out.appendingPathComponent("vibe-home"),
                userVibeDirectory: home.appendingPathComponent(".vibe")
            ),
            openIssues: { await github.openIssues(ofCheckout: $0, repository: $1) },
            context: { root, repository, capture in
                await QuickCaptureContextGatherer(
                    run: QuickCaptureContextGatherer.processRun(environment: child),
                    openIssues: { await github.openIssues(ofCheckout: $0, repository: $1) },
                    checkoutRepository: { await github.repository(ofCheckout: $0) }
                ).gather(root: root, repository: repository, capture: capture)
            },
            firstDrafter: firstDrafter,
            usageRecorder: usage
        )
        let project = QuickCaptureProject(key: root, name: "localvoxtral", summary: nil, terms: [], userLine: nil)
        for (index, capture) in captures.enumerated() {
            let started = Date()
            let firstAt = Mutex<Date?>(nil)
            let first = Mutex<QuickCaptureDraft.Outcome?>(nil)
            let before = usage.entries().count
            let final = await drafter.draft(
                capture: capture, route: .project(root), projects: [project], agents: [.claude],
                onFirstDraft: { outcome in
                    firstAt.withLock { $0 = Date() }
                    first.withLock { $0 = outcome }
                    return true
                }
            )
            let entries = Array(usage.entries().dropFirst(before))
            let firstSeconds = firstAt.withLock { $0 }.map { $0.timeIntervalSince(started) } ?? 0
            let totalSeconds = Date().timeIntervalSince(started)
            let chat = entries.first { $0.backend == .mistral }
            let agent = entries.first { $0.backend == .claudeCode }
            var file = "# Capture \(index + 1)\n\n> \(capture)\n\n"
            var line = String(format: "QC two-stage %d: first %.0f s", index + 1, firstSeconds)
            line += " (\(chat?.promptTokens ?? 0) in, \(chat?.completionTokens ?? 0) out, EUR \(String(format: "%.4f", chat?.costEUR ?? 0)))"
            switch first.withLock({ $0 }) {
            case .draft(let draft, _)?:
                line += " kind=\(draft.kind.rawValue) title=\(draft.title)"
                file += "## First draft (\(draft.kind.rawValue), \(Int(firstSeconds)) s)\n\n### \(draft.title)\n\n\(draft.body)\n\n"
            case let other:
                line += " first=\(String(describing: other))"
            }
            switch final {
            case .draft(let draft, let runUsage)?:
                line += String(format: " | check %.0f s, $%.3f, %d files, title=%@", totalSeconds - firstSeconds,
                               agent?.agentCostUSD ?? runUsage?.costUSD ?? 0, draft.filesRead?.count ?? 0, draft.title)
                file += "## Checked (\(Int(totalSeconds - firstSeconds)) s)\n\n### \(draft.title)\n\n\(draft.body)\n\n"
                file += "Files read: \((draft.filesRead ?? []).joined(separator: ", "))\n"
            case nil:
                line += " | no check"
            case let other?:
                line += " | check \(other)"
            }
            print(line)
            try file.write(to: out.appendingPathComponent("capture-\(index + 1).md"), atomically: true, encoding: .utf8)
        }
    }
}
