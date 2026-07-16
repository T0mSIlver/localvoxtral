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
