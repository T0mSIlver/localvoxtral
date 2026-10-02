import Foundation
import XCTest

@testable import localvoxtralCore

final class QuickCaptureProjectsTests: XCTestCase {
    func testTheSummaryIsTheFirstTwoProseParagraphs() {
        let cases: [(String, String?)] = [
            (
                """
                ---
                title: x
                ---
                <p align="center"><img src="logo.png"></p>

                # localvoxtral

                [![CI](https://x/badge.svg)](https://x) ![License](https://y)
                <!-- a
                comment -->
                A **native** macOS menu bar app for realtime dictation with
                [Voxtral](https://mistral.ai), `speechd` and polish.

                Second paragraph.
                """,
                "A native macOS menu bar app for realtime dictation with Voxtral, speechd and polish. Second paragraph."
            ),
            ("# Title\n\n```sh\nmake\n```\n\nBuilds it.", "Builds it."),
            ("One.\n\nTwo.\n\nThree.", "One. Two."),
            ("# Title\n\n- a list\n- only\n\n| a | b |", nil),
            ("Plain first line\nwraps here\n\nnext", "Plain first line wraps here next"),
            ("Speak.&nbsp;\n\nTom &amp; Jerry.", "Speak. Tom & Jerry."),
            ("Speak.\n\nhttps://github.com/user-attachments/assets/81a3\n\nThen type.", "Speak. Then type."),
        ]
        for (readme, expected) in cases {
            XCTAssertEqual(QuickCaptureProjects.summary(ofReadme: readme), expected, readme)
        }
    }

    func testProjectsComeFromTheLearnedTermsWithTheirOwnDescriptions() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func term(_ spelling: String, dictations: Int, source: String = "screen") -> LearnedTerm {
            LearnedTerm(term: spelling, sources: [source], dictations: dictations, firstSeen: now, lastSeen: now)
        }
        var website = LearnedTermProject(key: "remote:website", name: "website", terms: [term("Astro", dictations: 3)], lastSeen: now)
        website.reportedAt = now
        website.reportedAsRepository = true
        let learned = LearnedTerms(projects: [
            website,
            LearnedTermProject(
                key: "/w/localvoxtral", name: "localvoxtral",
                terms: [term("speechd", dictations: 0, source: "agent:claude"), term("Voxtral", dictations: 5), term("rare", dictations: 1)],
                lastSeen: now.addingTimeInterval(60)
            ),
        ])
        var readmeReads: [String] = []
        let projects = QuickCaptureProjects.projects(
            from: learned,
            userLines: ["remote:website": "  My portfolio site.  ", "/w/localvoxtral": " "],
            now: now,
            readme: { root in
                readmeReads.append(root)
                return "# x\n\nDictation for coding agents."
            }
        )
        XCTAssertEqual(readmeReads, ["/w/localvoxtral"], "a remote project's files are not on this Mac")
        XCTAssertEqual(projects.map(\.key), ["/w/localvoxtral", "remote:website"], "most recent first")
        XCTAssertEqual(projects[0].terms, ["Voxtral", "speechd"], "confirmed, then proposals; unconfirmed polish terms stay out")
        XCTAssertEqual(projects[0].userLine, nil)
        XCTAssertEqual(
            projects[0].description,
            "Project localvoxtral. Dictation for coding agents. Its names: Voxtral, speechd."
        )
        XCTAssertEqual(projects[1].description, "Project website. My portfolio site. Its names: Astro.")
    }

    /// #819: a remote project no hook has named since hosts began sending
    /// `X-Lvx-Env-Project` is a label no session reports any more.
    func testARemoteProjectIsListedOnlyOnceAHookHasNamedIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 86_400
        let term = LearnedTerm(term: "ScreenPipe", sources: ["screen"], dictations: 3, firstSeen: now, lastSeen: now)
        var learned = LearnedTerms(projects: [
            LearnedTermProject(key: "remote:modest-lewin-c92780", name: "modest-lewin-c92780", terms: [term], lastSeen: now),
            LearnedTermProject(key: "remote:quill-fix", name: "quill-fix", terms: [term], lastSeen: now),
            LearnedTermProject(key: "/w/inkwell", name: "inkwell", terms: [term], lastSeen: now),
            LearnedTermProject(key: LearnedTermProjectResolver.shared.key, name: "No project", terms: [term], lastSeen: now),
        ])
        learned.recordRemoteReport(project: .init(key: "remote:quillmark", name: "quillmark"), asRepository: true, now: now)
        learned.recordRemoteReport(project: .init(key: "remote:quill-fix", name: "quill-fix"), asRepository: false, now: now)
        func listed(at moment: Date) -> [String] {
            QuickCaptureProjects.projects(from: learned, userLines: [:], now: moment, readme: { _ in nil })
                .map(\.key).sorted()
        }
        XCTAssertEqual(listed(at: now), ["/w/inkwell", "remote:quill-fix", "remote:quillmark"])
        XCTAssertEqual(
            listed(at: now.addingTimeInterval(Double(LearnedTerms.remoteLabelListedDays) * day)),
            ["/w/inkwell", "remote:quillmark"],
            "an old shim's cwd label drops out a week after its last hook; a repository stays"
        )
    }

    /// #891: the agent's sentence is the description when the user wrote
    /// none, and a remote project whose host sent its README is listed:
    /// only a shim that names the repository sends one.
    func testTheAgentsSentenceDescribesAProjectUntilTheUserWritesOne() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var quill = LearnedTermProject(key: "remote:quillmark", name: "quillmark", terms: [], lastSeen: now)
        quill.summary = "Quillmark renders Markdown to PDF."
        quill.summaryAt = now
        var learned = LearnedTerms(projects: [quill])
        func only(_ lines: [String: String] = [:]) -> QuickCaptureProject? {
            QuickCaptureProjects.projects(from: learned, userLines: lines, now: now, readme: { _ in nil }).first
        }
        XCTAssertEqual(only()?.key, "remote:quillmark", "no hook stamp, but its host sent the README")
        XCTAssertEqual(only()?.automaticLine, "Quillmark renders Markdown to PDF.")
        XCTAssertEqual(only()?.description, "Project quillmark. Quillmark renders Markdown to PDF.")

        learned.recordProposal(
            [], line: "Markdown to PDF renderer: the qmk CLI, page sizes, fonts.", agent: .claude,
            project: .init(key: "remote:quillmark", name: "quillmark"), now: now
        )
        XCTAssertEqual(only()?.automaticLine, "Markdown to PDF renderer: the qmk CLI, page sizes, fonts.")
        XCTAssertEqual(
            only()?.description,
            "Project quillmark. Markdown to PDF renderer: the qmk CLI, page sizes, fonts. Quillmark renders Markdown to PDF."
        )
        XCTAssertEqual(
            only(["remote:quillmark": "My PDF tool."])?.description,
            "Project quillmark. My PDF tool. Quillmark renders Markdown to PDF.",
            "the user's line replaces the agent's"
        )
    }

    func testTheReadmeIsReadFromTheCheckoutRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc-readme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(QuickCaptureProjects.readme(atRoot: root.path))
        try "Hello".write(to: root.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        XCTAssertEqual(QuickCaptureProjects.readme(atRoot: root.path), "Hello")
    }

    /// A checkout's README symlinked to a private file outside it is not
    /// read: its text would reach the router's model.
    func testASymlinkedReadmeIsNotRead() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("qc-readme-link-\(UUID().uuidString)")
        let root = base.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let secret = base.appendingPathComponent("secret.txt")
        try "OUTSIDE-SENTINEL".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("README.md").path, withDestinationPath: secret.path
        )
        XCTAssertNil(QuickCaptureProjects.readme(atRoot: root.path))
        try "Hello".write(to: root.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        XCTAssertEqual(QuickCaptureProjects.readme(atRoot: root.path), "Hello", "the next name that is a regular file")
    }
}
