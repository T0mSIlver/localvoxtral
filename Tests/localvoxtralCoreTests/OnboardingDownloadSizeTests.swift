import XCTest

@testable import localvoxtralCore

/// The Downloads page names what each item fetches before it starts, read
/// from the catalog entry the user's settings select.
final class OnboardingDownloadSizeTests: XCTestCase {
    func testEachItemReportsTheSelectedModelsSize() {
        let speech = SpeechModelCatalog.defaultOption
        let polish = PolishModelCatalog.defaultOption

        XCTAssertEqual(
            OnboardingItemID.dictation.downloadSizeLabel(
                speechModel: speech.repoID, polishModel: polish.repoID),
            ModelSizeLabel.gigabytes(speech.sizeOnDiskGB))
        XCTAssertEqual(
            OnboardingItemID.polishing.downloadSizeLabel(
                speechModel: speech.repoID, polishModel: polish.repoID),
            ModelSizeLabel.gigabytes(polish.sizeOnDiskGB))
    }

    func testFollowsANonDefaultPick() throws {
        let nemotron = try XCTUnwrap(SpeechModelCatalog.options.first { $0.engine == .nemotron })
        let smallest = try XCTUnwrap(PolishModelCatalog.options.min { $0.sizeOnDiskGB < $1.sizeOnDiskGB })

        XCTAssertEqual(
            OnboardingItemID.dictation.downloadSizeLabel(
                speechModel: nemotron.repoID, polishModel: smallest.repoID),
            ModelSizeLabel.gigabytes(nemotron.sizeOnDiskGB))
        XCTAssertEqual(
            OnboardingItemID.polishing.downloadSizeLabel(
                speechModel: nemotron.repoID, polishModel: smallest.repoID),
            ModelSizeLabel.gigabytes(smallest.sizeOnDiskGB))
    }

    func testAModelOutsideTheCatalogHasNoSize() {
        XCTAssertNil(
            OnboardingItemID.dictation.downloadSizeLabel(
                speechModel: "someone/unknown", polishModel: "someone/unknown"))
        XCTAssertNil(
            OnboardingItemID.polishing.downloadSizeLabel(
                speechModel: "someone/unknown", polishModel: "someone/unknown"))
    }
}
