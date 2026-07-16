import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// In-memory store, so the registry's contract is testable without a disk — and
/// so a test can inspect the exact bytes that WOULD be written, which is how the
/// "no plaintext ever lands" assertion is made at all.
private final class MemoryStoreIO: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])

    func read(from url: URL) throws -> Data? {
        contents.withLock { $0[url.path] }
    }

    func write(_ data: Data, to url: URL) throws {
        contents.withLock { $0[url.path] = data }
    }

    func seed(_ data: Data, at url: URL) {
        contents.withLock { $0[url.path] = data }
    }

    func written(at url: URL) -> Data? {
        contents.withLock { $0[url.path] }
    }
}

final class ClaudeRemoteHostRegistryTests: XCTestCase {
    private var io: MemoryStoreIO!
    private let fileURL = URL(fileURLWithPath: "/tmp/lvx-test/claude-remote-hosts.json")
    private let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))

    override func setUp() {
        super.setUp()
        io = MemoryStoreIO()
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_000_000) }
    }

    private func makeRegistry(
        tokens: [String] = [],
        hostIDs: [String] = []
    ) throws -> ClaudeRemoteHostRegistry {
        let tokenQueue = Mutex(tokens)
        let idQueue = Mutex(hostIDs)
        return try ClaudeRemoteHostRegistry(
            fileURL: fileURL,
            io: io,
            now: { [clock] in clock.withLock { $0 } },
            makeToken: {
                tokenQueue.withLock { queue in
                    queue.isEmpty ? ClaudeRemoteTokenDigest.makeToken() : queue.removeFirst()
                }
            },
            makeHostID: {
                idQueue.withLock { queue in
                    queue.isEmpty ? ClaudeRemoteTokenDigest.makeHostID() : queue.removeFirst()
                }
            }
        )
    }

    private func advance(_ seconds: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    // MARK: Enrollment

    func testEnrollIssuesAWorkingTokenAndPersistsTheHost() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")

        XCTAssertEqual(enrollment.host.label, "buildhost")
        XCTAssertNil(enrollment.host.revokedAt)
        XCTAssertEqual(enrollment.host.createdAt, clock.withLock { $0 })
        XCTAssertTrue(ClaudeRemoteTokenDigest.isWellFormed(enrollment.token))
        XCTAssertEqual(registry.authenticate(token: enrollment.token)?.id, enrollment.host.id)
        XCTAssertTrue(registry.hasActiveHosts)
        XCTAssertNotNil(io.written(at: fileURL), "enrollment must survive a relaunch")
    }

    func testEnrolledHostsSurviveAReload() throws {
        let first = try makeRegistry()
        let enrollment = try first.enroll(label: "buildhost")

        // A fresh registry over the same store: the relaunch case.
        let second = try makeRegistry()
        XCTAssertEqual(second.hosts().map(\.id), [enrollment.host.id])
        XCTAssertEqual(second.authenticate(token: enrollment.token)?.id, enrollment.host.id)
    }

    func testLabelIsSanitized() throws {
        let registry = try makeRegistry()
        // Anything that could act is dropped, not escaped. There is no host
        // alias that legitimately contains a newline or a backtick.
        let enrollment = try registry.enroll(label: "build`whoami`\u{1B}[31m host\n")
        XCTAssertEqual(enrollment.host.label, "buildwhoami31m host")
    }

    func testAnEmptyLabelIsRejected() throws {
        let registry = try makeRegistry()
        XCTAssertThrowsError(try registry.enroll(label: "  \u{1B}  ")) { error in
            XCTAssertEqual(error as? ClaudeRemoteHostRegistry.StoreError, .invalidLabel)
        }
    }

    func testEnrollmentIsCapped() throws {
        let registry = try makeRegistry()
        for index in 0..<ClaudeRemoteHostRegistry.maxHosts {
            _ = try registry.enroll(label: "host\(index)")
        }
        XCTAssertThrowsError(try registry.enroll(label: "one-too-many")) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteHostRegistry.StoreError,
                .tooManyHosts(limit: ClaudeRemoteHostRegistry.maxHosts)
            )
        }
    }

    func testHostIDCollisionsAreRetriedNotIssued() throws {
        // Two hosts sharing an id would share a session namespace — one host's
        // context would land in the other's sessions.
        let registry = try makeRegistry(hostIDs: ["hdeadbeef", "hdeadbeef", "hcafe0000"])
        let first = try registry.enroll(label: "a")
        let second = try registry.enroll(label: "b")
        XCTAssertEqual(first.host.id, "hdeadbeef")
        XCTAssertEqual(second.host.id, "hcafe0000")
    }

    // MARK: Secrets

    /// The single most important assertion in this file.
    func testThePlaintextTokenIsNeverWrittenToTheStore() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")

        let data = try XCTUnwrap(io.written(at: fileURL))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(enrollment.token), "the plaintext token must never be persisted")
        // Nor any prefix long enough to matter: a truncated token in a file is
        // still a head start on the rest of it.
        XCTAssertFalse(text.contains(enrollment.token.prefix(12)))
        // What IS there is a hash.
        XCTAssertTrue(text.contains("tokenHash"))
        XCTAssertTrue(text.contains("tokenSalt"))
    }

    func testThePublicHostViewExposesNoSecretMaterial() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")
        // The public type is what a UI, a log line, and a diagnostics export all
        // see. Reflection over it is the check that no secret property was added
        // later by someone who only meant to make debugging easier.
        let properties = Mirror(reflecting: enrollment.host).children.compactMap(\.label)
        XCTAssertEqual(Set(properties), ["id", "label", "createdAt", "lastSeenAt", "revokedAt"])
        let described = String(describing: enrollment.host)
        XCTAssertFalse(described.contains(enrollment.token))
    }

    func testStoredHashIsSaltedSoIdenticalTokensDoNotShareAHash() throws {
        // The salt is not itself a secret; it is here so one precomputed table
        // cannot be reused across hosts or across users.
        let registry = try makeRegistry(tokens: ["tokenAAAAAAAAAAAAAAA", "saltone", "tokenAAAAAAAAAAAAAAA", "salttwo"])
        _ = try registry.enroll(label: "a")
        _ = try registry.enroll(label: "b")
        let text = String(decoding: try XCTUnwrap(io.written(at: fileURL)), as: UTF8.self)
        let hashOne = ClaudeRemoteTokenDigest.hash(token: "tokenAAAAAAAAAAAAAAA", salt: "saltone")
        let hashTwo = ClaudeRemoteTokenDigest.hash(token: "tokenAAAAAAAAAAAAAAA", salt: "salttwo")
        XCTAssertNotEqual(hashOne, hashTwo)
        XCTAssertTrue(text.contains(hashOne))
        XCTAssertTrue(text.contains(hashTwo))
    }

    // MARK: Authentication

    func testAnUnknownTokenAuthenticatesNothing() throws {
        let registry = try makeRegistry()
        _ = try registry.enroll(label: "buildhost")
        XCTAssertNil(registry.authenticate(token: ClaudeRemoteTokenDigest.makeToken()))
    }

    func testMalformedTokensAreRejectedWithoutHashing() throws {
        let registry = try makeRegistry()
        _ = try registry.enroll(label: "buildhost")
        for token in [
            "",
            "short",
            "${CLAUDE_PLUGIN_OPTION_TOKEN}",
            "has spaces in it here",
            "has/slashes/in/it/here",
            String(repeating: "a", count: 200),
        ] {
            XCTAssertNil(registry.authenticate(token: token), "'\(token)' must not authenticate")
        }
    }

    func testEachHostAuthenticatesOnlyItsOwnToken() throws {
        let registry = try makeRegistry()
        let first = try registry.enroll(label: "alpha")
        let second = try registry.enroll(label: "beta")
        XCTAssertEqual(registry.authenticate(token: first.token)?.id, first.host.id)
        XCTAssertEqual(registry.authenticate(token: second.token)?.id, second.host.id)
        XCTAssertNotEqual(first.host.id, second.host.id)
    }

    // MARK: Revocation and rotation

    func testRevocationTakesEffectImmediately() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")
        XCTAssertNotNil(registry.authenticate(token: enrollment.token))

        advance(60)
        try registry.revoke(hostID: enrollment.host.id)

        XCTAssertNil(registry.authenticate(token: enrollment.token), "revocation is the real off switch")
        XCTAssertFalse(registry.hasActiveHosts, "a revoked host must not keep the port open")
        // The entry stays, so the user can see it existed and rotate it back.
        let host = try XCTUnwrap(registry.host(id: enrollment.host.id))
        XCTAssertEqual(host.revokedAt, clock.withLock { $0 })
        XCTAssertTrue(host.isRevoked)
    }

    func testRevocationErasesTheStoredHash() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")
        let hashBefore = String(decoding: try XCTUnwrap(io.written(at: fileURL)), as: UTF8.self)
        XCTAssertTrue(hashBefore.contains("tokenHash"))

        try registry.revoke(hostID: enrollment.host.id)
        let after = String(decoding: try XCTUnwrap(io.written(at: fileURL)), as: UTF8.self)
        XCTAssertTrue(
            after.contains("\"tokenHash\" : \"\""),
            "a revoked host's hash has no remaining purpose and must be erased"
        )
    }

    func testRevocationSurvivesAReload() throws {
        let first = try makeRegistry()
        let enrollment = try first.enroll(label: "buildhost")
        try first.revoke(hostID: enrollment.host.id)

        let second = try makeRegistry()
        XCTAssertNil(second.authenticate(token: enrollment.token))
        XCTAssertFalse(second.hasActiveHosts)
    }

    func testRotationInvalidatesTheOldTokenWithNoGracePeriod() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")
        let rotated = try registry.rotateToken(hostID: enrollment.host.id)

        XCTAssertNotEqual(rotated.token, enrollment.token)
        XCTAssertEqual(rotated.host.id, enrollment.host.id, "rotation keeps the host, not just the label")
        // No grace period: rotation is what you do when you think the old one
        // leaked, so the old one has to be dead the instant it returns.
        XCTAssertNil(registry.authenticate(token: enrollment.token))
        XCTAssertEqual(registry.authenticate(token: rotated.token)?.id, enrollment.host.id)
    }

    func testRotatingARevokedHostReinstatesIt() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")
        try registry.revoke(hostID: enrollment.host.id)
        let rotated = try registry.rotateToken(hostID: enrollment.host.id)

        XCTAssertFalse(rotated.host.isRevoked)
        XCTAssertEqual(registry.authenticate(token: rotated.token)?.id, enrollment.host.id)
        XCTAssertNil(registry.authenticate(token: enrollment.token), "the revoked token stays dead")
    }

    func testRevokeAndRotateRejectUnknownHosts() throws {
        let registry = try makeRegistry()
        XCTAssertThrowsError(try registry.revoke(hostID: "hnope")) { error in
            XCTAssertEqual(error as? ClaudeRemoteHostRegistry.StoreError, .unknownHost("hnope"))
        }
        XCTAssertThrowsError(try registry.rotateToken(hostID: "hnope"))
        XCTAssertThrowsError(try registry.remove(hostID: "hnope"))
    }

    func testRemoveForgetsTheHostEntirely() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")
        try registry.remove(hostID: enrollment.host.id)
        XCTAssertTrue(registry.hosts().isEmpty)
        XCTAssertNil(registry.authenticate(token: enrollment.token))
    }

    // MARK: Activity

    func testNoteActivityRecordsLastSeen() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")
        XCTAssertNil(enrollment.host.lastSeenAt)

        advance(300)
        registry.noteActivity(hostID: enrollment.host.id)
        XCTAssertEqual(registry.host(id: enrollment.host.id)?.lastSeenAt, clock.withLock { $0 })
    }

    func testNoteActivityDoesNotWriteToDisk() throws {
        // A disk write per hook event would turn a dictation nicety into steady
        // write amplification on the user's SSD.
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")
        let before = io.written(at: fileURL)
        advance(10)
        registry.noteActivity(hostID: enrollment.host.id)
        XCTAssertEqual(io.written(at: fileURL), before)
    }

    // MARK: Store integrity

    func testAnUnreadableStoreIsReportedNeverSilentlyReplaced() throws {
        // Starting fresh would revoke every enrolled host by accident, and do it
        // quietly: the user would just find that context had stopped working.
        io.seed(Data("this is not json".utf8), at: fileURL)
        XCTAssertThrowsError(try makeRegistry()) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteHostRegistry.StoreError,
                .unreadable(path: fileURL.path)
            )
        }
    }

    func testAFutureStoreVersionIsRefused() throws {
        io.seed(Data(#"{"v": 99, "hosts": []}"#.utf8), at: fileURL)
        XCTAssertThrowsError(try makeRegistry()) { error in
            XCTAssertEqual(error as? ClaudeRemoteHostRegistry.StoreError, .unsupportedVersion(99))
        }
    }

    func testAnAbsentStoreIsAnEmptyRegistryNotAnError() throws {
        let registry = try makeRegistry()
        XCTAssertTrue(registry.hosts().isEmpty)
        XCTAssertFalse(registry.hasActiveHosts, "no enrollment means no port is ever bound")
    }
}

/// The digest primitives on their own.
/// Fails the Nth write and every write after it, so the "a failed persist must
/// not destroy what was already stored" contract is testable — a real filesystem
/// will not oblige by failing on demand.
private final class FailingStoreIO: ClaudeRemoteHostStoreIO {
    private let contents = Mutex<[String: Data]>([:])
    private let writesUntilFailure = Mutex<Int>(.max)

    func failAfter(_ successfulWrites: Int) {
        writesUntilFailure.withLock { $0 = successfulWrites }
    }

    func read(from url: URL) throws -> Data? {
        contents.withLock { $0[url.path] }
    }

    func write(_ data: Data, to url: URL) throws {
        let allowed = writesUntilFailure.withLock { remaining -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        guard allowed else {
            throw ClaudeRemoteHostRegistry.StoreError.writeFailed(path: url.path)
        }
        contents.withLock { $0[url.path] = data }
    }

    func written(at url: URL) -> Data? {
        contents.withLock { $0[url.path] }
    }
}

/// The persistence contract, against the REAL on-disk store.
///
/// `MemoryStoreIO` above deliberately cannot cover any of this: the atomicity,
/// the permissions, the symlink refusal and the temp-file hygiene are properties
/// of the filesystem code specifically, and an in-memory dictionary satisfies all
/// of them vacuously.
final class ClaudeRemoteHostFileStoreIOTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private let io = ClaudeRemoteHostFileStoreIO()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lvx-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        fileURL = directory.appendingPathComponent("claude-remote-hosts.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func mode(of url: URL) throws -> Int16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? -1
    }

    private var strayFiles: [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return all.filter { $0 != fileURL.lastPathComponent }
    }

    func testWriteCreatesTheStoreAtOwnerOnlyPermissions() throws {
        try io.write(Data("first".utf8), to: fileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("first".utf8))
        // 0600 from the moment the file exists — not fixed up afterwards. The
        // file is a list of token hashes; there must be no window in which
        // another user can read it.
        XCTAssertEqual(try mode(of: fileURL), 0o600)
    }

    func testWriteCreatesAPrivateLeafBelowAPermissiveSharedParent() throws {
        let sharedParent = directory.appendingPathComponent("shared-app-support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sharedParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
        let privateLeaf = sharedParent.appendingPathComponent("claude", isDirectory: true)
        let nestedStore = privateLeaf.appendingPathComponent("claude-remote-hosts.json")

        try io.write(Data("payload".utf8), to: nestedStore)

        XCTAssertEqual(try mode(of: sharedParent), 0o755, "shared app data is not chmodded")
        XCTAssertEqual(try mode(of: privateLeaf), 0o700)
        XCTAssertEqual(try mode(of: nestedStore), 0o600)
    }

    func testWriteReplacesAnExistingTargetInPlace() throws {
        try io.write(Data("first".utf8), to: fileURL)
        try io.write(Data("second".utf8), to: fileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("second".utf8))
        XCTAssertEqual(try mode(of: fileURL), 0o600, "a replacement must not inherit looser bits")
    }

    func testWriteLeavesNoTemporaryFilesBehind() throws {
        try io.write(Data("first".utf8), to: fileURL)
        try io.write(Data("second".utf8), to: fileURL)
        XCTAssertEqual(strayFiles, [], "a temp file that outlives its write is a 0600 dropping")
    }

    func testWriteReplacesASymlinkedTargetRatherThanWritingThroughIt() throws {
        // rename(2) replaces the LINK, it does not follow it. So a planted
        // symlink at the store path is destroyed by the next write rather than
        // redirecting our token hashes to wherever it pointed.
        let elsewhere = directory.appendingPathComponent("elsewhere.json")
        try Data("planted".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: elsewhere)

        try io.write(Data("ours".utf8), to: fileURL)

        XCTAssertEqual(try Data(contentsOf: fileURL), Data("ours".utf8))
        XCTAssertEqual(
            try Data(contentsOf: elsewhere), Data("planted".utf8),
            "the symlink's target must be untouched — we replaced the link, not what it pointed at"
        )
        let metadata = try XCTUnwrap(ClaudeSocketGuard.metadata(ofPath: fileURL.path))
        XCTAssertFalse(metadata.isSymlink)
        XCTAssertEqual(metadata.mode, 0o600)
    }

    func testReadOfAnAbsentStoreIsNilNotAnError() throws {
        XCTAssertNil(try io.read(from: fileURL))
    }

    func testReadRoundTripsWhatWasWritten() throws {
        try io.write(Data("payload".utf8), to: fileURL)
        XCTAssertEqual(try io.read(from: fileURL), Data("payload".utf8))
    }

    func testReadRefusesASymlinkedStore() throws {
        let real = directory.appendingPathComponent("elsewhere.json")
        try Data("planted".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: real)
        // A symlink here means someone else chose what we authenticate against.
        // Refusing is the only safe answer; following it would let a planted
        // file decide which remote hosts are enrolled.
        XCTAssertThrowsError(try io.read(from: fileURL)) { error in
            XCTAssertEqual(
                error as? ClaudeSocketGuard.PreconditionFailure,
                .isSymlink(fileURL.path)
            )
        }
    }

    func testReadRefusesAStoreOtherUsersCanRead() throws {
        try io.write(Data("payload".utf8), to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: fileURL.path
        )
        XCTAssertThrowsError(try io.read(from: fileURL)) { error in
            guard case .permissive? = error as? ClaudeSocketGuard.PreconditionFailure else {
                return XCTFail("expected .permissive, got \(error)")
            }
        }
    }
}

/// Persistence as the REGISTRY contracts it: memory and disk agree, and a failed
/// write never destroys what was already there.
final class ClaudeRemoteHostRegistryPersistenceTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/lvx-test/claude-remote-hosts.json")

    private func makeRegistry(io: any ClaudeRemoteHostStoreIO) throws -> ClaudeRemoteHostRegistry {
        try ClaudeRemoteHostRegistry(
            fileURL: fileURL,
            io: io,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }

    private func decode(_ data: Data) throws -> ClaudeRemoteHostRegistry.StoredFile {
        try JSONDecoder.claudeRemote.decode(ClaudeRemoteHostRegistry.StoredFile.self, from: data)
    }

    func testAFailedPersistLeavesThePreviouslyStoredFileIntact() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        _ = try registry.enroll(label: "first")
        let afterFirst = io.written(at: fileURL)
        XCTAssertNotNil(afterFirst)

        io.failAfter(0)
        XCTAssertThrowsError(try registry.enroll(label: "second"))
        // The point of rename-over-target with no delete first: a write that
        // fails is a write that did not happen. The user's existing enrollments
        // are not collateral for a full disk.
        XCTAssertEqual(io.written(at: fileURL), afterFirst)
        XCTAssertEqual(try decode(XCTUnwrap(io.written(at: fileURL))).hosts.map(\.label), ["first"])
    }

    func testConcurrentEnrollmentsLeaveDiskAgreeingWithMemory() throws {
        let io = MemoryStoreIO()
        let registry = try makeRegistry(io: io)

        // Every mutation releases the state lock before persisting, so without
        // serialization these interleave as: A snapshots {A}, B snapshots {A,B},
        // B writes {A,B}, A writes {A} — and the last writer puts a STALE
        // snapshot on disk. Memory says two hosts, the file says one, and the
        // discrepancy only surfaces on the next launch, as a host that silently
        // stopped working.
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            _ = try? registry.enroll(label: "host\(index)")
        }

        let inMemory = Set(registry.hosts().map(\.label))
        XCTAssertEqual(inMemory.count, 16)
        let onDisk = try Set(decode(XCTUnwrap(io.written(at: fileURL))).hosts.map(\.label))
        XCTAssertEqual(onDisk, inMemory, "the last write must be the newest state, not a stale snapshot")
    }

    func testConcurrentMixedMutationsConvergeOnDisk() throws {
        let io = MemoryStoreIO()
        let registry = try makeRegistry(io: io)
        let enrolled = try (0..<8).map { try registry.enroll(label: "host\($0)") }

        DispatchQueue.concurrentPerform(iterations: 8) { index in
            if index.isMultiple(of: 2) {
                try? registry.revoke(hostID: enrolled[index].host.id)
            } else {
                _ = try? registry.rotateToken(hostID: enrolled[index].host.id)
            }
        }

        let onDisk = try decode(XCTUnwrap(io.written(at: fileURL)))
        let revokedOnDisk = Set(onDisk.hosts.filter { $0.revokedAt != nil }.map(\.id))
        let revokedInMemory = Set(registry.hosts().filter(\.isRevoked).map(\.id))
        XCTAssertEqual(revokedOnDisk, revokedInMemory)
        XCTAssertEqual(revokedInMemory.count, 4)
    }

    func testNoPlaintextTokenReachesDiskUnderConcurrency() throws {
        // The single most important assertion about the file, restated where
        // concurrency could plausibly break it: a torn or interleaved write must
        // not be a route by which a plaintext token lands in the store.
        let io = MemoryStoreIO()
        let registry = try makeRegistry(io: io)
        let tokens = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            if let enrollment = try? registry.enroll(label: "host\(index)") {
                tokens.withLock { $0.append(enrollment.token) }
            }
        }
        let bytes = try XCTUnwrap(io.written(at: fileURL))
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for token in tokens.withLock({ $0 }) {
            XCTAssertFalse(text.contains(token), "the store must hold hashes, never a plaintext token")
        }
    }
}

final class ClaudeRemoteTokenDigestTests: XCTestCase {
    func testConstantTimeEqualsMatchesOrdinaryEquality() {
        XCTAssertTrue(ClaudeRemoteTokenDigest.constantTimeEquals("abc", "abc"))
        XCTAssertTrue(ClaudeRemoteTokenDigest.constantTimeEquals("", ""))
        XCTAssertFalse(ClaudeRemoteTokenDigest.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(ClaudeRemoteTokenDigest.constantTimeEquals("abc", "abcd"), "length differs")
        XCTAssertFalse(ClaudeRemoteTokenDigest.constantTimeEquals("abc", ""))
    }

    /// The property that makes it worth having: a difference in the LAST byte
    /// must be caught, which a short-circuiting compare would also do — but the
    /// point is that it costs the same as a difference in the first. This pins
    /// correctness; timing itself is not something a unit test can assert.
    func testConstantTimeEqualsCatchesADifferenceAtEitherEnd() {
        let base = String(repeating: "a", count: 64)
        XCTAssertFalse(ClaudeRemoteTokenDigest.constantTimeEquals(base, "b" + base.dropFirst()))
        XCTAssertFalse(ClaudeRemoteTokenDigest.constantTimeEquals(base, base.dropLast() + "b"))
    }

    func testHashIsStableAndDependsOnBothInputs() {
        let hash = ClaudeRemoteTokenDigest.hash(token: "token", salt: "salt")
        XCTAssertEqual(hash, ClaudeRemoteTokenDigest.hash(token: "token", salt: "salt"))
        XCTAssertNotEqual(hash, ClaudeRemoteTokenDigest.hash(token: "token", salt: "other"))
        XCTAssertNotEqual(hash, ClaudeRemoteTokenDigest.hash(token: "other", salt: "salt"))
        XCTAssertEqual(hash.count, 64, "hex SHA-256")
    }

    /// `salt || token` concatenation must not be ambiguous about where the salt
    /// ends — otherwise ("ab", "c") and ("a", "bc") collide.
    func testHashDoesNotConfuseSaltAndTokenBoundaries() {
        XCTAssertNotEqual(
            ClaudeRemoteTokenDigest.hash(token: "bc", salt: "a"),
            ClaudeRemoteTokenDigest.hash(token: "c", salt: "ab")
        )
    }

    func testGeneratedTokensAreWellFormedAndUnguessable() {
        let tokens = (0..<64).map { _ in ClaudeRemoteTokenDigest.makeToken() }
        for token in tokens {
            XCTAssertTrue(ClaudeRemoteTokenDigest.isWellFormed(token))
            // base64url: safe unquoted in an HTTP header, a JSON string, and a
            // shell command line — all three of which it passes through.
            XCTAssertFalse(token.contains("+"))
            XCTAssertFalse(token.contains("/"))
            XCTAssertFalse(token.contains("="))
        }
        XCTAssertEqual(Set(tokens).count, tokens.count, "tokens must not repeat")
        XCTAssertGreaterThanOrEqual(tokens[0].count, 43, "32 bytes of entropy, base64url")
    }

    func testGeneratedHostIDsAreOpaqueAndSeparatorFree() {
        // A host id becomes a session-id namespace and an origin channel; a
        // separator in one would let a crafted id forge either.
        for _ in 0..<64 {
            let id = ClaudeRemoteTokenDigest.makeHostID()
            XCTAssertTrue(id.allSatisfy { $0.isHexDigit || $0 == "h" })
            XCTAssertFalse(id.contains(":"))
            XCTAssertFalse(id.contains("/"))
        }
    }

    func testWellFormednessIsAnAllowlist() {
        XCTAssertTrue(ClaudeRemoteTokenDigest.isWellFormed(String(repeating: "a", count: 16)))
        XCTAssertFalse(ClaudeRemoteTokenDigest.isWellFormed(String(repeating: "a", count: 15)), "too short")
        XCTAssertFalse(ClaudeRemoteTokenDigest.isWellFormed(String(repeating: "a", count: 129)), "too long")
        for bad in ["aaaaaaaaaaaaaaa+", "aaaaaaaaaaaaaaa/", "aaaaaaaaaaaaaaa ", "aaaaaaaaaaaaaaa\n"] {
            XCTAssertFalse(ClaudeRemoteTokenDigest.isWellFormed(bad), "'\(bad)' must not be well-formed")
        }
    }
}
