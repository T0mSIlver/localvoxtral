import Foundation
import XCTest
@testable import localvoxtral

#if canImport(Darwin)
import Darwin

// MARK: - Socket directory preconditions

final class ClaudeSocketGuardValidationTests: XCTestCase {
    private let uid: UInt32 = 501

    private func metadata(
        isDirectory: Bool = true,
        isSymlink: Bool = false,
        ownerUID: UInt32 = 501,
        mode: UInt16 = 0o700
    ) -> ClaudeSocketGuard.PathMetadata {
        ClaudeSocketGuard.PathMetadata(
            isDirectory: isDirectory, isSymlink: isSymlink, ownerUID: ownerUID, mode: mode
        )
    }

    private func validate(_ metadata: ClaudeSocketGuard.PathMetadata) -> ClaudeSocketGuard.PreconditionFailure? {
        ClaudeSocketGuard.validateDirectory(metadata, path: "/run/dir", expectedUID: uid)
    }

    func testAcceptsPrivateDirectoryOwnedByUs() {
        XCTAssertNil(validate(metadata()))
    }

    func testRejectsSymlink() {
        // A symlink could redirect the socket into a directory an attacker
        // controls, and it is checked FIRST because lstat is the only way to
        // see it at all.
        XCTAssertEqual(validate(metadata(isSymlink: true)), .isSymlink("/run/dir"))
    }

    func testSymlinkIsRejectedEvenWhenItLooksLikeAValidDirectory() {
        XCTAssertEqual(
            validate(metadata(isDirectory: true, isSymlink: true, ownerUID: uid, mode: 0o700)),
            .isSymlink("/run/dir")
        )
    }

    func testRejectsNonDirectory() {
        XCTAssertEqual(validate(metadata(isDirectory: false)), .notADirectory("/run/dir"))
    }

    func testRejectsForeignOwner() {
        // Another user owning the directory means they could swap in their own
        // socket — and we would then label their records .localAuthenticated.
        XCTAssertEqual(
            validate(metadata(ownerUID: 0)),
            .wrongOwner(path: "/run/dir", owner: 0, expected: uid)
        )
    }

    func testRejectsGroupWritableDirectory() {
        XCTAssertEqual(validate(metadata(mode: 0o770)), .permissive(path: "/run/dir", mode: 0o770))
    }

    func testRejectsWorldReadableDirectory() {
        XCTAssertEqual(validate(metadata(mode: 0o755)), .permissive(path: "/run/dir", mode: 0o755))
    }

    func testRejectsAnyGroupOrOtherBit() {
        for mode: UInt16 in [0o701, 0o702, 0o704, 0o710, 0o720, 0o740] {
            XCTAssertEqual(
                validate(metadata(mode: mode)),
                .permissive(path: "/run/dir", mode: mode),
                "mode \(String(mode, radix: 8)) must be rejected"
            )
        }
    }

    func testAcceptsMoreRestrictiveThan0700() {
        XCTAssertNil(validate(metadata(mode: 0o500)))
    }
}

// MARK: - Real filesystem behaviour

final class ClaudeSocketGuardFilesystemTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testPrepareCreatesPrivateDirectory() throws {
        let path = root.appendingPathComponent("run").path
        try ClaudeSocketGuard.prepareDirectory(at: path)
        let metadata = try XCTUnwrap(ClaudeSocketGuard.metadata(ofPath: path))
        XCTAssertTrue(metadata.isDirectory)
        XCTAssertFalse(metadata.isSocket)
        XCTAssertEqual(metadata.mode, 0o700)
        XCTAssertEqual(metadata.ownerUID, UInt32(geteuid()))
    }

    func testPrepareIsIdempotent() throws {
        let path = root.appendingPathComponent("run").path
        try ClaudeSocketGuard.prepareDirectory(at: path)
        XCTAssertNoThrow(try ClaudeSocketGuard.prepareDirectory(at: path))
    }

    func testPrepareRefusesPermissiveExistingDirectoryRatherThanRepairingIt() throws {
        // Deliberately NOT chmod-ing it back: a directory that is not ours or
        // not private is a situation to report, not to paper over.
        let path = root.appendingPathComponent("loose").path
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o777))]
        )
        XCTAssertThrowsError(try ClaudeSocketGuard.prepareDirectory(at: path)) { error in
            guard case .permissive(_, let mode)? = error as? ClaudeSocketGuard.PreconditionFailure else {
                return XCTFail("expected .permissive, got \(error)")
            }
            XCTAssertEqual(mode, 0o777)
        }
        // Still permissive: we reported, we did not mutate.
        XCTAssertEqual(ClaudeSocketGuard.metadata(ofPath: path)?.mode, 0o777)
    }

    func testPrepareRejectsSymlinkedDirectory() throws {
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try ClaudeSocketGuard.prepareDirectory(at: link.path)) { error in
            XCTAssertEqual(
                error as? ClaudeSocketGuard.PreconditionFailure, .isSymlink(link.path)
            )
        }
    }

    func testPrepareReportsAFoundationErrorCodeNotAStaleErrno() throws {
        // `errno` after a FileManager call is whatever its LAST internal
        // syscall left behind — routinely 0 on a path that plainly failed.
        // Creating under a non-directory is a guaranteed failure, so a nonzero,
        // meaningful code proves we read NSError rather than errno.
        let file = root.appendingPathComponent("blocker")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let unreachable = file.appendingPathComponent("child/run").path

        XCTAssertThrowsError(try ClaudeSocketGuard.prepareDirectory(at: unreachable)) { error in
            guard case .cannotCreate(_, let code)? = error as? ClaudeSocketGuard.PreconditionFailure else {
                return XCTFail("expected .cannotCreate, got \(error)")
            }
            XCTAssertNotEqual(code, 0, "a stale errno would report 0 here")
        }
    }

    func testPrepareRejectsExistingFileAtDirectoryPath() throws {
        let path = root.appendingPathComponent("afile").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
        XCTAssertThrowsError(try ClaudeSocketGuard.prepareDirectory(at: path)) { error in
            XCTAssertEqual(error as? ClaudeSocketGuard.PreconditionFailure, .notADirectory(path))
        }
    }

    func testMetadataDoesNotFollowSymlinks() throws {
        let target = root.appendingPathComponent("t")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("l")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let metadata = try XCTUnwrap(ClaudeSocketGuard.metadata(ofPath: link.path))
        XCTAssertTrue(metadata.isSymlink, "lstat, not stat")
        XCTAssertFalse(metadata.isDirectory)
    }

    func testMetadataOfMissingPathIsNil() {
        XCTAssertNil(ClaudeSocketGuard.metadata(ofPath: root.appendingPathComponent("nope").path))
    }
}

#endif
