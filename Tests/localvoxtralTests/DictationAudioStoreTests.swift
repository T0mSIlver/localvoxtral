import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class DictationAudioStoreTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])

    private func makeStores() throws -> (DictationSessionStore, DictationAudioStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-audio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let audio = DictationAudioStore(directoryURL: directory)
        let store = try XCTUnwrap(DictationSessionStore(inMemory: true))
        store.audioStore = audio
        return (store, audio)
    }

    private func record(_ text: String, daysAgo: Double = 0) -> DictationSessionRecord {
        let startedAt = origin.addingTimeInterval(-daysAgo * day)
        return DictationSessionRecord(
            startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(5), rawText: text,
            provider: "p", model: "m", outputMode: "overlay_buffer", status: .completed,
            commitSucceeded: true)
    }

    func testAudioIsWrittenBesideItsRecordAsWAV() async throws {
        let (store, audio) = try makeStores()
        let saved = record("hello")
        await store.save(saved, audio: pcm).value

        let wav = try Data(contentsOf: audio.fileURL(for: saved.id))
        XCTAssertEqual(wav, DictationAudioRecording.wav(fromPCM16: pcm))
        let summary = await store.audioSummary()
        XCTAssertEqual(summary.recordings, 1)
        XCTAssertEqual(summary.bytes, 44 + pcm.count)
    }

    func testARecordSavedWithoutAudioLeavesNoFile() async throws {
        let (store, audio) = try makeStores()
        await store.save(record("hello")).value

        XCTAssertEqual(audio.storedIDs(), [])
    }

    func testDeletingADictationDeletesItsAudioOnly() async throws {
        let (store, audio) = try makeStores()
        let kept = record("kept", daysAgo: 1)
        let deleted = record("deleted")
        store.save(kept, audio: pcm)
        store.save(deleted, audio: pcm)
        await store.delete(id: deleted.id).value

        XCTAssertEqual(audio.storedIDs(), [kept.id])
    }

    func testRetentionDeletesTheAudioOfTheDictationsItTrims() async throws {
        let (store, audio) = try makeStores()
        let old = record("old", daysAgo: 40)
        let recent = record("recent", daysAgo: 1)
        store.save(old, audio: pcm)
        store.save(recent, audio: pcm)
        await store.trim(olderThan: origin.addingTimeInterval(-30 * day)).value

        XCTAssertEqual(audio.storedIDs(), [recent.id])
        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.rawText), ["recent"])
    }

    func testTrimAlsoDeletesAudioWhoseDictationIsAlreadyGone() async throws {
        let (store, audio) = try makeStores()
        let orphan = UUID()
        try audio.write(pcm16: pcm, for: orphan)
        let recent = record("recent")
        store.save(recent, audio: pcm)
        await store.trim(olderThan: origin.addingTimeInterval(-30 * day)).value

        XCTAssertEqual(audio.storedIDs(), [recent.id])
    }

    func testTheLaunchSweepDeletesOnlyAudioWithoutADictation() async throws {
        let (store, audio) = try makeStores()
        let orphan = UUID()
        try audio.write(pcm16: pcm, for: orphan)
        let kept = record("kept")
        await store.save(kept, audio: pcm).value
        let torn = audio.directoryURL.appendingPathComponent(".dat.nosync1234.tmp")
        try Data([0]).write(to: torn)
        await store.removeOrphanedAudio().value

        XCTAssertEqual(audio.storedIDs(), [kept.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: torn.path))
    }

    func testDeleteAllAndTurningAudioOffDeleteEveryRecording() async throws {
        let (store, audio) = try makeStores()
        store.save(record("one", daysAgo: 1), audio: pcm)
        store.save(record("two"), audio: pcm)

        await store.deleteAllAudio().value
        XCTAssertEqual(audio.storedIDs(), [])
        let kept = await store.count()
        XCTAssertEqual(kept, 2, "turning audio off keeps the dictations")

        store.save(record("three"), audio: pcm)
        await store.deleteAll().value
        XCTAssertEqual(audio.storedIDs(), [])
    }

    // MARK: - The session

    private func makeViewModel(audioEnabled: Bool) throws
        -> (DictationViewModel, DictationAudioStore)
    {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.dictationAudioEnabled = audioEnabled
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)
        let (store, audio) = try makeStores()
        viewModel.sessionStore = store
        return (viewModel, audio)
    }

    private func stopOverlaySession(_ viewModel: DictationViewModel) {
        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = "hello"
        viewModel.session.finishStoppedSession(promotePendingSegment: false)
    }

    func testAStoppedSessionSavesWhatTheMicrophoneCaptured() async throws {
        let (viewModel, audio) = try makeViewModel(audioEnabled: true)
        var saved: DictationSessionRecord?
        viewModel.dependencies.onSessionRecord = { saved = $0 }
        viewModel.session.audio.sessionRecording.begin(enabled: true)
        viewModel.session.audio.sessionRecording.append(pcm)

        stopOverlaySession(viewModel)
        _ = await viewModel.sessionStore?.count()

        let id = try XCTUnwrap(saved?.id)
        XCTAssertEqual(audio.storedIDs(), [id])
        XCTAssertEqual(
            try Data(contentsOf: audio.fileURL(for: id)),
            DictationAudioRecording.wav(fromPCM16: pcm))
    }

    func testTurningAudioOffMidSessionKeepsThatSessionsAudioOut() async throws {
        let (viewModel, audio) = try makeViewModel(audioEnabled: true)
        viewModel.session.audio.sessionRecording.begin(enabled: true)
        viewModel.session.audio.sessionRecording.append(pcm)
        viewModel.settings.dictationAudioEnabled = false

        stopOverlaySession(viewModel)
        let count = await viewModel.sessionStore?.count()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(audio.storedIDs(), [])
    }
}
