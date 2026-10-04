import XCTest
@testable import localvoxtral

/// The line the user writes about a project (#811) reaches the quick capture
/// router's option for that project, and survives a relaunch.
@MainActor
final class QuickCaptureProjectLinesTests: XCTestCase {
    func testAStoredLineReachesTheRoutersOptionAfterARelaunch() throws {
        let defaults = makeSettingsDefaults()
        makeSettings(defaults: defaults)
            .setQuickCaptureProjectLine("Dictation app; shortcuts, quick capture, Inbox. ", for: "/nonexistent/demo")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickCaptureProjectLinesTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let learned = LearnedTerms(projects: [
            LearnedTermProject(key: "/nonexistent/demo", name: "demo", terms: [], lastSeen: now),
            LearnedTermProject(key: "/nonexistent/other", name: "other", terms: [], lastSeen: now),
        ])
        let inbox = QuickCaptureInboxViewModel(
            settings: makeSettings(defaults: defaults),
            learnedTerms: { learned },
            fileURL: nil,
            applicationSupport: directory
        )

        let options = QuickCaptureRouting.options(for: inbox.model.projectChoices)
        XCTAssertEqual(
            options.first { $0.projectKey == "/nonexistent/demo" }?.description,
            "Project demo. Dictation app; shortcuts, quick capture, Inbox."
        )
        XCTAssertEqual(options.first { $0.projectKey == "/nonexistent/other" }?.description, "Project other.")
    }

    /// Two copies launched before either wrote: each one's line survives the
    /// other's save, and a blank line removes only its own project (#1773).
    func testTwoCopiesPreserveDescriptionsForDifferentProjects() {
        let defaults = makeSettingsDefaults()
        let first = makeSettings(defaults: defaults)
        let second = makeSettings(defaults: defaults)

        first.setQuickCaptureProjectLine("Dictation app", for: "/w/a")
        second.setQuickCaptureProjectLine("Database tools", for: "/w/b")
        XCTAssertEqual(
            makeSettings(defaults: defaults).quickCaptureProjectLines,
            ["/w/a": "Dictation app", "/w/b": "Database tools"])

        first.setQuickCaptureProjectLine(" ", for: "/w/a")
        XCTAssertEqual(makeSettings(defaults: defaults).quickCaptureProjectLines, ["/w/b": "Database tools"])
    }

    func testALineIsCutToWhatTheRouterReadsAndABlankOneIsRemoved() {
        let settings = makeSettings()
        settings.setQuickCaptureProjectLine(String(repeating: "a", count: 250), for: "/w/demo")
        XCTAssertEqual(settings.quickCaptureProjectLines["/w/demo"]?.count, QuickCaptureProjects.maxUserLineCharacters)

        settings.setQuickCaptureProjectLine("  \n", for: "/w/demo")
        XCTAssertEqual(settings.quickCaptureProjectLines, [:])
    }
}
