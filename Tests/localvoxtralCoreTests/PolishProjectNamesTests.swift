import Foundation
import XCTest

@testable import localvoxtralCore

/// #1024: every polish carries the user's project names.
final class PolishProjectNamesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testNamesAreEachListedProjectAndItsRepositorySortedWithoutToolLabels() {
        let term = LearnedTerm(term: "Voxtral", sources: ["screen"], dictations: 3, firstSeen: now, lastSeen: now)
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/w/supervoxtral", name: "supervoxtral", terms: [term], lastSeen: now),
            LearnedTermProject(key: "/w/Vidtheque", name: "Vidtheque", terms: [term], lastSeen: now.addingTimeInterval(60)),
            LearnedTermProject(key: "remote:pi-setup", name: "pi-setup", terms: [term], lastSeen: now),
            LearnedTermProject(key: "remote:modest-lewin-c92780", name: "modest-lewin-c92780", terms: [term], lastSeen: now),
            LearnedTermProject(
                key: "remote:agent-add526d17c28bb610", name: "agent-add526d17c28bb610", terms: [term], lastSeen: now),
        ])
        learned.projects[0].repository = "T0mSIlver/localvoxtral"
        for label in ["pi-setup", "modest-lewin-c92780", "agent-add526d17c28bb610"] {
            learned.recordRemoteReport(project: .init(key: "remote:" + label, name: label), asRepository: false, now: now)
        }
        learned.recordRemoteReport(project: .init(key: "remote:working-set", name: "working-set"), asRepository: true, now: now)
        learned.recordRemoteReport(project: .init(key: "remote:vidtheque", name: "vidtheque"), asRepository: true, now: now)

        XCTAssertEqual(
            PolishProjectNames.names(from: learned, now: now),
            ["localvoxtral", "pi-setup", "supervoxtral", "Vidtheque", "working-set"],
            "a checkout and its repository both; one spelling per name; no worktree or agent hash labels"
        )
    }

    func testTheProjectLineFollowsTheTermsAndSkipsNamesTheTermsHold() {
        let templates = LLMPromptTemplates(systemContent: "SYSTEM", userContent: "{{input_text}}")
        XCTAssertEqual(
            templates.withSpeakerProfile("", terms: ["Qwen", "Working Set"], projects: ["herdr", "working-set"])
                .systemContent,
            "SYSTEM\n\n\(LLMPromptTemplates.speakerProfileHeader)\n"
                + "Names and terms they use: Qwen, Working Set\n"
                + "Their projects (repository names): herdr\n"
        )
        XCTAssertEqual(
            templates.withSpeakerProfile("", projects: ["herdr"]).systemContent,
            "SYSTEM\n\n\(LLMPromptTemplates.speakerProfileHeader)\nTheir projects (repository names): herdr\n",
            "project names alone bring the header"
        )
    }

    func testGlobalTermsThatRepeatAProjectNameAreTheOnesOfferedForRemoval() {
        XCTAssertEqual(
            PolishProjectNames.globalTerms(
                ["Qwen", "working set", "CodexBar", "Codex"], repeating: ["codexbar", "working-set", "localvoxtral"]),
            ["working set", "CodexBar"]
        )
    }
}
