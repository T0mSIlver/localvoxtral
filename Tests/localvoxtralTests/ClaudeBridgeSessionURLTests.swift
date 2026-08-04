import XCTest
@testable import localvoxtral

/// The parser that turns a browser tab URL into a join key.
///
/// The asymmetry these tests defend: a false positive here is a JOIN, and a
/// join attaches a Claude session's prior prompt, its recent files, and (for a
/// local session) its repository to whatever the user just said. A false
/// negative costs one dictation's context. So every shape that is not exactly
/// `https://claude.ai/code/session_…` must return nil — especially the ones a
/// page the user is merely READING could produce.
final class ClaudeBridgeSessionURLTests: XCTestCase {
    // MARK: - The shapes that join

    func testPlainSessionURL() {
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(
                inTabURL: "https://claude.ai/code/session_01JQ8Z4KX9"
            ),
            "session_01JQ8Z4KX9"
        )
    }

    // The app appends both; neither is part of the identity.
    func testQueryAndFragmentAreIgnored() {
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(
                inTabURL: "https://claude.ai/code/session_abc?tab=files&x=1"
            ),
            "session_abc"
        )
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/session_abc#top"),
            "session_abc"
        )
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/session_abc?a=b#c"),
            "session_abc"
        )
    }

    func testSingleTrailingSlashIsTolerated() {
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/session_abc/"),
            "session_abc"
        )
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/session_abc/?x=1"),
            "session_abc"
        )
    }

    // Hosts are case-insensitive by the URL standard and a browser may report
    // one as typed; the ID is not, and must survive verbatim.
    func testHostAndSchemeAreCaseNormalizedButTheIDIsNot() {
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "HTTPS://CLAUDE.AI/code/session_AbC_dEf"),
            "session_AbC_dEf"
        )
    }

    func testIDCharsetEdges() {
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/session_a-b_c-9Z"),
            "session_a-b_c-9Z"
        )
        // One character after the prefix is enough.
        XCTAssertEqual(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/session_a"),
            "session_a"
        )
    }

    // MARK: - Host tricks

    // The classic suffix trick: a host the attacker owns, ending in the string
    // we are looking for.
    func testLookalikeHostSuffixIsRejected() {
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(
                inTabURL: "https://claude.ai.evil.com/code/session_abc"
            )
        )
    }

    // The path trick: our host name, but in someone else's path.
    func testOurHostInsideAnotherHostsPathIsRejected() {
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(
                inTabURL: "https://evil.com/claude.ai/code/session_abc"
            )
        )
    }

    // No subdomain is the real UI, and admitting one would admit every
    // "anything.claude.ai" a future product ships — including ones that are not
    // Remote Control.
    func testSubdomainsAreRejected() {
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://www.claude.ai/code/session_abc")
        )
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://evil.claude.ai/code/session_abc")
        )
    }

    // `https://claude.ai@evil.com/…` reads as our host to a human and resolves
    // to evil.com. Rejected twice over: the userinfo check, and the host check.
    func testUserinfoIsRejected() {
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai@evil.com/code/session_a")
        )
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(
                inTabURL: "https://user:pass@claude.ai/code/session_a"
            )
        )
    }

    func testPortIsRejected() {
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai:8443/code/session_abc")
        )
    }

    func testNonHTTPSSchemesAreRejected() {
        for url in [
            "http://claude.ai/code/session_abc",
            "file:///code/session_abc",
            "javascript:https://claude.ai/code/session_abc",
            "//claude.ai/code/session_abc",
            "claude.ai/code/session_abc",
        ] {
            XCTAssertNil(
                ClaudeBridgeSessionURL.sessionID(inTabURL: url),
                "\(url) must not join"
            )
        }
    }

    // MARK: - Path and id shapes

    func testOtherPathsOnTheRealHostAreRejected() {
        for url in [
            "https://claude.ai/",
            "https://claude.ai/code",
            "https://claude.ai/code/",
            "https://claude.ai/chat/session_abc",
            "https://claude.ai/code/session_abc/files",
            "https://claude.ai//code/session_abc",
            "https://claude.ai/code/session_abc//",
        ] {
            XCTAssertNil(
                ClaudeBridgeSessionURL.sessionID(inTabURL: url),
                "\(url) must not join"
            )
        }
    }

    func testIDsWithoutTheSessionPrefixAreRejected() {
        for id in ["abc", "Session_abc", "SESSION_abc", "session-abc", "session_", "sess_abc"] {
            XCTAssertNil(
                ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/\(id)"),
                "\(id) must not join"
            )
        }
    }

    // A percent escape must not be able to decode into a shape we accepted:
    // the parser reads the ENCODED path, so `%` (not in the id charset) fails.
    func testPercentEscapesAreRejected() {
        for id in ["session_a%2Fb", "session%5Fabc", "session_abc%00", "session_%2E%2E"] {
            XCTAssertNil(
                ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/\(id)"),
                "\(id) must not join"
            )
        }
    }

    func testNonASCIILookalikesAreRejected() {
        // Cyrillic 'а' inside the id.
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/session_\u{0430}bc")
        )
        // Cyrillic 'а' inside the host (IDN homograph).
        XCTAssertNil(
            ClaudeBridgeSessionURL.sessionID(
                inTabURL: "https://cl\u{0430}ude.ai/code/session_abc"
            )
        )
    }

    func testOverlongIDIsRejected() {
        let long = "session_" + String(repeating: "a", count: 200)
        XCTAssertNil(ClaudeBridgeSessionURL.sessionID(inTabURL: "https://claude.ai/code/\(long)"))
    }

    func testGarbageIsRejected() {
        for url in ["", " ", "not a url", "https://", "https:///code/session_abc"] {
            XCTAssertNil(
                ClaudeBridgeSessionURL.sessionID(inTabURL: url),
                "\(url) must not join"
            )
        }
    }
}
