import Foundation
import XCTest
@testable import localvoxtral

/// `scripts/mac/README.md` is the owner runbook for the on-demand test
/// services, and it embeds complete launchd plists plus `hf download` commands
/// with model pins. Its own rule — "keep these pins in sync with
/// `SpeechModelCatalog.defaultOption` and `PolishModelCatalog.defaultOption`" —
/// drifted almost immediately: #186 moved the speech default to the qhead
/// repo while the runbook kept the retired mlx-community pin, so anyone
/// installing from the runbook verbatim would silently reintroduce the old
/// model and tier-1 would measure a backend production no longer ships.
/// Prose sync rules drift; these assertions do not.
final class MacTestServerRunbookPinTests: XCTestCase {
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

    /// Values from runbook plist lines shaped
    /// `<string>FLAG</string><string>VALUE</string>`.
    private func plistValues(after flag: String, in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let flagRange = line.range(of: "<string>\(flag)</string><string>") else {
                return nil
            }
            let tail = line[flagRange.upperBound...]
            guard let end = tail.range(of: "</string>") else { return nil }
            return String(tail[..<end.lowerBound])
        }
    }

    func testEveryRunbookPlistModelPinIsACurrentCatalogDefault() throws {
        // Set equality both ways: a stale pin fails (it is not a default), and
        // a missing service section fails (a default is not pinned anywhere).
        let text = try runbook()
        XCTAssertEqual(
            Set(plistValues(after: "--model", in: text)),
            [SpeechModelCatalog.defaultOption.repoID, PolishModelCatalog.defaultOption.repoID],
            "every plist --model in the runbook must be a current catalog default"
        )
        XCTAssertEqual(
            Set(plistValues(after: "--model-revision", in: text)),
            [SpeechModelCatalog.defaultOption.revision, PolishModelCatalog.defaultOption.revision],
            "every plist --model-revision in the runbook must be a current catalog pin"
        )
    }

    func testRunbookDownloadCommandsMatchTheCatalogDefaults() throws {
        // The pre-download step is what puts weights where launchd's services
        // can load them; a stale repo here makes the service relaunch-loop on
        // a missing model with nothing in the runbook to explain it.
        let text = try runbook()
        for option in [
            (SpeechModelCatalog.defaultOption.repoID, SpeechModelCatalog.defaultOption.revision),
            (PolishModelCatalog.defaultOption.repoID, PolishModelCatalog.defaultOption.revision),
        ] {
            XCTAssertTrue(
                text.contains("hf download \(option.0)"),
                "the runbook must pre-download \(option.0)"
            )
            XCTAssertTrue(
                text.contains("--revision \(option.1)"),
                "the runbook must pin \(option.0) to revision \(option.1)"
            )
        }
    }
}
