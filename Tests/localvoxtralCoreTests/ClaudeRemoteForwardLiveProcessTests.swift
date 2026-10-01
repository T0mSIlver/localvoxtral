import Foundation
import XCTest
@testable import localvoxtralCore

final class ClaudeRemoteForwardLiveProcessTests: XCTestCase {
    /// The supervisor matches ssh's stderr against an English line (#1011),
    /// so the child runs in the C locale whatever the app's locale is. A
    /// shell stands in for ssh and reports the locale it was given.
    func testChildRunsInTheCLocale() async throws {
        let process = try ClaudeRemoteForwardLiveProcess(
            argv: ["ssh", "-c", "echo \"LC_ALL=$LC_ALL\" >&2"],
            sshExecutableURL: URL(fileURLWithPath: "/bin/sh")
        )
        var lines: [String] = []
        for await line in process.standardErrorLines { lines.append(line) }
        _ = await process.waitUntilExit()
        XCTAssertEqual(lines, ["LC_ALL=C"])
    }

    /// A chunk the readability handler has read when ssh exits still reaches
    /// the stream (#1086). The hooks hold the handler between its read and
    /// its ingest until `finish` has closed the stream; a `finish` that waits
    /// for the handler instead never gets there, so the hold ends at the
    /// bound and the handler ingests first.
    func testChunkReadDuringExitReachesTheStream() async throws {
        let handlerRead = DispatchSemaphore(value: 0)
        let streamFinished = DispatchSemaphore(value: 0)
        let process = try ClaudeRemoteForwardLiveProcess(
            argv: ["ssh", "-c", "echo 'remote port forwarding failed' >&2"],
            sshExecutableURL: URL(fileURLWithPath: "/bin/sh"),
            hooks: .init(
                afterHandlerRead: {
                    handlerRead.signal()
                    _ = streamFinished.wait(timeout: .now() + .milliseconds(500))
                },
                willFinish: { _ = handlerRead.wait(timeout: .now() + .seconds(10)) },
                didFinishStream: { streamFinished.signal() }
            )
        )
        var lines: [String] = []
        for await line in process.standardErrorLines { lines.append(line) }
        _ = await process.waitUntilExit()
        XCTAssertEqual(lines, ["remote port forwarding failed"])
    }
}
