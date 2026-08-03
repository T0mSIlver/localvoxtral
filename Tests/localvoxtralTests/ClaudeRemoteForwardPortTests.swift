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

    func testDistinctIdentitiesSpreadAcrossTheRange() {
        // Two Macs must be very unlikely to collide, and the derivation must
        // not degenerate to one value. 100 slots, 500 identities: every slot
        // should be hit by a sane hash.
        let ports = Set((0..<500).map {
            ClaudeRemoteForwardPort.port(forInstallIdentity: UUID(uuidString: String(
                format: "00000000-0000-4000-8000-%012d", $0
            ))?.uuidString ?? "identity-\($0)")
        })
        XCTAssertGreaterThan(ports.count, 80, "the derivation must use the whole range")
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

    // MARK: Allocator

    func testTheIdentityIsGeneratedOnceAndThenReused() throws {
        let defaults = try defaults()
        let generated = Mutex(0)
        let allocator = ClaudeRemoteForwardPortAllocator(
            defaults: defaults,
            makeIdentity: {
                generated.withLock { $0 += 1 }
                return "fixed-identity"
            }
        )

        let first = allocator.allocatedPort()
        let second = allocator.allocatedPort()
        // A second allocator over the same defaults is what the next launch is.
        let relaunched = ClaudeRemoteForwardPortAllocator(
            defaults: defaults,
            makeIdentity: { XCTFail("a persisted identity must never be regenerated"); return "x" }
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(relaunched.allocatedPort(), first)
        XCTAssertEqual(generated.withLock { $0 }, 1)
        XCTAssertEqual(
            defaults.string(forKey: ClaudeRemoteForwardPortAllocator.identityDefaultsKey),
            "fixed-identity"
        )
    }

    func testABlankStoredIdentityIsTreatedAsAbsent() throws {
        // A half-written default must not pin every install that suffered it to
        // one shared port — which is the exact failure this whole change exists
        // to remove.
        let defaults = try defaults()
        defaults.set("   ", forKey: ClaudeRemoteForwardPortAllocator.identityDefaultsKey)
        let allocator = ClaudeRemoteForwardPortAllocator(
            defaults: defaults, makeIdentity: { "regenerated" }
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
            defaults: try defaults("a"), makeIdentity: { "mac-a" }
        )
        let b = ClaudeRemoteForwardPortAllocator(
            defaults: try defaults("b"), makeIdentity: { "mac-b" }
        )
        XCTAssertNotEqual(a.allocatedPort(), b.allocatedPort())
    }

    @MainActor
    func testSettingsStoreExposesAStablePortForTheInstall() throws {
        let defaults = try defaults()
        let store = SettingsStore(defaults: defaults, environment: [:])
        let port = store.claudeRemoteForwardPort
        XCTAssertTrue(ClaudeRemoteForwardPort.isAcceptable(port))
        XCTAssertEqual(store.claudeRemoteForwardPort, port)
        // Same defaults domain, new store: the next launch of this install.
        XCTAssertEqual(SettingsStore(defaults: defaults, environment: [:]).claudeRemoteForwardPort, port)
    }
}
