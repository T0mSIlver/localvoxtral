import Foundation
import XCTest
import localvoxtralCore
import localvoxtralTestSupport

/// A `~/.ssh/config` whose begin or end marker for this host lost its partner
/// (#1163): insert and remove refuse it and leave every byte alone. Before,
/// insert appended a second block below the orphan, and the next insert
/// replaced everything from the orphan to that block's end, the user's own
/// lines in between included.
final class ClaudeRemoteSSHConfigDamagedBlockTests: XCTestCase {
    private typealias Service = ClaudeRemoteEnrollmentService

    private let host = ClaudeRemoteHost(
        id: "habc1234",
        label: "buildhost",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: nil,
        revokedAt: nil
    )

    private func snippet(remoteForwardPort: UInt16 = 28_542) -> String {
        Service.sshConfigSnippet(
            host: host, sshHostAlias: "builder", listenerPort: 8473,
            remoteForwardPort: remoteForwardPort
        )
    }

    /// An enrolled block whose end marker was deleted by hand, with the
    /// user's own stanza after it.
    private var orphanedBegin: String {
        let block = snippet(remoteForwardPort: 28_000)
            .replacingOccurrences(of: "\n" + Service.blockEnd(hostID: host.id), with: "")
        return "Host github.com\n    User git\n\n" + block + "\nHost mine\n    User me\n"
    }

    /// An end marker left behind after its block was deleted by hand.
    private var orphanedEnd: String {
        "Host github.com\n    User git\n\n" + Service.blockEnd(hostID: host.id)
            + "\nHost mine\n    User me\n"
    }

    private var damagedConfigs: [(name: String, text: String)] {
        [("orphaned begin", orphanedBegin), ("orphaned end", orphanedEnd)]
    }

    private func service(config: String) -> (Service, MemorySSHConfigFileSystem) {
        let fileSystem = MemorySSHConfigFileSystem(state: ClaudeRemoteSSHConfigState(
            directoryExists: true,
            configData: Data(config.utf8),
            configPermissions: 0o600,
            directoryPermissions: 0o700
        ))
        return (Service(sshConfigFileSystem: fileSystem), fileSystem)
    }

    func testInsertionRefusesAnUnpairedMarkerWithoutWriting() throws {
        for (name, config) in damagedConfigs {
            let (service, fileSystem) = service(config: config)

            XCTAssertThrowsError(try service.insertSSHConfig(snippet: snippet(), hostID: host.id), name) {
                XCTAssertEqual($0 as? Service.ServiceError, .sshConfigBlockDamaged, name)
            }
            XCTAssertTrue(fileSystem.snapshot.writes.isEmpty, name)
            XCTAssertEqual(fileSystem.snapshot.state.configData, Data(config.utf8), name)
        }
    }

    func testRemovalRefusesAnUnpairedMarkerWithoutWriting() throws {
        for (name, config) in damagedConfigs {
            let (service, fileSystem) = service(config: config)

            XCTAssertThrowsError(try service.removeSSHConfig(hostID: host.id), name) {
                XCTAssertEqual($0 as? Service.ServiceError, .sshConfigBlockDamaged, name)
            }
            XCTAssertTrue(fileSystem.snapshot.writes.isEmpty, name)
            XCTAssertEqual(fileSystem.snapshot.state.configData, Data(config.utf8), name)
        }
    }

    /// The text functions agree with the writer: an unpaired marker comes
    /// back byte-identical, so no caller of them can append past it either.
    func testTheTextFunctionsLeaveAnUnpairedMarkerUnchanged() {
        for (name, config) in damagedConfigs {
            XCTAssertEqual(Service.applySSHConfigSnippet(to: config, snippet: snippet(), hostID: host.id), config, name)
            XCTAssertEqual(Service.removeSSHConfigSnippet(from: config, hostID: host.id), config, name)
            let crlf = config.replacingOccurrences(of: "\n", with: "\r\n")
            XCTAssertEqual(Service.applySSHConfigSnippet(to: crlf, snippet: snippet(), hostID: host.id), crlf, name)
        }
    }

    /// Damage is per host: another host's orphaned marker is that host's
    /// problem, and this host's paired block still updates as before.
    func testAnotherHostsUnpairedMarkerDoesNotBlockThisHost() throws {
        let otherBegin = Service.blockBegin(hostID: "hother999")
        let paired = Service.applySSHConfigSnippet(
            to: "Host github.com\n    User git\n\n\(otherBegin)\nHost mine\n    User me\n",
            snippet: snippet(remoteForwardPort: 28_000),
            hostID: host.id
        )
        let (service, fileSystem) = service(config: paired)

        try service.insertSSHConfig(snippet: snippet(), hostID: host.id)

        let written = String(decoding: try XCTUnwrap(fileSystem.snapshot.writes.last?.data), as: UTF8.self)
        XCTAssertEqual(written, paired.replacingOccurrences(of: "28000", with: "28542"))
    }
}
