import Foundation
import Synchronization
import XCTest
import localvoxtralCore

/// Another program saves `~/.ssh/config` while the app is updating it: an
/// editor, or a second running copy of the app. The app's write must keep
/// that save, or refuse and say so; it must never rename its older snapshot
/// over it.
final class ClaudeRemoteSSHConfigConcurrentEditTests: XCTestCase {
    private typealias Service = ClaudeRemoteEnrollmentService

    /// The live file system on a temporary home, with an "editor" that saves
    /// the config right after the service reads it, `saves` times.
    private final class EditorSavingFileSystem: ClaudeRemoteSSHConfigFileSystem {
        let live: LiveClaudeRemoteSSHConfigFileSystem
        let configURL: URL
        let savesLeft: Mutex<Int>

        init(live: LiveClaudeRemoteSSHConfigFileSystem, configURL: URL, saves: Int) {
            self.live = live
            self.configURL = configURL
            savesLeft = Mutex(saves)
        }

        func readState() throws -> ClaudeRemoteSSHConfigState {
            let state = try live.readState()
            let save = savesLeft.withLock { left -> Bool in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
            if save {
                let current = try String(contentsOf: configURL, encoding: .utf8)
                try (current + "Host editor\(UUID().uuidString.prefix(8))\n    User me\n")
                    .write(to: configURL, atomically: false, encoding: .utf8)
            }
            return state
        }

        func createSSHDirectory(permissions: UInt16) throws {
            try live.createSSHDirectory(permissions: permissions)
        }

        func atomicWriteConfig(_ data: Data, permissions: UInt16, replacing expected: Data?) throws {
            try live.atomicWriteConfig(data, permissions: permissions, replacing: expected)
        }

        func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
            try live.withExclusiveAccess(body)
        }
    }

    private let host = ClaudeRemoteHost(
        id: "habc1234",
        label: "buildhost",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: nil,
        revokedAt: nil
    )

    private var snippet: String {
        Service.sshConfigSnippet(
            host: host, sshHostAlias: "builder", listenerPort: 8473, remoteForwardPort: 28_542
        )
    }

    private var home: URL!
    private var configURL: URL { home.appendingPathComponent(".ssh/config") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-ssh-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".ssh"),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try "Host github.com\n    User git\n".write(to: configURL, atomically: false, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func service(editorSaves: Int) -> Service {
        Service(sshConfigFileSystem: EditorSavingFileSystem(
            live: LiveClaudeRemoteSSHConfigFileSystem(homeDirectoryURL: home),
            configURL: configURL,
            saves: editorSaves
        ))
    }

    func testSSHConfigInsertionPreservesConcurrentEdit() throws {
        try service(editorSaves: 1).insertSSHConfig(snippet: snippet, hostID: host.id)

        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("Host editor"), "the editor's save was lost:\n\(written)")
        XCTAssertTrue(written.contains("Host builder"), written)
        XCTAssertTrue(written.hasPrefix("Host github.com\n    User git\n"), written)
    }

    /// An editor that saves after every read: the app gives up rather than
    /// write over it, and the file is what the editor left.
    func testSSHConfigInsertionRefusesAConfigThatKeepsChanging() throws {
        let service = service(editorSaves: Service.sshConfigWriteAttempts)

        XCTAssertThrowsError(try service.insertSSHConfig(snippet: snippet, hostID: host.id)) {
            XCTAssertEqual($0 as? Service.ServiceError, .sshConfigChangedDuringWrite)
        }
        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(written.components(separatedBy: "Host editor").count - 1, Service.sshConfigWriteAttempts)
        XCTAssertFalse(written.contains("Host builder"), written)
    }
}
