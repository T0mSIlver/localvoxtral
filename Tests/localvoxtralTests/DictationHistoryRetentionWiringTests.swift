import Foundation
import XCTest
@testable import localvoxtral

/// What applying the History settings deletes: at launch, when the History
/// window opens, and after each save.
@MainActor
final class DictationHistoryRetentionWiringTests: XCTestCase {
    private let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])

    private func record(_ text: String) -> DictationSessionRecord {
        let startedAt = Date().addingTimeInterval(-60)
        return DictationSessionRecord(
            startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(5), rawText: text,
            provider: "p", model: "m", outputMode: "overlay_buffer", status: .completed,
            commitSucceeded: true)
    }

    private func makeViewModel(settings: SettingsStore) throws -> (DictationViewModel, DictationSessionStore) {
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        let store = try XCTUnwrap(DictationSessionStore.inMemory())
        viewModel.sessionStore = store
        return (viewModel, store)
    }

    /// Two running copies share the defaults. The one still holding Don't
    /// keep from its launch must not delete what the other copy now keeps
    /// (#1569).
    func testAStaleCopyAppliesTheRetentionAnotherCopySaved() async throws {
        let defaults = makeSettingsDefaults()
        let staleCopy = makeSettings(defaults: defaults)
        staleCopy.dictationHistoryRetention = .off
        let otherCopy = makeSettings(defaults: defaults)
        otherCopy.dictationHistoryRetention = .forever
        let (viewModel, store) = try makeViewModel(settings: staleCopy)
        await store.save(record("kept by the other copy")).value

        viewModel.applyDictationHistoryRetention()
        await store.pendingWrites?.value

        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.rawText), ["kept by the other copy"])
        XCTAssertEqual(staleCopy.dictationHistoryRetention, .forever)
    }

    /// The audio switch went off but its delete failed: the next pass deletes
    /// the recordings and keeps the dictations (#1573).
    func testApplyingRetentionDeletesAudioLeftAfterTheSwitchWentOff() async throws {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.dictationHistoryRetention = .forever
        settings.dictationAudioEnabled = false
        let (viewModel, store) = try makeViewModel(settings: settings)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-audio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let audio = DictationAudioStore(directoryURL: directory)
        store.audioStore = audio
        let saved = record("kept")
        await store.save(saved, audio: pcm).value
        XCTAssertEqual(audio.storedIDs(), [saved.id])

        viewModel.applyDictationHistoryRetention()
        await store.pendingWrites?.value

        XCTAssertEqual(audio.storedIDs(), [])
        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.rawText), ["kept"])
    }

    /// Don't keep deletes the History snapshots too, and takes none: a copy
    /// would keep what the user asked not to keep (#1574).
    func testDontKeepLeavesNoSnapshot() async throws {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let (viewModel, _) = try makeViewModel(settings: settings)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-history-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try DictationSessionStore.open(directory: directory, now: { now }).get()
        viewModel.sessionStore = store
        let started = now.addingTimeInterval(-60)
        await store.save(DictationSessionRecord(
            startedAt: started, finishedAt: started.addingTimeInterval(5), rawText: "private",
            provider: "p", model: "m", outputMode: "overlay_buffer", status: .completed,
            commitSucceeded: true)).value
        let backups = try XCTUnwrap(store.backups)
        backups.snapshot(of: try XCTUnwrap(store.storeURL), reason: .daily)
        XCTAssertTrue(backups.snapshots().contains { $0.dictations == 1 })

        settings.dictationHistoryRetention = .off
        viewModel.applyDictationHistoryRetention(now: now)
        await store.pendingWrites?.value

        XCTAssertEqual(backups.snapshots(), [])
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    /// The same for the audio switch: a copy that launched with it off
    /// keeps the recordings another copy now saves.
    func testAStaleCopyKeepsTheAudioAnotherCopyTurnedOn() async throws {
        let defaults = makeSettingsDefaults()
        let staleCopy = makeSettings(defaults: defaults)
        staleCopy.dictationHistoryRetention = .forever
        staleCopy.dictationAudioEnabled = false
        let otherCopy = makeSettings(defaults: defaults)
        otherCopy.dictationAudioEnabled = true
        let (viewModel, store) = try makeViewModel(settings: staleCopy)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-audio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let audio = DictationAudioStore(directoryURL: directory)
        store.audioStore = audio
        let saved = record("recorded by the other copy")
        await store.save(saved, audio: pcm).value

        viewModel.applyDictationHistoryRetention()
        await store.pendingWrites?.value

        XCTAssertEqual(audio.storedIDs(), [saved.id])
        XCTAssertTrue(staleCopy.dictationAudioEnabled)
    }
}
