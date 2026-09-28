import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

/// The voice memo folder watcher (#925): which files become captures, when,
/// and that each becomes exactly one, across relaunches.
@MainActor
final class VoiceMemoIntakeTests: XCTestCase {
    private final class Transcriber: VoiceMemoTranscribing, @unchecked Sendable {
        let results = Mutex<[String: Result<String, any Error>]>([:])
        let calls = Mutex<[String]>([])
        func transcribe(_ url: URL) async throws -> VoiceMemoTranscript {
            let name = url.lastPathComponent
            calls.withLock { $0.append(name) }
            let result = results.withLock { $0[name] } ?? .success("words of \(name)")
            return VoiceMemoTranscript(text: try result.get(), pcm16: Data(name.utf8))
        }
    }

    private struct EngineDown: Error {}

    private struct Captured: Equatable {
        let id: UUID
        let text: String
        let recordedAt: Date
        let pcm16: Data
    }

    private let directory = URL(fileURLWithPath: "/memos", isDirectory: true)
    private var workDirectory: URL!
    private var ledgerURL: URL { workDirectory.appendingPathComponent("voice-memos.json") }
    private let transcriber = Transcriber()
    private var files: [VoiceMemoFile] = []
    private var captured: [Captured] = []
    private var trashed: [String] = []
    private var downloadRequests: [String] = []
    private var trashFails = false

    override func setUp() async throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-memo-intake-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func memo(_ name: String, size: Int = 1_000, minute: Double = 0, downloaded: Bool = true) -> VoiceMemoFile {
        VoiceMemoFile(
            name: name, size: size, modifiedAt: Date(timeIntervalSince1970: 1_000_000 + minute * 60),
            isDownloaded: downloaded)
    }

    /// A fresh intake over the same ledger file: what a relaunch sees.
    private func intake() -> VoiceMemoIntake {
        VoiceMemoIntake(
            directory: directory,
            ledgerURL: ledgerURL,
            transcriber: transcriber,
            list: { [unowned self] _ in files },
            requestDownload: { [unowned self] in downloadRequests.append($0.lastPathComponent) },
            removeTranscribed: { [unowned self] url in
                if trashFails { throw CocoaError(.fileWriteNoPermission) }
                trashed.append(url.lastPathComponent)
                files.removeAll { $0.name == url.lastPathComponent }
            },
            inboxHas: { [unowned self] id in captured.contains { $0.id == id } },
            capture: { [unowned self] id, text, recordedAt, pcm in
                captured.append(Captured(id: id, text: text, recordedAt: recordedAt, pcm16: pcm))
            }
        )
    }

    func testANewMemoIsTakenOnceItHeldStillForTwoScansThenMovedToTheTrash() async {
        let intake = intake()
        files = [memo("walk.m4a", minute: 5)]
        let first = await intake.scan()
        XCTAssertEqual(first, 0, "first sighting: iCloud may still be writing it")
        XCTAssertEqual(transcriber.calls.withLock { $0 }, [])

        let second = await intake.scan()
        XCTAssertEqual(second, 1)
        XCTAssertEqual(captured.map(\.text), ["words of walk.m4a"])
        XCTAssertEqual(captured.first?.recordedAt, Date(timeIntervalSince1970: 1_000_300), "dated when recorded")
        XCTAssertEqual(captured.first?.pcm16, Data("walk.m4a".utf8), "the audio goes with the capture")
        XCTAssertEqual(trashed, ["walk.m4a"])

        _ = await intake.scan()
        XCTAssertEqual(captured.count, 1)
    }

    func testAMemoStillGrowingOrStillInICloudWaits() async {
        let intake = intake()
        files = [memo("growing.m4a", size: 1_000), memo("cloud.m4a", downloaded: false)]
        _ = await intake.scan()
        files[0] = memo("growing.m4a", size: 5_000)
        _ = await intake.scan()
        XCTAssertEqual(transcriber.calls.withLock { $0 }, [], "size changed between the scans")
        XCTAssertEqual(downloadRequests, ["cloud.m4a", "cloud.m4a"], "iCloud is asked for the bytes")

        files[1] = memo("cloud.m4a")
        _ = await intake.scan()
        XCTAssertEqual(Set(captured.map(\.text)), ["words of growing.m4a"])
        _ = await intake.scan()
        XCTAssertEqual(Set(captured.map(\.text)), ["words of growing.m4a", "words of cloud.m4a"])
    }

    func testOlderMemosGoFirstAndNothingStartsWhileADictationRuns() async {
        let intake = intake()
        var dictating = true
        intake.canTranscribe = { !dictating }
        files = [memo("b.m4a", minute: 2), memo("a.m4a", minute: 1)]
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(captured, [])
        dictating = false
        _ = await intake.scan()
        XCTAssertEqual(captured.map(\.text), ["words of a.m4a", "words of b.m4a"])
    }

    func testAnEngineFailureLeavesTheMemoForTheNextScanAndStopsThePass() async {
        let intake = intake()
        var statuses: [String] = []
        intake.onStatus = { statuses.append($0) }
        transcriber.results.withLock { $0["a.m4a"] = .failure(EngineDown()) }
        files = [memo("a.m4a", minute: 1), memo("b.m4a", minute: 2)]
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(transcriber.calls.withLock { $0 }, ["a.m4a"], "b would fail the same way")
        XCTAssertEqual(captured, [])
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(statuses, ["Voice memo waits for the speech engine."])

        transcriber.results.withLock { $0["a.m4a"] = nil }
        _ = await intake.scan()
        XCTAssertEqual(captured.map(\.text), ["words of a.m4a", "words of b.m4a"])
    }

    func testUnreadableAndSilentMemosStayInTheFolderAndAreNotTriedAgain() async {
        let intake = intake()
        transcriber.results.withLock {
            $0["broken.m4a"] = .failure(VoiceMemoUnreadable())
            $0["silence.m4a"] = .success("")
        }
        files = [memo("broken.m4a"), memo("silence.m4a")]
        _ = await intake.scan()
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(transcriber.calls.withLock { $0 }.sorted(), ["broken.m4a", "silence.m4a"])
        XCTAssertEqual(captured, [])
        XCTAssertEqual(trashed, [])
    }

    func testAfterARelaunchAMemoThatCouldNotBeTrashedIsNotCapturedAgain() async {
        trashFails = true
        files = [memo("walk.m4a")]
        let first = intake()
        _ = await first.scan()
        _ = await first.scan()
        XCTAssertEqual(captured.count, 1)

        let relaunched = intake()
        _ = await relaunched.scan()
        _ = await relaunched.scan()
        XCTAssertEqual(captured.count, 1)
    }

    func testAQuitMidTranscriptionRetriesTheMemoUnlessItsItemWasSaved() async throws {
        files = [memo("saved.m4a"), memo("lost.m4a")]
        var ledger = VoiceMemoLedger()
        let savedID = UUID()
        ledger.entries["saved.m4a"] = .init(size: 1_000, state: .transcribing(itemID: savedID))
        ledger.entries["lost.m4a"] = .init(size: 1_000, state: .transcribing(itemID: UUID()))
        try ledger.save(to: ledgerURL)
        captured = [Captured(id: savedID, text: "words of saved.m4a", recordedAt: .distantPast, pcm16: Data())]

        let relaunched = intake()
        _ = await relaunched.scan()
        _ = await relaunched.scan()
        XCTAssertEqual(transcriber.calls.withLock { $0 }, ["lost.m4a"])
        XCTAssertEqual(captured.map(\.text), ["words of saved.m4a", "words of lost.m4a"])
    }

    func testANewMemoSavedUnderAnOldNameIsANewMemo() async {
        transcriber.results.withLock { $0["memo.m4a"] = .success("") }
        files = [memo("memo.m4a", size: 1_000)]
        let intake = intake()
        _ = await intake.scan()
        _ = await intake.scan()
        transcriber.results.withLock { $0["memo.m4a"] = nil }
        files = [memo("memo.m4a", size: 2_000, minute: 9)]
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(captured.map(\.text), ["words of memo.m4a"])
    }

    func testAnUnreadableFolderIsReportedAndForgetsNothing() async throws {
        files = [memo("walk.m4a")]
        trashFails = true
        let intake = intake()
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(captured.count, 1)

        var failures = 0
        let refusing = VoiceMemoIntake(
            directory: directory, ledgerURL: ledgerURL, transcriber: transcriber,
            list: { _ in throw CocoaError(.fileReadNoPermission) },
            inboxHas: { _ in false }, capture: { _, _, _, _ in })
        refusing.onListFailure = { _ in failures += 1 }
        _ = await refusing.scan()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(VoiceMemoLedger.load(from: ledgerURL).entries.keys.sorted(), ["walk.m4a"])
    }

    /// The real listing: audio files only, no hidden iCloud or Finder files,
    /// no folders.
    func testTheFolderListingKeepsOnlyVisibleAudioFiles() throws {
        let folder = workDirectory.appendingPathComponent("memos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["walk.m4a", "Kitchen.WAV", ".walk.m4a.icloud", ".DS_Store", "notes.txt"] {
            try Data(repeating: 7, count: 12).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("old.m4a", isDirectory: true), withIntermediateDirectories: true)

        let listed = try VoiceMemoFolder.list(folder).sorted { $0.name < $1.name }
        XCTAssertEqual(listed.map(\.name), ["Kitchen.WAV", "walk.m4a"])
        XCTAssertEqual(listed.map(\.size), [12, 12])
        XCTAssertTrue(listed.allSatisfy(\.isDownloaded))
    }
}
