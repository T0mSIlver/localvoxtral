import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// The port is half of a two-sided configuration a human copies by hand: the
/// ssh block here and the plugin's `port` option there. If the app ever
/// recomputes a different answer than it printed, the two halves disagree and
/// the hooks fail open — which looks exactly like nothing happening. So
/// stability is not a nicety here, it is the contract.
final class ClaudeRemoteForwardPortTests: XCTestCase {
    private func defaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "ClaudeRemoteForwardPortTests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: Derivation

    func testTheSameIdentityAlwaysDerivesTheSamePort() {
        let identity = "6A5E9F1C-0C2E-4D1F-9E3A-0A6E2A2B7C11"
        let first = ClaudeRemoteForwardPort.port(forInstallIdentity: identity)
        for _ in 0..<50 {
            XCTAssertEqual(ClaudeRemoteForwardPort.port(forInstallIdentity: identity), first)
        }
    }

    func testEveryDerivedPortLandsInsideTheDocumentedRange() {
        for index in 0..<2000 {
            let port = ClaudeRemoteForwardPort.port(forInstallIdentity: "install-\(index)")
            XCTAssertGreaterThanOrEqual(port, ClaudeRemoteForwardPort.rangeLowerBound)
            XCTAssertLessThanOrEqual(port, ClaudeRemoteForwardPort.rangeUpperBound)
        }
    }

    func testTheRangeSitsBelowEveryDefaultEphemeralRangeAndAboveThePrivilegedOnes() {
        // Below Linux's 32768 and macOS/BSD's 49152, so an outbound socket on
        // the remote host can never be holding the port the forward wants;
        // above 1023, so binding it needs no privilege.
        XCTAssertGreaterThan(ClaudeRemoteForwardPort.rangeLowerBound, 1023)
        XCTAssertLessThan(ClaudeRemoteForwardPort.rangeUpperBound, 32768)
        XCTAssertEqual(
            ClaudeRemoteForwardPort.rangeUpperBound - ClaudeRemoteForwardPort.rangeLowerBound + 1,
            ClaudeRemoteForwardPort.portCount
        )
    }

    func testDistinctIdentitiesSpreadAcrossTheWholeWidenedRange() {
        // This test was a v1 remnant: written for 100 slots, it demanded only
        // ">80 distinct" and the OLD 100-slot implementation passed it
        // unchanged — so it pinned nothing about the widening. Two properties
        // now, both of which the old implementation fails:
        //
        //   1. the ports actually SPREAD over 2000 slots, not 100, and
        //   2. the great majority land ABOVE 28572 — the old ceiling — which is
        //      the single cheapest way to detect a silent revert to v1.
        let ports = (0..<3000).map {
            ClaudeRemoteForwardPort.port(forInstallIdentity: "install-\($0)")
        }
        let distinct = Set(ports)
        XCTAssertGreaterThan(
            distinct.count, 1400,
            "3000 identities over 2000 slots should hit ~1550 of them; got \(distinct.count)"
        )
        let aboveOldCeiling = ports.filter { $0 > 28572 }.count
        XCTAssertGreaterThan(
            aboveOldCeiling, 2500,
            "the old 100-slot range could not produce these at all; got \(aboveOldCeiling)"
        )
        XCTAssertTrue(ports.allSatisfy {
            (ClaudeRemoteForwardPort.rangeLowerBound...ClaudeRemoteForwardPort.rangeUpperBound)
                .contains($0)
        })
    }

    func testTheV2DerivationIsPinnedToExactValues() {
        // Golden values. The derivation is a two-sided contract with text a
        // user already pasted into ~/.ssh/config and into a remote plugin
        // config, so it must not drift silently: a changed domain string, a
        // changed fold width, or a reverted range all show up here as a
        // different number. (The v1 answers for these identities were 28508,
        // 28568, 28486 — inside the old 100-slot window, and nothing like
        // these.)
        XCTAssertEqual(ClaudeRemoteForwardPort.port(forInstallIdentity: "mac-a"), 28486)
        XCTAssertEqual(ClaudeRemoteForwardPort.port(forInstallIdentity: "mac-b"), 28761)
        XCTAssertEqual(ClaudeRemoteForwardPort.port(forInstallIdentity: "fixed-identity"), 29201)
    }

    func testTheLegacyPortIsOutsideTheAllocationRange() {
        // Otherwise a freshly allocated Mac could land on 8473 and be
        // indistinguishable from an install that never migrated.
        XCTAssertFalse(
            (ClaudeRemoteForwardPort.rangeLowerBound...ClaudeRemoteForwardPort.rangeUpperBound)
                .contains(ClaudeRemoteForwardPort.legacyPort)
        )
    }

    func testAcceptableRangeMatchesTheShimsValidation() {
        // The shim clamps to 1024–65535 and falls back to 8473 outside it; this
        // constant is what the Swift side must agree with.
        XCTAssertTrue(ClaudeRemoteForwardPort.isAcceptable(1024))
        XCTAssertTrue(ClaudeRemoteForwardPort.isAcceptable(65535))
        XCTAssertFalse(ClaudeRemoteForwardPort.isAcceptable(1023))
        XCTAssertTrue(ClaudeRemoteForwardPort.isAcceptable(ClaudeRemoteForwardPort.legacyPort))
    }

    func testTheContentionMessageNamesThePortTheHostAndNoApostrophe() throws {
        let message = ClaudeRemoteForwardPort.contentionMessage(port: 28500, host: "builder")
        XCTAssertTrue(message.contains("28500"))
        XCTAssertTrue(message.contains("builder"))
        // It is embedded in single-quoted shell in the verify command; one
        // apostrophe would end the quote and change what the user runs.
        XCTAssertFalse(message.contains("'"))
    }

    // MARK: Identity persistence (review finding 4)

    /// An in-memory store with the one property that matters: `claim` is
    /// first-writer-wins, like `link(2)`, not last-writer-wins like a
    /// defaults write.
    private final class MemoryIdentityStore: ClaudeRemoteForwardIdentityStore, @unchecked Sendable {
        private let stored = Mutex<String?>(nil)
        private let claims = Mutex(0)

        var claimCount: Int { claims.withLock { $0 } }
        var value: String? { stored.withLock { $0 } }

        init(seed: String? = nil) { stored.withLock { $0 = seed } }

        /// Blank is not an identity — same contract as the file store, which
        /// returns nil for an empty or whitespace-only file. A fake that were
        /// laxer here would let the allocator's own guard go untested.
        func read() throws -> String? {
            stored.withLock { value in
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return value
            }
        }

        func claim(_ candidate: String) throws -> String {
            claims.withLock { $0 += 1 }
            return stored.withLock { current in
                if let existing = current,
                   !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return existing
                }
                current = candidate
                return candidate
            }
        }
    }

    private final class FailingIdentityStore: ClaudeRemoteForwardIdentityStore, @unchecked Sendable {
        struct Denied: Error {}
        func read() throws -> String? { nil }
        func claim(_ candidate: String) throws -> String { throw Denied() }
    }

    func testTwoRacingFirstLaunchesConvergeOnOneIdentity() throws {
        // The defaults-based version was a read-then-write with no atomicity:
        // two processes starting together each generated an identity and the
        // last writer won, so a host enrolled under the loser's port was wrong
        // forever. First-writer-wins is the property; this is it, exercised
        // through the seam.
        let store = MemoryIdentityStore()
        let first = ClaudeRemoteForwardPortAllocator(
            store: store, legacyDefaults: nil, makeIdentity: { "racer-a" }
        )
        let second = ClaudeRemoteForwardPortAllocator(
            store: store, legacyDefaults: nil, makeIdentity: { "racer-b" }
        )

        XCTAssertEqual(first.installIdentity(), "racer-a")
        XCTAssertEqual(second.installIdentity(), "racer-a", "the loser must adopt the winner")
        XCTAssertEqual(first.allocatedPort(), second.allocatedPort())
    }

    func testAnIdentityOutlivesAPreferencesReset() throws {
        // `defaults delete`, a migration assistant, a restored backup: the host
        // registry in Application Support survives all of them, and an identity
        // that did not would silently move every enrolled host's port while the
        // enrollments themselves looked healthy.
        let store = MemoryIdentityStore()
        let defaults = try defaults()
        let allocator = ClaudeRemoteForwardPortAllocator(
            store: store, legacyDefaults: defaults, makeIdentity: { "durable" }
        )
        let port = allocator.allocatedPort()

        defaults.removePersistentDomain(forName: defaults.description)
        let afterReset = ClaudeRemoteForwardPortAllocator(
            store: store,
            legacyDefaults: try self.defaults("fresh"),
            makeIdentity: { XCTFail("a persisted identity must not be regenerated"); return "x" }
        )
        XCTAssertEqual(afterReset.allocatedPort(), port)
    }

    func testAnIdentityWrittenByTheFirstIterationMigratesInsteadOfMoving() throws {
        // This feature's first iteration stored the identity in UserDefaults.
        // An install that already has one must keep its port — it may already
        // have handed that port to a remote host.
        let defaults = try defaults()
        defaults.set("legacy-identity", forKey: ClaudeRemoteForwardPortAllocator.identityDefaultsKey)
        let store = MemoryIdentityStore()
        let allocator = ClaudeRemoteForwardPortAllocator(
            store: store, legacyDefaults: defaults, makeIdentity: { "freshly-generated" }
        )

        XCTAssertEqual(allocator.installIdentity(), "legacy-identity")
        XCTAssertEqual(store.value, "legacy-identity", "and it must be durable from now on")
        XCTAssertEqual(
            allocator.allocatedPort(),
            ClaudeRemoteForwardPort.port(forInstallIdentity: "legacy-identity")
        )
    }

    func testTheFileStoreIsFirstWriterWinsAndPrivate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvx-identity-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("claude-remote-forward-identity")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ClaudeRemoteForwardIdentityFileStore(fileURL: url)

        XCTAssertNil(try store.read())
        XCTAssertEqual(try store.claim("first"), "first")
        // The second claim must NOT overwrite — that is the whole point of the
        // link-based create, and the difference from a plain atomic write.
        XCTAssertEqual(try store.claim("second"), "first")
        XCTAssertEqual(try store.read(), "first")

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual(mode as? NSNumber, 0o600)
        // No temp files left behind next to it.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".claude-remote-forward-identity.") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testAnUnwritableIdentityStoreStillYieldsAPortForThisLaunch() throws {
        // Read-only home or a sandbox denial: the launch must still work (and
        // log), rather than crash or hand back a port of zero.
        let allocator = ClaudeRemoteForwardPortAllocator(
            store: FailingIdentityStore(), legacyDefaults: nil, makeIdentity: { "ephemeral" }
        )
        XCTAssertEqual(
            allocator.allocatedPort(),
            ClaudeRemoteForwardPort.port(forInstallIdentity: "ephemeral")
        )
    }

    // MARK: Allocator

    func testTheIdentityIsGeneratedOnceAndThenReused() throws {
        let store = MemoryIdentityStore()
        let generated = Mutex(0)
        let allocator = ClaudeRemoteForwardPortAllocator(
            store: store,
            legacyDefaults: nil,
            makeIdentity: {
                generated.withLock { $0 += 1 }
                return "fixed-identity"
            }
        )

        let first = allocator.allocatedPort()
        let second = allocator.allocatedPort()
        // A second allocator over the same store is what the next launch is.
        let relaunched = ClaudeRemoteForwardPortAllocator(
            store: store,
            legacyDefaults: nil,
            makeIdentity: { XCTFail("a persisted identity must never be regenerated"); return "x" }
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(relaunched.allocatedPort(), first)
        XCTAssertEqual(generated.withLock { $0 }, 1)
        XCTAssertEqual(store.value, "fixed-identity")
    }

    func testABlankStoredIdentityIsTreatedAsAbsent() throws {
        // A half-written file must not pin every install that suffered it to
        // one shared port — which is the exact failure this whole change
        // exists to remove.
        let store = MemoryIdentityStore(seed: "   ")
        let allocator = ClaudeRemoteForwardPortAllocator(
            store: store, legacyDefaults: nil, makeIdentity: { "regenerated" }
        )
        XCTAssertEqual(allocator.installIdentity(), "regenerated")
        XCTAssertEqual(
            allocator.allocatedPort(),
            ClaudeRemoteForwardPort.port(forInstallIdentity: "regenerated")
        )
    }

    func testTwoInstallsOnOneMachineDoNotShareAPort() throws {
        // The whole point of #215: two enrolled Macs must not both ask the
        // remote for one bind. Distinct identities, distinct ports — this is
        // the property, expressed on the two identities that would collide.
        let a = ClaudeRemoteForwardPortAllocator(
            store: MemoryIdentityStore(), legacyDefaults: nil, makeIdentity: { "mac-a" }
        )
        let b = ClaudeRemoteForwardPortAllocator(
            store: MemoryIdentityStore(), legacyDefaults: nil, makeIdentity: { "mac-b" }
        )
        XCTAssertNotEqual(a.allocatedPort(), b.allocatedPort())
    }

    // `SettingsStore.claudeRemoteForwardPort` is deliberately NOT exercised
    // here any more: since the identity moved out of UserDefaults and into a
    // file beside the host registry (review finding 4), reading that property
    // would create state in the real Application Support directory of whatever
    // machine runs the suite. The allocator, the file store and the derivation
    // are covered directly above; the accessor is a one-line call into them.
}
