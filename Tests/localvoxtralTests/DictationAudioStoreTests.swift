import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class DictationAudioStoreTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])
    /// The deletes and sweeps below save both files: an id counts as stored
    /// while either folder holds its file, so a full-quality file left
    /// behind fails the same `storedIDs()` assertion as a 16 kHz one.
    private let fullQuality = FullQualityAudio(
        pcm16: Data([1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0]), sampleRate: 48_000)

    private func makeStores() throws -> (DictationSessionStore, DictationAudioStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-audio-\(UUID().uuidString)", isDirectory: true)
        let audio = DictationAudioStore(directoryURL: directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: audio.fullQualityDirectoryURL)
        }
        let store = try XCTUnwrap(DictationSessionStore.inMemory())
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
        let fetched = await store.audioSummary()
        let summary = try XCTUnwrap(fetched)
        XCTAssertEqual(summary.recordings, 1)
        XCTAssertEqual(summary.bytes, 44 + pcm.count)
    }

    /// The 16 kHz file stays where the replay eval reads it; the
    /// full-quality one sits under the same name in the sibling folder and
    /// names its own rate. The Settings row counts one dictation and both
    /// files' bytes.
    func testFullQualityAudioIsWrittenBesideTheSixteenKilohertzFile() async throws {
        let (store, audio) = try makeStores()
        let saved = record("hello")
        await store.save(saved, audio: pcm, fullQualityAudio: fullQuality).value

        XCTAssertEqual(try Data(contentsOf: audio.fileURL(for: saved.id)), DictationAudioRecording.wav(fromPCM16: pcm))
        XCTAssertEqual(
            audio.fullQualityFileURL(for: saved.id).deletingLastPathComponent().lastPathComponent,
            "\(audio.directoryURL.lastPathComponent)-full-quality")
        XCTAssertEqual(
            try Data(contentsOf: audio.fullQualityFileURL(for: saved.id)),
            DictationAudioRecording.wav(fromPCM16: fullQuality.pcm16, sampleRate: 48_000))
        let fetched = await store.audioSummary()
        let summary = try XCTUnwrap(fetched)
        XCTAssertEqual(summary.recordings, 1)
        XCTAssertEqual(summary.bytes, 44 + pcm.count + 44 + fullQuality.pcm16.count)
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
        store.save(kept, audio: pcm, fullQualityAudio: fullQuality)
        store.save(deleted, audio: pcm, fullQualityAudio: fullQuality)
        await store.delete(id: deleted.id).value

        XCTAssertEqual(audio.storedIDs(), [kept.id])
    }

    func testRetentionDeletesTheAudioOfTheDictationsItTrims() async throws {
        let (store, audio) = try makeStores()
        let old = record("old", daysAgo: 40)
        let recent = record("recent", daysAgo: 1)
        store.save(old, audio: pcm, fullQualityAudio: fullQuality)
        store.save(recent, audio: pcm, fullQualityAudio: fullQuality)
        await store.trim(olderThan: origin.addingTimeInterval(-30 * day)).value

        XCTAssertEqual(audio.storedIDs(), [recent.id])
        let entries = await store.entries()
        XCTAssertEqual(entries.map(\.rawText), ["recent"])
    }

    func testTrimAlsoDeletesAudioWhoseDictationIsAlreadyGone() async throws {
        let (store, audio) = try makeStores()
        let orphan = UUID()
        try audio.write(pcm16: pcm, for: orphan)
        try audio.write(fullQuality: fullQuality, for: orphan)
        let recent = record("recent")
        store.save(recent, audio: pcm, fullQualityAudio: fullQuality)
        await store.trim(olderThan: origin.addingTimeInterval(-30 * day)).value

        XCTAssertEqual(audio.storedIDs(), [recent.id])
    }

    func testTheLaunchSweepDeletesOnlyAudioWithoutADictation() async throws {
        let (store, audio) = try makeStores()
        let orphan = UUID()
        // Its full-quality file only: an id with one file is still stored.
        try audio.write(fullQuality: fullQuality, for: orphan)
        let kept = record("kept")
        await store.save(kept, audio: pcm, fullQualityAudio: fullQuality).value
        let torn = audio.directoryURL.appendingPathComponent(".dat.nosync1234.tmp")
        try Data([0]).write(to: torn)
        let tornFullQuality = audio.fullQualityDirectoryURL.appendingPathComponent(".dat.nosync5678.tmp")
        try Data([0]).write(to: tornFullQuality)
        // Far past the file's time: an old leftover, not another copy's write.
        store.now = { Date(timeIntervalSince1970: 4_000_000_000) }
        await store.removeOrphanedAudio().value

        XCTAssertEqual(audio.storedIDs(), [kept.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.fullQualityFileURL(for: kept.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: torn.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tornFullQuality.path))
    }

    /// An empty store beside recordings lost its rows; it is not a user who
    /// deleted everything, since Delete All removes the files itself. The
    /// sweep that trusted it deleted every recording after #985's wipe.
    func testTheLaunchSweepKeepsEveryRecordingWhenTheStoreIsEmpty() async throws {
        let (store, audio) = try makeStores()
        let ids = [UUID(), UUID()]
        for id in ids { try audio.write(pcm16: pcm, for: id) }
        await store.removeOrphanedAudio().value
        await store.trim(olderThan: origin).value

        XCTAssertEqual(audio.storedIDs(), Set(ids))
    }

    /// The guard above must not keep what retention deletes: a trim that
    /// empties the store still deletes the audio of what it trimmed.
    func testRetentionThatTrimsEveryDictationDeletesTheirAudio() async throws {
        let (store, audio) = try makeStores()
        store.save(record("old", daysAgo: 40), audio: pcm, fullQualityAudio: fullQuality)
        store.save(record("older", daysAgo: 50), audio: pcm, fullQualityAudio: fullQuality)
        await store.trim(olderThan: origin.addingTimeInterval(-30 * day)).value

        XCTAssertEqual(audio.storedIDs(), [])
        let count = await store.count()
        XCTAssertEqual(count, 0)
    }

    func testDeleteAllAndTurningAudioOffDeleteEveryRecording() async throws {
        let (store, audio) = try makeStores()
        store.save(record("one", daysAgo: 1), audio: pcm, fullQualityAudio: fullQuality)
        store.save(record("two"), audio: pcm, fullQualityAudio: fullQuality)

        await store.deleteAllAudio().value
        XCTAssertEqual(audio.storedIDs(), [])
        let kept = await store.count()
        XCTAssertEqual(kept, 2, "turning audio off keeps the dictations")

        store.save(record("three"), audio: pcm, fullQualityAudio: fullQuality)
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
        viewModel.phase = .finalizing
        viewModel.transcript.currentDictationEventText = "hello"
        viewModel.session.finishStoppedSession(promotePendingSegment: false)
    }

    func testAStoppedSessionSavesWhatTheMicrophoneCaptured() async throws {
        let (viewModel, audio) = try makeViewModel(audioEnabled: true)
        var saved: DictationSessionRecord?
        viewModel.dependencies.onSessionRecord = { saved = $0 }
        viewModel.session.latchSessionAudio(outputMode: .overlayBuffer)
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
        viewModel.session.latchSessionAudio(outputMode: .overlayBuffer)
        viewModel.session.audio.sessionRecording.append(pcm)
        viewModel.settings.dictationAudioEnabled = false

        stopOverlaySession(viewModel)
        let count = await viewModel.sessionStore?.count()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(audio.storedIDs(), [])
    }
}
