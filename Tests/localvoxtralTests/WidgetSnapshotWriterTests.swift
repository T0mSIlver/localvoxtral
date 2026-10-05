import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class WidgetSnapshotWriterTests: XCTestCase {
    /// A write still counting when History is turned off must not land after
    /// the History-off write: the widget would show, and copy, the last
    /// dictation's text again.
    func testAWriteCountedBeforeHistoryWentOffDoesNotRestoreTheText() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.dictationHistoryRetention = .forever
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        let store = try XCTUnwrap(DictationSessionStore.inMemory())
        viewModel.sessionStore = store
        await store.save(DictationSessionRecord(
            startedAt: now.addingTimeInterval(-60), finishedAt: now.addingTimeInterval(-50),
            rawText: "the secret plan", provider: "test", model: "test",
            outputMode: DictationOutputMode.overlayBuffer.rawValue,
            status: .completed, commitSucceeded: true
        )).value

        let counting = BoundedWait()
        let release = BoundedWait()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let writer = WidgetSnapshotWriter(
            viewModel: viewModel,
            fileURL: fileURL,
            reloadTimelines: {},
            sleep: { _ in },
            countHistory: { entries, terms, now, calendar in
                counting.resolve()
                _ = await release.value(failAfter: 30)
                return WidgetSnapshotAssembler.history(entries: entries, terms: terms, now: now, calendar: calendar)
            },
            now: { now }
        )

        let olderWrite = Task { await writer.write() }
        let reached = await counting.value(failAfter: 30)
        XCTAssertTrue(reached, "the first write never reached counting")
        settings.dictationHistoryRetention = .off
        await writer.write()
        release.resolve()
        await olderWrite.value

        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: fileURL))
        XCTAssertFalse(snapshot.historyKept)
        XCTAssertNil(snapshot.lastDictation)
    }

    /// Quit inside the coalesce wait after History went off: the quit
    /// snapshot must not write back the text the last write still held
    /// (#1572).
    func testQuitRightAfterHistoryWentOffDropsTheText() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.dictationHistoryRetention = .forever
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        let store = try XCTUnwrap(DictationSessionStore.inMemory())
        viewModel.sessionStore = store
        await store.save(DictationSessionRecord(
            startedAt: now.addingTimeInterval(-60), finishedAt: now.addingTimeInterval(-50),
            rawText: "the secret plan", provider: "test", model: "test",
            outputMode: DictationOutputMode.overlayBuffer.rawValue,
            status: .completed, commitSucceeded: true
        )).value
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL) }
        let writer = WidgetSnapshotWriter(
            viewModel: viewModel, fileURL: fileURL, reloadTimelines: {}, sleep: { _ in }, now: { now })
        await writer.write()
        let before = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: fileURL))
        XCTAssertNotNil(before.lastDictation, "the History-on write holds the dictation")

        settings.dictationHistoryRetention = .off
        writer.writeAppQuit()

        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: fileURL))
        XCTAssertFalse(snapshot.engines.appRunning)
        XCTAssertFalse(snapshot.historyKept)
        XCTAssertNil(snapshot.lastDictation)
        XCTAssertEqual(snapshot.dictation, WidgetSnapshot.Dictation())
    }
}
