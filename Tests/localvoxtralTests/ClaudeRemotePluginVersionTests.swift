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

    // MARK: - Ordering
    //
    // One comparison, two consumers: the registry's monotone per-host record
    // and the Settings model's outdated verdict. If they ever disagreed about
    // which of two versions is older, the row could contradict the record
    // underneath it.

    func testVersionComparisonIsNumericPerComponent() {
        let older = { (version: String) in
            ClaudeRemotePluginVersionCodec.isVersion(version, olderThan: "1.10.0")
        }
        // 9 < 10 numerically, not "9" < "10" as text.
        XCTAssertTrue(older("1.9.0"))
        XCTAssertTrue(older("1.9.9"))
        XCTAssertTrue(older("1.9.99"))
        XCTAssertFalse(older("1.10.0"))
        XCTAssertFalse(older("1.10.1"))
        XCTAssertFalse(older("2.0.0"))
        XCTAssertFalse(older("1.11.0"))
        // Anything unparseable answers "not older" — the conservative reading,
        // because a false update hint costs trust. (A malformed report cannot
        // reach this comparison anyway: the codec records only strict-shape
        // values.)
        XCTAssertFalse(older("1.10.0-beta"))
        XCTAssertFalse(older("nonsense"))
        XCTAssertFalse(older("1.10"))
        XCTAssertFalse(older(""))
    }

    /// The order the never-lower rule is written against: `.headerAbsent` is
    /// the floor, versions order numerically, and only a STRICTLY higher
    /// report may replace a recorded one. What makes it load-bearing: after
    /// "Update Plugin…" a host's already-running sessions still execute the
    /// old plugin's shim, so header-less hooks from the OLD generation keep
    /// arriving after the new version is on disk.
    func testReportsOrderWithHeaderAbsentBelowEveryVersion() {
        XCTAssertTrue(ClaudeRemotePluginVersionReport.headerAbsent < .version("1.9.0"))
        XCTAssertFalse(ClaudeRemotePluginVersionReport.version("1.9.0") < .headerAbsent)
        XCTAssertFalse(ClaudeRemotePluginVersionReport.headerAbsent < .headerAbsent)

        XCTAssertTrue(ClaudeRemotePluginVersionReport.version("1.9.0") < .version("1.10.0"))
        XCTAssertFalse(ClaudeRemotePluginVersionReport.version("1.10.0") < .version("1.9.0"))
        XCTAssertFalse(ClaudeRemotePluginVersionReport.version("1.10.0") < .version("1.10.0"))

        // Strictly higher is what replaces; equal is not.
        XCTAssertTrue(ClaudeRemotePluginVersionReport.version("1.9.0") > .headerAbsent)
        XCTAssertTrue(ClaudeRemotePluginVersionReport.version("2.0.0") > .version("1.99.99"))
    }
}
