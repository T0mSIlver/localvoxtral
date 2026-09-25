import Foundation
import XCTest
@testable import localvoxtralCore

final class PolishModelCatalogTests: XCTestCase {
    func testCatalogLookupAndDefaultOption() {
        let defaultOption = PolishModelCatalog.defaultOption

        // Owner decision 2026-07-11: the 4B is the default for ALL users.
        XCTAssertEqual(defaultOption.repoID, "mlx-community/Qwen3.5-4B-OptiQ-4bit")
        XCTAssertEqual(PolishModelCatalog.option(forRepoID: defaultOption.repoID), defaultOption)
        XCTAssertNil(PolishModelCatalog.option(forRepoID: "unknown/model"))
        // Greedy decoding scored the same as temperature 0.3 on both polish
        // corpora (#533) and repeats exactly (#563). Only the temperature is
        // set: Qwen's recommended sampling lost to it on the eval (#97).
        for option in PolishModelCatalog.options {
            XCTAssertEqual(
                option.samplingDefaults, PolishSamplingDefaults(temperature: 0), option.repoID)
        }
        XCTAssertEqual(defaultOption.chatTemplateArguments, ["enable_thinking": false])
        // The 0.8B stays selectable with its legacy request shape (nil kwargs).
        XCTAssertNil(
            PolishModelCatalog.option(
                forRepoID: "mlx-community/Qwen3.5-0.8B-8bit"
            )?.chatTemplateArguments
        )
    }

    /// Every catalog model names an exact commit. A bare repo id tracks main,
    /// and upstream rewriting model.safetensors.index.json is precisely how
    /// the polish helper started dying on load (2026-07-14).
    func testEveryCatalogOptionPinsACommitRevision() {
        for option in PolishModelCatalog.options {
            XCTAssertEqual(
                option.revision.count,
                40,
                "\(option.repoID) must pin a full commit sha, got '\(option.revision)'"
            )
            XCTAssertTrue(
                option.revision.allSatisfy(\.isHexDigit),
                "\(option.repoID) pin is not a sha: '\(option.revision)'"
            )
        }
    }

    func testPickerEntriesAppendCustomStoredModelWithoutRewritingIt() {
        let customRepoID = "example/custom-polisher"

        let entries = PolishModelPickerSupport.entries(storedRepoID: customRepoID)

        XCTAssertEqual(entries.count, PolishModelCatalog.options.count + 1)
        XCTAssertEqual(entries.last?.repoID, customRepoID)
        XCTAssertEqual(entries.last?.label, "Custom: \(customRepoID)")
        XCTAssertNil(entries.last?.option)
    }

    func testPickerEntriesDoNotDuplicateCatalogModel() {
        let entries = PolishModelPickerSupport.entries(
            storedRepoID: PolishModelCatalog.defaultOption.repoID
        )

        XCTAssertEqual(entries.count, PolishModelCatalog.options.count)
    }
}
