import Foundation
import XCTest
import localvoxtralCore
import localvoxtralTestSupport

/// A `~/.ssh/config` with CRLF line endings (#678): the writer must find its
/// block there, or every apply appends another `Host` stanza.
final class ClaudeRemoteSSHConfigCRLFTests: XCTestCase {
    private let host = ClaudeRemoteHost(
        id: "habc1234",
        label: "buildhost",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: nil,
        revokedAt: nil
    )

    private func snippet(remoteForwardPort: UInt16) -> String {
        ClaudeRemoteEnrollmentService.sshConfigSnippet(
            host: host, sshHostAlias: "builder", listenerPort: 8473,
            remoteForwardPort: remoteForwardPort
        )
    }

    private let userLines = "Host github.com\n    User git\n"

    /// The config an earlier enrollment left, saved back by an editor set to
    /// CRLF.
    private func enrolledCRLFConfig(remoteForwardPort: UInt16) -> String {
        (userLines + "\n" + snippet(remoteForwardPort: remoteForwardPort) + "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private func service(config: String) -> (ClaudeRemoteEnrollmentService, MemorySSHConfigFileSystem) {
        let fileSystem = MemorySSHConfigFileSystem(state: ClaudeRemoteSSHConfigState(
            directoryExists: true,
            configData: Data(config.utf8),
            configPermissions: 0o600,
            directoryPermissions: 0o700
        ))
        return (ClaudeRemoteEnrollmentService(sshConfigFileSystem: fileSystem), fileSystem)
    }

    private func writtenConfig(_ fileSystem: MemorySSHConfigFileSystem) throws -> String {
        let data = try XCTUnwrap(fileSystem.snapshot.writes.last?.data)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testReenrollingReplacesTheBlockInACRLFConfig() throws {
        let (service, fileSystem) = service(config: enrolledCRLFConfig(remoteForwardPort: 28_000))

        try service.insertSSHConfig(snippet: snippet(remoteForwardPort: 28_542), hostID: host.id)

        let written = try writtenConfig(fileSystem)
        XCTAssertEqual(written.components(separatedBy: "Host builder").count - 1, 1, written)
        XCTAssertEqual(written, enrolledCRLFConfig(remoteForwardPort: 28_542))
    }

    func testApplyingTheSameBlockToACRLFConfigIsANoOp() {
        let config = enrolledCRLFConfig(remoteForwardPort: 28_542)
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
                to: config, snippet: snippet(remoteForwardPort: 28_542), hostID: host.id
            ),
            config
        )
    }

    func testAFirstEnrollmentAppendsWithTheConfigsOwnTerminator() {
        let crlfUserLines = userLines.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(
            ClaudeRemoteEnrollmentService.applySSHConfigSnippet(
                to: crlfUserLines, snippet: snippet(remoteForwardPort: 28_542), hostID: host.id
            ),
            enrolledCRLFConfig(remoteForwardPort: 28_542)
        )
    }

    func testRemovingTheBlockFromACRLFConfigLeavesTheUsersLines() throws {
        let (service, fileSystem) = service(config: enrolledCRLFConfig(remoteForwardPort: 28_542))

        try service.removeSSHConfig(hostID: host.id)

        XCTAssertEqual(
            try writtenConfig(fileSystem),
            (userLines + "\n").replacingOccurrences(of: "\n", with: "\r\n")
        )
    }

    func testTheReadersSeeTheBlockInACRLFConfig() {
        let (service, _) = service(config: enrolledCRLFConfig(remoteForwardPort: 28_542))

        XCTAssertEqual(service.sshConfigForwardState(hostID: host.id), .forwards(28_542))
        XCTAssertEqual(
            service.sshConfigBlockIsCurrent(snippet: snippet(remoteForwardPort: 28_542), hostID: host.id),
            true
        )
    }
}
