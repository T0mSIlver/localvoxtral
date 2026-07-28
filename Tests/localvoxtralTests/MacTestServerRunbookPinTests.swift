import Foundation
import XCTest
@testable import localvoxtral

/// `scripts/mac/README.md` is the owner runbook for the on-demand test
/// services, and it embeds complete launchd plists plus `hf download` commands
/// with model pins. Its own rule — "keep these pins in sync with
/// `SpeechModelCatalog.defaultOption` and `PolishModelCatalog.defaultOption`" —
/// drifted almost immediately: #169 moved the speech default to the qhead
/// repo while the runbook kept the pin #176 had installed, so anyone
/// installing from the runbook verbatim would silently reintroduce the old
/// model and tier-1 would measure a backend production no longer ships.
/// Prose sync rules drift; these assertions do not.
///
/// Pins are checked as PER-SERVICE (repo, revision) PAIRS, never as
/// independent sets: independent sets would accept the two services'
/// revisions swapped — a runbook state where `hf download` rejects both
/// commands and both services relaunch-loop on a missing snapshot.
final class MacTestServerRunbookPinTests: XCTestCase {
    private struct ServicePin {
        let binary: String
        let repoID: String
        let revision: String
    }

    private var expectedPins: [ServicePin] {
        [
            ServicePin(
                binary: "localvoxtral-speechd",
                repoID: SpeechModelCatalog.defaultOption.repoID,
                revision: SpeechModelCatalog.defaultOption.revision
            ),
            ServicePin(
                binary: "localvoxtral-polishd",
                repoID: PolishModelCatalog.defaultOption.repoID,
                revision: PolishModelCatalog.defaultOption.revision
            ),
        ]
    }

    private func runbook() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // localvoxtralTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        return try String(
            contentsOf: root.appendingPathComponent("scripts/mac/README.md"),
            encoding: .utf8
        )
    }

    /// The plist window for one service: from its binary path to the close of
    /// that `ProgramArguments` array. Scoping the search here is what makes a
    /// stray mention elsewhere in the doc (prose, comments, another snippet)
    /// unable to satisfy the assertion.
    private func serviceWindow(binary: String, in text: String) throws -> String {
        let anchor = try XCTUnwrap(
            text.range(of: "/\(binary)</string>"),
            "the runbook must embed a plist running \(binary)"
        )
        let tail = text[anchor.upperBound...]
        let end = try XCTUnwrap(
            tail.range(of: "</array>"),
            "\(binary)'s ProgramArguments array never closes"
        )
        return String(tail[..<end.lowerBound])
    }

    /// The single value of `<string>FLAG</string> <string>VALUE</string>`
    /// inside `window`, tolerant of the value landing on the next line.
    /// Exactly one occurrence — zero means the pin is gone, two means the
    /// window boundary or the plist grew ambiguous; both must fail loudly.
    private func plistValue(
        after flag: String, inWindow window: String, service: String
    ) throws -> String {
        let pattern = "<string>\(NSRegularExpression.escapedPattern(for: flag))</string>"
            + "\\s*<string>([^<]+)</string>"
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(
            in: window, range: NSRange(window.startIndex..., in: window)
        )
        XCTAssertEqual(
            matches.count, 1,
            "\(service): expected exactly one \(flag) in its plist block, found \(matches.count)"
        )
        let match = try XCTUnwrap(matches.first)
        let valueRange = try XCTUnwrap(Range(match.range(at: 1), in: window))
        return String(window[valueRange])
    }

    func testEachServicePlistPinsItsOwnCatalogDefault() throws {
        // Pairing, per service: speechd's block must carry speechd's repo AND
        // revision, polishd's block polishd's. A swapped pair, a stale value,
        // and a missing service section each fail on their own line.
        let text = try runbook()
        for pin in expectedPins {
            let window = try serviceWindow(binary: pin.binary, in: text)
            XCTAssertEqual(
                try plistValue(after: "--model", inWindow: window, service: pin.binary),
                pin.repoID,
                "\(pin.binary) plist must run the current catalog default repo"
            )
            XCTAssertEqual(
                try plistValue(after: "--model-revision", inWindow: window, service: pin.binary),
                pin.revision,
                "\(pin.binary) plist must pin the current catalog revision"
            )
        }
    }

    func testEveryDownloadCommandIsACatalogDefaultPair() throws {
        // The pre-download step is what puts weights where launchd's services
        // can load them; a stale or cross-wired pair makes a service
        // relaunch-loop on a missing snapshot with nothing in the runbook to
        // explain it. Repo and revision are matched as one command-level pair
        // (the `\` continuation puts --revision on the following line), and
        // the complete mapping must equal the catalog defaults — a swapped,
        // extra, or missing pair all fail.
        let text = try runbook()
        let pattern = "hf download (\\S+) \\\\\\s*--revision ([0-9a-f]{40})"
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var downloaded: [String: String] = [:]
        for match in matches {
            let repoRange = try XCTUnwrap(Range(match.range(at: 1), in: text))
            let revisionRange = try XCTUnwrap(Range(match.range(at: 2), in: text))
            downloaded[String(text[repoRange])] = String(text[revisionRange])
        }
        XCTAssertEqual(
            downloaded,
            Dictionary(uniqueKeysWithValues: expectedPins.map { ($0.repoID, $0.revision) }),
            "the runbook's hf download pairs must be exactly the catalog defaults"
        )
    }
}
