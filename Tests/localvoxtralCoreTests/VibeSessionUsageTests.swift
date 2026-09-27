import Foundation
import XCTest

@testable import localvoxtralCore

/// A local Vibe run's usage, read from the session log it leaves in the
/// app's `VIBE_HOME` (#854).
final class VibeSessionUsageTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeSessionUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func output(sessionID: String) -> Data {
        Data(#"[{"sessionId":"\#(sessionID)","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}]}]"#.utf8)
    }

    func testTheNewestGenerationsCountsAreTheRuns() throws {
        let home = try temporaryDirectory()
        try AgentUsageFixtures.writeVibeSession(home: home)

        XCTAssertEqual(
            VibeSessionUsage.read(home: home, output: output(sessionID: AgentUsageFixtures.vibeSessionID)),
            AgentUsageFixtures.vibeUsage)
    }

    func testASessionIdThatIsNotOneDirectoryNameOrAMissingLogReadsNothing() throws {
        let home = try temporaryDirectory()
        try AgentUsageFixtures.writeVibeSession(home: home.appendingPathComponent("logs/session/unified/x"))
        XCTAssertNil(VibeSessionUsage.read(home: home, output: output(sessionID: "x/logs/session/unified/\(AgentUsageFixtures.vibeSessionID)")))
        XCTAssertNil(VibeSessionUsage.read(home: home, output: output(sessionID: "..")))
        XCTAssertNil(VibeSessionUsage.read(home: home, output: output(sessionID: "absent")))
        XCTAssertNil(VibeSessionUsage.read(home: home, output: Data("not json".utf8)))
    }

    /// The real runner: a fake `vibe` answers and leaves its log, and the
    /// answer comes back with the run's counts beside it.
    func testTheLocalRunnerReportsAVibeRunsCounts() async throws {
        let host = try AgentUsageFixtures.Host(
            agents: ["vibe": AgentUsageFixtures.fakeVibe(printing: String(decoding: Self.vibeTermsOutput, as: UTF8.self))],
            testCase: self)
        let runner = ProjectTermProposalProcessRunner(
            environment: ["HOME": host.home.path, "PATH": host.path],
            vibeHome: try temporaryDirectory().appendingPathComponent("vibe-home", isDirectory: true),
            userVibeDirectory: host.userVibe
        )

        let outcome = await runner.run(
            ProjectTermProposal.Invocation(agent: .vibe, workingDirectory: host.project.path, arguments: []))

        XCTAssertEqual(outcome, .terms(["Quillmark"], usage: AgentUsageFixtures.vibeUsage))
    }

    private static let vibeTermsOutput = Data(
        #"[{"sessionId":"92b6f11b-999e-d33a-2026-4a0a2150f620","type":"message","role":"assistant","content":[{"type":"text","text":"{\"terms\":[\"Quillmark\"]}"}]}]"#.utf8)
}
