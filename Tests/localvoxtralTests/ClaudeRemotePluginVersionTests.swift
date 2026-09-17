import ClaudeContextWire
import XCTest

/// `ClaudeRemotePluginVersionCodec`: the receiving half of the shim's one
/// version header, tested byte-level like the env codec beside it.
///
/// The shape is strict on purpose: a version is COMPARED, never echoed, so a
/// value that cannot be compared must read as absent rather than as a fact —
/// the pre-1.10.0 plugin generation this header exists to detect.
final class ClaudeRemotePluginVersionTests: XCTestCase {
    func testTheHeaderNameIsWhatTheShimWrites() {
        // The parser keys headers lowercased (ClaudeRemoteHTTPCodec); the
        // canonical spelling is what post.sh must match literally.
        XCTAssertEqual(ClaudeRemotePluginVersionCodec.headerName, "X-Lvx-Plugin-Version")
        XCTAssertEqual(
            ClaudeRemotePluginVersionCodec.lowercasedHeaderName, "x-lvx-plugin-version"
        )
    }

    func testAcceptsExactlyThreeComponentsOfOneToFourDigits() {
        for good in [
            "1.10.0", "0.0.1", "10.20.30", "9999.9999.9999", "1.0.0",
            "1234.1.1", // four digits, the shape's own ceiling
        ] {
            XCTAssertTrue(
                ClaudeRemotePluginVersionCodec.isAcceptableVersion(good),
                "'\(good)' matches ^[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$"
            )
        }
    }

    func testRejectsEverythingElseIncludingInjectionShapes() throws {
        let bad = [
            "", "1.10", "1.10.0.0", "1..0", ".1.0", "1.10.", " 1.10.0",
            "1.10.0 ", "v1.10.0", "1.1o.0", "1.10.0\r\nX-Evil: 1", "1.10.0\n",
            "1,10.0", "1.-1.0", "-1.10.0", "12345.0.0", "1.12345.0", "0.0.12345",
            "١.١.٠", // Arabic-Indic digits: not ASCII bytes
            String(repeating: "9", count: 200),
            "1.10.0;evil",
        ]
        for value in bad {
            XCTAssertFalse(
                ClaudeRemotePluginVersionCodec.isAcceptableVersion(value),
                "'\(value)' must not pass as a version"
            )
        }
    }

    func testReportCarriesAValidValueAndCollapsesEverythingElseOntoAbsent() {
        func report(_ headers: [String: String]) -> ClaudeRemotePluginVersionReport {
            ClaudeRemotePluginVersionCodec.report(in: headers)
        }
        XCTAssertEqual(
            report(["x-lvx-plugin-version": "1.10.0"]), .version("1.10.0")
        )
        // Absent header, empty value, malformed value: one answer, because
        // "cannot state a version" is one fact — a plugin from before the
        // header existed.
        XCTAssertEqual(report([:]), .headerAbsent)
        XCTAssertEqual(report(["x-lvx-plugin-version": ""]), .headerAbsent)
        XCTAssertEqual(report(["x-lvx-plugin-version": "1.10"]), .headerAbsent)
        XCTAssertEqual(report(["x-lvx-plugin-version": "evil\r\nX-Evil: 1"]), .headerAbsent)
        // Keyed exactly as the HTTP parser keys headers; no case games.
        XCTAssertEqual(report(["X-Lvx-Plugin-Version": "1.10.0"]), .headerAbsent)
    }
}
