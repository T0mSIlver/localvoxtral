import XCTest

@testable import localvoxtral

/// The speech model choice as `SettingsStore` persists it; the catalog itself
/// is tested in `SpeechModelCatalogTests` (localvoxtralCoreTests).
final class SpeechModelSelectionSettingsTests: XCTestCase {
    @MainActor
    func testManagedSpeechModelSelectionPersistsAcrossLaunches() throws {
        let defaults = makeSettingsDefaults()
        let settings = makeSettings(defaults: defaults)
        XCTAssertEqual(settings.resolvedManagedSpeechModel, SpeechModelCatalog.defaultOption)

        let nemotron = try XCTUnwrap(
            SpeechModelCatalog.option(
                forRepoID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
            )
        )
        settings.managedSpeechModel = nemotron.repoID

        let relaunched = makeSettings(defaults: defaults)
        XCTAssertEqual(relaunched.resolvedManagedSpeechModel, nemotron)
        // Managed mode reports the selected repo as the session's model name.
        relaunched.dictationBackendMode = .managedLocal
        XCTAssertEqual(relaunched.effectiveModelName(for: .realtimeAPI), nemotron.repoID)
    }

    @MainActor
    func testStoredRepoOutsideTheCatalogFallsBackToTheDefault() {
        let defaults = makeSettingsDefaults()
        defaults.set("someone/retired-model", forKey: "settings.managed_speech_model")

        let settings = makeSettings(defaults: defaults)

        XCTAssertEqual(settings.resolvedManagedSpeechModel, SpeechModelCatalog.defaultOption)
        XCTAssertEqual(settings.managedSpeechModel, SpeechModelCatalog.defaultOption.repoID)
    }
}
