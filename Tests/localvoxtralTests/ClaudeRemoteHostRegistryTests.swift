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

private final class RemoteHostTestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))

    func reset() {
        value.withLock { $0 = Date(timeIntervalSince1970: 1_000_000) }
    }

    func now() -> Date {
        value.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

final class ClaudeRemoteHostRegistryTests: XCTestCase {
    private var io: MemoryStoreIO!
    private let fileURL = URL(fileURLWithPath: "/tmp/lvx-test/claude-remote-hosts.json")
    private let clock = RemoteHostTestClock()

    override func setUp() {
        super.setUp()
        io = MemoryStoreIO()
        clock.reset()
    }

    private func makeRegistry(
        tokens: [String] = [],
        hostIDs: [String] = []
    ) throws -> ClaudeRemoteHostRegistry {
        let tokenQueue = Mutex(tokens)
        let idQueue = Mutex(hostIDs)
        let clock = self.clock
        return try ClaudeRemoteHostRegistry(
            fileURL: fileURL,
            io: io,
            now: { [clock] in clock.now() },
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
        clock.advance(seconds)
    }

    // MARK: Enrollment

    func testEnrollIssuesAWorkingTokenAndPersistsTheHost() throws {
        let registry = try makeRegistry()
        let enrollment = try registry.enroll(label: "buildhost")

        XCTAssertEqual(enrollment.host.label, "buildhost")
        XCTAssertNil(enrollment.host.revokedAt)
        XCTAssertEqual(enrollment.host.createdAt, clock.now())
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

    func testLegacyHashStillAuthenticatesAndRotationMigratesItToHMAC() throws {
        let legacyToken = "legacyToken_1234567890"
        let legacySalt = "legacySalt_1234567890"
        let storedHost = ClaudeRemoteHostRegistry.StoredHost(
            id: "hlegacy01",
            label: "legacy",
            createdAt: clock.now(),
            lastSeenAt: nil,
            revokedAt: nil,
            tokenSalt: legacySalt,
            tokenHash: ClaudeRemoteTokenDigest.legacyHash(
                token: legacyToken, salt: legacySalt
            ),
            hashVersion: nil
        )
        let storedFile = ClaudeRemoteHostRegistry.StoredFile(
            version: ClaudeRemoteHostRegistry.fileVersion,
            hosts: [storedHost]
        )
        io.seed(try JSONEncoder.claudeRemote.encode(storedFile), at: fileURL)

        let newToken = "rotatedToken_1234567890"
        let newSalt = "rotatedSalt_12345678901"
        let registry = try makeRegistry(tokens: [newToken, newSalt])
        XCTAssertEqual(registry.authenticate(token: legacyToken)?.id, storedHost.id)

        let rotated = try registry.rotateToken(hostID: storedHost.id)
        XCTAssertEqual(rotated.token, newToken)
        XCTAssertNil(registry.authenticate(token: legacyToken))
        XCTAssertEqual(registry.authenticate(token: newToken)?.id, storedHost.id)

        let persisted = try JSONDecoder.claudeRemote.decode(
            ClaudeRemoteHostRegistry.StoredFile.self,
            from: try XCTUnwrap(io.written(at: fileURL))
        )
        XCTAssertEqual(persisted.hosts.first?.hashVersion, ClaudeRemoteHostRegistry.currentHashVersion)
    }

    /// Review finding (PR #197): the update/rotate paths had to guess the ssh
    /// alias from the display name, so a host NAMED `prod` and REACHED over
    /// alias `builder` would have been acted on as `prod` — a different
    /// machine. The alias the user enrolled with is persisted for exactly this,
    /// and survives the relaunch that separates enrollment from an update.
    func testTheEnrolledSSHAliasIsPersistedSeparatelyFromTheLabel() throws {
        let first = try makeRegistry()
        let enrollment = try first.enroll(label: "prod", sshHostAlias: "builder")
        XCTAssertEqual(enrollment.host.label, "prod")
        XCTAssertEqual(enrollment.host.sshHostAlias, "builder")

        let second = try makeRegistry()
        XCTAssertEqual(second.hosts().first?.sshHostAlias, "builder")
    }

    func testAnUnusableSSHAliasIsNotStoredAtAll() throws {
        // A stored alias is later allowed to reach ssh's argv, so the registry
        // stores only what the validator accepts — nil, never a repaired value
        // that some caller would then trust.
        let registry = try makeRegistry()
        for alias in ["-V", "two words", "host#comment", ""] {
            let enrollment = try registry.enroll(label: "host", sshHostAlias: alias)
            XCTAssertNil(enrollment.host.sshHostAlias, "'\(alias)' must not be stored")
        }
    }

    func testAHostStoredBeforeAliasesWereRecordedLoadsWithoutOne() throws {
        // The key is absent in files written by earlier builds. That must read
        // back as "no alias" — not as a decode failure, which would report the
        // whole store unreadable and strand every enrolled host.
        let storedHost = ClaudeRemoteHostRegistry.StoredHost(
            id: "hlegacy02",
            label: "legacy",
            createdAt: clock.now(),
            lastSeenAt: nil,
            revokedAt: nil,
            tokenSalt: "legacySalt_1234567890",
            tokenHash: "abc",
            hashVersion: nil
        )
        let storedFile = ClaudeRemoteHostRegistry.StoredFile(
            version: ClaudeRemoteHostRegistry.fileVersion,
            hosts: [storedHost]
        )
        let json = try XCTUnwrap(
            String(data: try JSONEncoder.claudeRemote.encode(storedFile), encoding: .utf8)
        )
        XCTAssertFalse(json.contains("sshHostAlias"), "an absent alias must not be written as null")
        io.seed(Data(json.utf8), at: fileURL)

        let registry = try makeRegistry()
        XCTAssertEqual(registry.hosts().map(\.id), ["hlegacy02"])
        XCTAssertNil(registry.hosts().first?.sshHostAlias)
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
        // `sshHostAlias` joined this allowlist deliberately (PR #197): it is
        // the name of a host in the user's own ssh config, not a credential,
        // and the alternative — guessing it from the label — acted on the wrong
        // machine.
        let properties = Mirror(reflecting: enrollment.host).children.compactMap(\.label)
        // `persistentForwardEnabled` joined it for the same reason: it is a
        // per-host preference (does the app hold this host's ssh forward), not
        // credential material, and the pane has to be able to render it.
        XCTAssertEqual(
            Set(properties),
            [
                "id", "label", "sshHostAlias", "createdAt", "lastSeenAt", "revokedAt",
                "persistentForwardEnabled",
            ]
        )
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
        XCTAssertEqual(host.revokedAt, clock.now())
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
        XCTAssertEqual(registry.host(id: enrollment.host.id)?.lastSeenAt, clock.now())
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

    // MARK: Persistent forward opt-in

    func testThePersistentForwardFlagIsOffUntilItIsTurnedOnAndSurvivesARelaunch() throws {
        // Spawning ssh on someone's behalf is an opt-in, and "the file was
        // silent about it" must read as off — never as on.
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        XCTAssertFalse(try XCTUnwrap(registry.host(id: host.id)).persistentForwardEnabled)

        try registry.setPersistentForwardEnabled(true, hostID: host.id)
        XCTAssertTrue(try XCTUnwrap(registry.host(id: host.id)).persistentForwardEnabled)

        // A second registry over the same store is the next launch.
        let relaunched = try makeRegistry()
        XCTAssertTrue(try XCTUnwrap(relaunched.host(id: host.id)).persistentForwardEnabled)

        try registry.setPersistentForwardEnabled(false, hostID: host.id)
        XCTAssertFalse(
            try XCTUnwrap(makeRegistry().host(id: host.id)).persistentForwardEnabled,
            "turning it off must persist too, or the app resumes ssh on the next launch"
        )
    }

    func testAFileWrittenBeforeTheFlagExistedReadsAsOff() throws {
        // Forward compatibility, same rule as the alias: an older file has no
        // key, and the safe reading of silence is "do not start ssh".
        let registry = try makeRegistry()
        let host = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        let stored = try XCTUnwrap(io.read(from: fileURL))
        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: stored) as? [String: Any]
        )
        var hosts = try XCTUnwrap(json["hosts"] as? [[String: Any]])
        hosts = hosts.map { entry in
            var copy = entry
            copy.removeValue(forKey: "persistentForwardEnabled")
            return copy
        }
        json["hosts"] = hosts
        try io.write(try JSONSerialization.data(withJSONObject: json), to: fileURL)

        XCTAssertFalse(try XCTUnwrap(makeRegistry().host(id: host.id)).persistentForwardEnabled)
    }

    func testRemovingAHostTakesItsForwardFlagWithIt() throws {
        // The reason the flag lives in the registry rather than in a parallel
        // preference: a separate store would keep a dead host's switch, and
        // could hand it to a future host that reused the id.
        let registry = try makeRegistry(hostIDs: ["hsame123", "hsame123"])
        let first = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        try registry.setPersistentForwardEnabled(true, hostID: first.id)
        try registry.remove(hostID: first.id)

        let second = try registry.enroll(label: "buildhost", sshHostAlias: "builder").host
        XCTAssertEqual(second.id, first.id, "the id allocator was pinned to reuse it")
        XCTAssertFalse(second.persistentForwardEnabled)
    }

    func testSettingTheFlagOnAnUnknownHostIsReportedNotIgnored() throws {
        let registry = try makeRegistry()
        XCTAssertThrowsError(try registry.setPersistentForwardEnabled(true, hostID: "hnope")) { error in
            XCTAssertEqual(
                error as? ClaudeRemoteHostRegistry.StoreError, .unknownHost("hnope")
            )
        }
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

    /// Undo a `failAfter`, so a test can prove the retry after a transient
    /// failure lands — a full disk that the user then cleared.
    func stopFailing() {
        writesUntilFailure.withLock { $0 = .max }
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

    // MARK: - Transactionality
    //
    // A mutation memory accepted and the disk refused is a lie with a delay on
    // it: the UI shows the change, the listener acts on it, and the next launch
    // reads a file that never heard of it. Each of the four mutations is checked
    // for the same contract — a failed write leaves the registry EXACTLY as it
    // was, by every question a caller can ask of it.

    func testAFailedEnrollLeavesTheRegistryUnchangedInMemoryToo() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        let first = try registry.enroll(label: "first")

        io.failAfter(0)
        XCTAssertThrowsError(try registry.enroll(label: "second"))

        XCTAssertEqual(registry.hosts().map(\.label), ["first"], "the rejected host is not in memory either")
        XCTAssertEqual(registry.authenticate(token: first.token)?.id, first.host.id, "and the existing one is intact")
        XCTAssertTrue(registry.hasActiveHosts)
    }

    func testAFailedEnrollDoesNotLeaveAnAuthenticatableHostBehind() throws {
        // The sharpest form of the bug: a token the file does not know about,
        // which the listener would nonetheless accept until the next launch
        // silently stopped it.
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)

        io.failAfter(0)
        XCTAssertThrowsError(try registry.enroll(label: "ghost"))

        XCTAssertTrue(registry.hosts().isEmpty)
        XCTAssertFalse(registry.hasActiveHosts, "no host means no port is bound")
    }

    func testARetriedEnrollSucceedsAfterATransientWriteFailure() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)

        io.failAfter(0)
        XCTAssertThrowsError(try registry.enroll(label: "builder"))
        io.stopFailing()
        let retry = try registry.enroll(label: "builder")

        XCTAssertEqual(registry.hosts().map(\.label), ["builder"], "the rolled-back attempt left no duplicate")
        XCTAssertEqual(registry.authenticate(token: retry.token)?.id, retry.host.id)
        XCTAssertEqual(try decode(XCTUnwrap(io.written(at: fileURL))).hosts.map(\.id), [retry.host.id])
    }

    func testAFailedRotationKeepsTheOldTokenWorking() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        let original = try registry.enroll(label: "builder")

        io.failAfter(0)
        XCTAssertThrowsError(try registry.rotateToken(hostID: original.host.id))

        // Rotation has no grace period by design, so a half-applied one is the
        // worst case available: the old token dead in memory, the new one absent
        // from disk, and the host locked out with nothing left to authenticate.
        XCTAssertEqual(
            registry.authenticate(token: original.token)?.id,
            original.host.id,
            "a rotation that did not persist did not happen"
        )
    }

    func testARetriedRotationSucceedsAndInvalidatesTheOldToken() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        let original = try registry.enroll(label: "builder")

        io.failAfter(0)
        XCTAssertThrowsError(try registry.rotateToken(hostID: original.host.id))
        io.stopFailing()
        let rotated = try registry.rotateToken(hostID: original.host.id)

        XCTAssertEqual(registry.authenticate(token: rotated.token)?.id, original.host.id)
        XCTAssertNil(registry.authenticate(token: original.token), "the retry is a real rotation")
        let stored = try decode(XCTUnwrap(io.written(at: fileURL)))
        XCTAssertEqual(stored.hosts.map(\.id), [original.host.id])
    }

    func testAFailedRevokeLeavesTheHostActive() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        let enrollment = try registry.enroll(label: "builder")

        io.failAfter(0)
        XCTAssertThrowsError(try registry.revoke(hostID: enrollment.host.id))

        // Revoke erases the stored hash as well as setting revokedAt, so the
        // the failed candidate must publish neither — a host whose hash was
        // dropped in memory could never authenticate again, revoked flag or not.
        XCTAssertEqual(registry.host(id: enrollment.host.id)?.isRevoked, false)
        XCTAssertEqual(registry.authenticate(token: enrollment.token)?.id, enrollment.host.id)
        XCTAssertTrue(registry.hasActiveHosts, "the listener must not close a port on a revoke that failed")
    }

    func testARetriedRevokeTakesEffect() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        let enrollment = try registry.enroll(label: "builder")

        io.failAfter(0)
        XCTAssertThrowsError(try registry.revoke(hostID: enrollment.host.id))
        io.stopFailing()
        try registry.revoke(hostID: enrollment.host.id)

        XCTAssertNil(registry.authenticate(token: enrollment.token))
        XCTAssertFalse(registry.hasActiveHosts)
        let stored = try decode(XCTUnwrap(io.written(at: fileURL)))
        XCTAssertEqual(stored.hosts.first?.tokenHash, "", "the persisted revoke erased the hash")
    }

    func testAFailedRemoveKeepsTheHostEnrolled() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        let kept = try registry.enroll(label: "keeper")
        let target = try registry.enroll(label: "target")

        io.failAfter(0)
        XCTAssertThrowsError(try registry.remove(hostID: target.host.id))

        // A set, not an array: this class pins the clock, so both hosts share a
        // createdAt and `hosts()`'s sort has no defined order between them.
        XCTAssertEqual(Set(registry.hosts().map(\.label)), ["keeper", "target"])
        XCTAssertEqual(registry.authenticate(token: target.token)?.id, target.host.id)
        XCTAssertEqual(registry.authenticate(token: kept.token)?.id, kept.host.id, "the bystander is untouched")
    }

    func testARetriedRemoveForgetsTheHost() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        let kept = try registry.enroll(label: "keeper")
        let target = try registry.enroll(label: "target")

        io.failAfter(0)
        XCTAssertThrowsError(try registry.remove(hostID: target.host.id))
        io.stopFailing()
        try registry.remove(hostID: target.host.id)

        XCTAssertEqual(registry.hosts().map(\.label), ["keeper"])
        XCTAssertNil(registry.authenticate(token: target.token))
        XCTAssertEqual(registry.authenticate(token: kept.token)?.id, kept.host.id)
        XCTAssertEqual(try decode(XCTUnwrap(io.written(at: fileURL))).hosts.map(\.id), [kept.host.id])
    }

    func testAFailedConcurrentMutationDoesNotEraseASuccessfulOne() throws {
        // Each candidate is serialized through its write. A failed candidate
        // must never replace the last committed state or erase a later success.
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        let existing = try (0..<4).map { try registry.enroll(label: "host\($0)") }

        // Half the writers hit a failing disk. Whichever they are, every caller
        // that was told "enrolled" must still be enrolled at the end.
        io.failAfter(4)
        let succeeded = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            if let enrollment = try? registry.enroll(label: "concurrent\(index)") {
                succeeded.withLock { $0.append(enrollment.host.id) }
            }
        }

        let inMemory = Set(registry.hosts().map(\.id))
        for id in succeeded.withLock({ $0 }) {
            XCTAssertTrue(inMemory.contains(id), "an enroll that returned success was rolled back by another's failure")
        }
        for enrollment in existing {
            XCTAssertTrue(inMemory.contains(enrollment.host.id), "a pre-existing host was rolled away")
        }
        XCTAssertEqual(inMemory.count, 4 + succeeded.withLock { $0.count })
    }

    func testMemoryAndDiskStillAgreeWhenSomeWritesFail() throws {
        let io = FailingStoreIO()
        let registry = try makeRegistry(io: io)
        _ = try (0..<4).map { try registry.enroll(label: "host\($0)") }

        io.failAfter(4)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            _ = try? registry.enroll(label: "concurrent\(index)")
        }

        // The whole point of the transaction: whatever the mix of successes and
        // failures, the file is a faithful copy of memory when the dust settles.
        let onDisk = try Set(decode(XCTUnwrap(io.written(at: fileURL))).hosts.map(\.id))
        XCTAssertEqual(onDisk, Set(registry.hosts().map(\.id)))
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
