import XCTest

@testable import localvoxtral

final class SpeechModelCatalogTests: XCTestCase {
    func testManagedCatalogContainsOnlyBundledHelpers() {
        XCTAssertEqual(BackendCatalog.speechd.displayName, "Dictation engine")
        XCTAssertEqual(BackendCatalog.speechd.executableName, "localvoxtral-speechd")
        XCTAssertEqual(BackendCatalog.speechd.port, 8471)
        XCTAssertEqual(BackendCatalog.all.map(\.id), ["speechd", "polishd"])
        XCTAssertEqual(BackendCatalog.polishd.executableName, "localvoxtral-polishd")
    }

    func testSpeechModelCatalogPinsFullCommitSHA() {
        let option = SpeechModelCatalog.defaultOption
        XCTAssertEqual(option.repoID, "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead")
        XCTAssertEqual(option.engine, .voxtral)
        XCTAssertEqual(option.revision.count, 40)
        XCTAssertTrue(option.revision.allSatisfy(\.isHexDigit))
    }

    /// The build host serves one test service per row of this list, and eval-e2e
    /// scores whichever one it names. A catalog model without a row cannot be
    /// scored there, and a stale row serves weights the app no longer ships.
    func testBuildHostServesEveryCatalogModelAtItsPin() throws {
        let list = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/mac/test-speech-models.tsv")
        let rows = try String(contentsOf: list, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.allSatisfy(\.isWhitespace) }
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }

        XCTAssertTrue(rows.allSatisfy { $0.count == 4 }, "\(rows)")
        XCTAssertEqual(rows.count, SpeechModelCatalog.options.count, "one row per model")
        XCTAssertEqual(
            Set(rows.map { "\($0[2])@\($0[3])" }),
            Set(SpeechModelCatalog.options.map { "\($0.repoID)@\($0.revision)" })
        )
        XCTAssertEqual(Set(rows.map { $0[0] }).count, rows.count, "names must be unique")
        XCTAssertEqual(Set(rows.map { $0[1] }).count, rows.count, "ports must be unique")
        // lv-test-servers.sh and the build gate accept 8000-8079 only.
        XCTAssertTrue(
            rows.allSatisfy { Int($0[1]).map { (8000...8079).contains($0) } ?? false },
            "ports must stay in 8000-8079"
        )
        // CI and older build gates reach Voxtral on 8000 without reading the list.
        XCTAssertEqual(rows.first { $0[0] == "voxtral" }?[1], "8000")
    }

    func testEveryCatalogEntryIsUniqueAndPinnedToACommit() {
        let repoIDs = SpeechModelCatalog.options.map(\.repoID)
        XCTAssertEqual(Set(repoIDs).count, repoIDs.count)
        for option in SpeechModelCatalog.options {
            XCTAssertEqual(option.revision.count, 40, option.repoID)
            XCTAssertTrue(option.revision.allSatisfy(\.isHexDigit), option.repoID)
        }
    }

    func testNemotronEntryPinsItsRevisionAndEngine() throws {
        let option = try XCTUnwrap(
            SpeechModelCatalog.option(
                forRepoID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
            )
        )
        XCTAssertEqual(option.engine, .nemotron)
        XCTAssertEqual(option.revision, "7279359e4481b5e9e185a318bd618e429c6d86cd")
        // The whole point of the second entry: it is the small one.
        XCTAssertLessThan(option.sizeOnDiskGB, SpeechModelCatalog.defaultOption.sizeOnDiskGB)
    }

    /// The helper picks its engine from the repo id it is launched with, so a
    /// catalog entry whose id does not map to its declared engine would load
    /// the wrong model class. The helper's own inference is unit-tested in
    /// `SpeechASREngineKindTests`; this pins the two sides together.
    func testCatalogEngineMatchesTheRepoIDTheHelperInfersFrom() {
        for option in SpeechModelCatalog.options {
            let inferred = option.repoID.lowercased().contains("nemotron")
                ? SpeechEngineKind.nemotron
                : SpeechEngineKind.voxtral
            XCTAssertEqual(option.engine, inferred, option.repoID)
        }
    }

    func testPickerHelpTextNamesTheSizeAndDownloadState() throws {
        let option = try XCTUnwrap(
            SpeechModelCatalog.option(
                forRepoID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
            )
        )
        // The size renders in the user's locale (0.8 / 0,8), so assert around it.
        XCTAssertEqual(option.sizeOnDiskGB, 0.8)
        let pending = SpeechModelPickerSupport.helpText(for: option, isDownloaded: false)
        XCTAssertTrue(pending.hasPrefix("Lowest memory, less accurate. "), pending)
        XCTAssertTrue(pending.hasSuffix(" GB, downloads on first use"), pending)
        XCTAssertTrue(
            SpeechModelPickerSupport.helpText(for: option, isDownloaded: true)
                .hasSuffix(" GB, downloaded")
        )
    }

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

    /// Measured in #486: Voxtral's cache fills to the limit, Nemotron's stays near
    /// 10 MB, so only Voxtral gets the Memory limit row.
    func testOnlyVoxtralShowsTheMemoryLimitRow() {
        let shown = SpeechModelCatalog.options.filter(\.showsMemoryLimit).map(\.engine)
        XCTAssertEqual(shown, [.voxtral])
    }
}
