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

    /// The dictation language persists, and a session sends it only while the
    /// selected model takes it (Nemotron Unified), never to Voxtral.
    @MainActor
    func testDictationLanguagePersistsAndReachesOnlyAModelThatTakesIt() {
        let defaults = makeSettingsDefaults()
        let settings = makeSettings(defaults: defaults)
        settings.dictationBackendMode = .managedLocal
        XCTAssertEqual(settings.dictationLanguage, "")
        XCTAssertNil(settings.sessionDictationLanguage)

        settings.dictationLanguage = "fr"
        settings.managedSpeechModel = "T0mSIlver/nemotron-labs-unified-asr-0.6b-8bit"
        XCTAssertEqual(settings.sessionDictationLanguage, "fr")

        settings.managedSpeechModel = SpeechModelCatalog.defaultOption.repoID
        XCTAssertNil(settings.sessionDictationLanguage)

        let relaunched = makeSettings(defaults: defaults)
        XCTAssertEqual(relaunched.dictationLanguage, "fr")
    }

    /// A repo this build doesn't know may be one a newer build added (#1040):
    /// this build launches the default but leaves the stored choice alone.
    @MainActor
    func testStoredRepoOutsideTheCatalogIsKeptInDefaults() {
        let defaults = makeSettingsDefaults()
        defaults.set("someone/newer-model", forKey: "settings.managed_speech_model")

        let settings = makeSettings(defaults: defaults)

        XCTAssertEqual(settings.resolvedManagedSpeechModel, SpeechModelCatalog.defaultOption)
        XCTAssertEqual(settings.managedSpeechModel, SpeechModelCatalog.defaultOption.repoID)
        XCTAssertEqual(defaults.string(forKey: "settings.managed_speech_model"), "someone/newer-model")
    }
}
