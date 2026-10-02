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
        let whileTranscribing = Mutex<(@MainActor @Sendable () -> Void)?>(nil)
        func transcribe(_ url: URL) async throws -> VoiceMemoTranscript {
            let name = url.lastPathComponent
            calls.withLock { $0.append(name) }
            if let observe = whileTranscribing.withLock({ $0 }) { await observe() }
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
    private var captureFails = false
    /// The Inbox turned the capture down, as a refused Inbox does.
    private var captureRefused = false
    private var streamingSeen: [Bool] = []

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
    private func intake(
        inboxHas: (@MainActor (UUID) -> Bool)? = nil,
        capture: (@MainActor (UUID, String, Date, Data) throws -> Void)? = nil
    ) -> VoiceMemoIntake {
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
            inboxHas: inboxHas ?? { [unowned self] id in captured.contains { $0.id == id } },
            capture: capture ?? { [unowned self] id, text, recordedAt, pcm in
                if captureFails { throw CocoaError(.fileWriteOutOfSpace) }
                if captureRefused { return }
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

    /// A try-pr build beside the installed app (#990): one copy takes the
    /// memo, the other leaves the folder alone, and takes over once the
    /// first quits without taking the memo a second time.
    func testTwoRunningCopiesTakeAMemoOnce() async {
        files = [memo("walk.m4a")]
        trashFails = true
        let tryBuild = intake()
        do {
            let installed = intake()
            for _ in 0..<2 {
                _ = await installed.scan()
                _ = await tryBuild.scan()
            }
        }
        XCTAssertEqual(captured.map(\.text), ["words of walk.m4a"])

        for _ in 0..<2 { _ = await tryBuild.scan() }
        XCTAssertEqual(captured.map(\.text), ["words of walk.m4a"])
        XCTAssertEqual(transcriber.calls.withLock { $0 }.count, 1)
    }

    /// The Inbox refused the capture while the memo was being transcribed
    /// (#990 review): the memo stays in the folder and is not marked taken.
    func testAMemoTheInboxTurnsDownStaysInTheFolder() async {
        files = [memo("walk.m4a")]
        captureRefused = true
        let intake = intake()
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(trashed, [])
        XCTAssertNil(VoiceMemoLedger.load(from: ledgerURL).value?.entries["walk.m4a"])

        captureRefused = false
        _ = await intake.scan()
        XCTAssertEqual(captured.map(\.text), ["words of walk.m4a"])
        XCTAssertEqual(trashed, ["walk.m4a"])
    }

    /// A memo that begins "also" joins the capture before it (#990 review):
    /// the Inbox took it, so it goes to the Trash and is transcribed once.
    func testAMemoThatJoinsTheCaptureBeforeItIsTakenOnce() async throws {
        let inbox = QuickCaptureFixture.model(
            fileURL: workDirectory.appendingPathComponent("quick-captures.json"), answer: ["reach": 0.9],
            github: FakeQuickCaptureGitHub(), runner: FakeQuickCaptureDraftRunner())
        await inbox.capture(text: "Add a dark mode", historyRecordID: nil).value
        transcriber.results.withLock { $0["walk.m4a"] = .success("Also make it the default") }
        files = [memo("walk.m4a")]
        let intake = intake(
            inboxHas: { inbox.holds($0) },
            capture: { id, text, recordedAt, _ in
                _ = inbox.capture(text: text, historyRecordID: nil, id: id, capturedAt: recordedAt)
            })
        for _ in 0..<3 { _ = await intake.scan() }

        XCTAssertEqual(inbox.items.map(\.text), ["Add a dark mode"])
        XCTAssertEqual(inbox.items.first?.followUps?.map(\.text), ["Also make it the default"])
        XCTAssertEqual(trashed, ["walk.m4a"])
        XCTAssertEqual(transcriber.calls.withLock { $0 }.count, 1)
    }

    /// A copy whose Inbox is refused does not keep the folder from the copy
    /// that can take memos (#990 review).
    func testACopyThatCannotScanLeavesTheFolderToTheOther() async {
        files = [memo("walk.m4a")]
        let refused = intake()
        refused.inboxProblem = { .unreadable }
        let healthy = intake()
        for _ in 0..<2 {
            _ = await refused.scan()
            _ = await healthy.scan()
        }
        XCTAssertEqual(captured.map(\.text), ["words of walk.m4a"])
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

    /// A dictation started while a memo streams gets its text only after the
    /// memo's, so its stop asks whether one is streaming.
    func testTheIntakeSaysWhileAMemoStreamsThroughTheEngine() async {
        let intake = intake()
        transcriber.whileTranscribing.withLock {
            $0 = { [unowned self] in streamingSeen.append(intake.isTranscribing) }
        }
        transcriber.results.withLock { $0["b.m4a"] = .failure(EngineDown()) }
        files = [memo("a.m4a", minute: 1), memo("b.m4a", minute: 2)]
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(streamingSeen, [true, true])
        XCTAssertEqual(captured.map(\.text), ["words of a.m4a"])
        XCTAssertFalse(intake.isTranscribing, "after a capture and after a failure")
    }

    /// Voice memos turned off mid-memo: the memo in flight is finished, since
    /// the helper decodes its audio anyway, and no other memo is taken.
    func testStoppingFinishesTheMemoInFlightAndTakesNoOther() async {
        let intake = intake()
        transcriber.whileTranscribing.withLock {
            $0 = { [unowned self] in
                intake.stopAfterCurrentMemo()
                streamingSeen.append(intake.isTranscribing)
            }
        }
        files = [memo("a.m4a", minute: 1), memo("b.m4a", minute: 2)]
        _ = await intake.scan()
        await intake.run()
        XCTAssertEqual(streamingSeen, [true], "still streaming after the stop")
        XCTAssertEqual(captured.map(\.text), ["words of a.m4a"])
        XCTAssertEqual(transcriber.calls.withLock { $0 }, ["a.m4a"])
    }

    /// #988: a capture whose audio or words could not be written leaves
    /// the memo for a later scan, like an engine failure.
    func testAFailedCaptureLeavesTheMemoAndStopsThePass() async {
        let intake = intake()
        var statuses: [String] = []
        intake.onStatus = { statuses.append($0) }
        captureFails = true
        files = [memo("a.m4a", minute: 1), memo("b.m4a", minute: 2)]
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(transcriber.calls.withLock { $0 }, ["a.m4a"], "b would fail the same way")
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(statuses, ["A voice memo could not be saved."])

        captureFails = false
        _ = await intake.scan()
        XCTAssertEqual(captured.map(\.text), ["words of a.m4a", "words of b.m4a"])
        XCTAssertEqual(trashed, ["a.m4a", "b.m4a"])
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

    /// #988: a memo whose capture never reached the Inbox file stays in the
    /// folder, and the ledger does not call it captured until a later save
    /// puts the words on disk.
    func testAMemoWhoseCaptureIsNotOnDiskStaysInTheFolder() async throws {
        // A file where the Inbox's folder goes: the Inbox reads as absent and
        // every save fails, even as root. A folder at the file's own path
        // would read as unreadable, which refuses the Inbox (#990).
        let inboxFolder = workDirectory.appendingPathComponent("inbox")
        let inboxURL = inboxFolder.appendingPathComponent("quick-captures.json")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try Data().write(to: inboxFolder)
        let model = QuickCaptureFixture.model(
            fileURL: inboxURL, answer: [:], github: FakeQuickCaptureGitHub(), runner: FakeQuickCaptureDraftRunner()
        )
        files = [memo("walk.m4a")]
        let intake = VoiceMemoIntake(
            directory: directory, ledgerURL: ledgerURL, transcriber: transcriber,
            list: { [unowned self] _ in files },
            removeTranscribed: { [unowned self] url in trashed.append(url.lastPathComponent) },
            inboxHas: { id in model.holds(id) },
            inboxIsSaved: { !model.hasUnsavedChanges },
            capture: { id, text, recordedAt, _ in
                try model.captureVoiceMemo(text: text, historyRecordID: nil, id: id, capturedAt: recordedAt)
            }
        )
        _ = await intake.scan()
        let taken = await intake.scan()

        XCTAssertEqual(taken, 0)
        XCTAssertEqual(trashed, [], "the original stays until its capture is on disk")
        let entry = try XCTUnwrap(VoiceMemoLedger.load(from: ledgerURL).value?.entries["walk.m4a"])
        guard case .transcribing(let itemID) = entry.state else {
            return XCTFail("the ledger says \(entry.state), not transcribing")
        }
        XCTAssertEqual(model.items.map(\.id), [itemID], "the words wait in the Inbox for the next save")

        try FileManager.default.removeItem(at: inboxFolder)
        model.setTitle("A walk", for: itemID)
        _ = await intake.scan()
        XCTAssertEqual(trashed, ["walk.m4a"])
        XCTAssertEqual(VoiceMemoLedger.load(from: ledgerURL).value?.entries["walk.m4a"]?.state, .captured(itemID: itemID))
        XCTAssertEqual(transcriber.calls.withLock { $0 }, ["walk.m4a"], "transcribed once")
    }

    /// An intake whose captures go to a real Inbox model. A file sits where
    /// the Inbox's folder goes, as in the test above: every Inbox save fails
    /// until the returned blocker is removed.
    private func intakeOverFailingInbox() throws -> (VoiceMemoIntake, QuickCaptureInboxModel, blocker: URL) {
        let inboxFolder = workDirectory.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try Data().write(to: inboxFolder)
        let model = QuickCaptureFixture.model(
            fileURL: inboxFolder.appendingPathComponent("quick-captures.json"), answer: [:],
            github: FakeQuickCaptureGitHub(), runner: FakeQuickCaptureDraftRunner()
        )
        let intake = VoiceMemoIntake(
            directory: directory, ledgerURL: ledgerURL, transcriber: transcriber,
            list: { [unowned self] _ in files },
            removeTranscribed: { [unowned self] url in
                trashed.append(url.lastPathComponent)
                files.removeAll { $0.name == url.lastPathComponent }
            },
            inboxHas: { id in model.holds(id) },
            inboxIsSaved: { !model.hasUnsavedChanges },
            capture: { id, text, recordedAt, _ in
                try model.captureVoiceMemo(text: text, historyRecordID: nil, id: id, capturedAt: recordedAt)
            }
        )
        return (intake, model, inboxFolder)
    }

    /// #1098: the user discards a capture whose save failed, and the
    /// discard saves. The memo is done, not transcribed again.
    func testADiscardedCaptureWhoseSaveFailedIsNotTranscribedAgain() async throws {
        let (intake, model, blocker) = try intakeOverFailingInbox()
        files = [memo("walk.m4a")]
        _ = await intake.scan()
        _ = await intake.scan()
        let itemID = try XCTUnwrap(model.items.first?.id)

        try FileManager.default.removeItem(at: blocker)
        model.discard(itemID)
        XCTAssertFalse(model.hasUnsavedChanges, "the discard reached the Inbox file")
        _ = await intake.scan()
        _ = await intake.scan()

        XCTAssertEqual(transcriber.calls.withLock { $0 }, ["walk.m4a"], "transcribed once")
        XCTAssertEqual(model.items, [])
    }

    /// #1098: a memo replaced in iCloud under the same name and size while
    /// its first capture waited for a save is a new memo: it is transcribed,
    /// not trashed on the strength of the old words.
    func testAMemoReplacedWhileItsCaptureWaitedForASaveIsTranscribed() async throws {
        let (intake, model, blocker) = try intakeOverFailingInbox()
        transcriber.results.withLock { $0["walk.m4a"] = .success("first take") }
        files = [memo("walk.m4a", minute: 1)]
        _ = await intake.scan()
        _ = await intake.scan()
        let firstID = try XCTUnwrap(model.items.first?.id)

        transcriber.results.withLock { $0["walk.m4a"] = .success("second take") }
        files = [memo("walk.m4a", minute: 7)]
        try FileManager.default.removeItem(at: blocker)
        model.setTitle("A walk", for: firstID)
        XCTAssertFalse(model.hasUnsavedChanges, "the first take reached the Inbox file")
        _ = await intake.scan()
        XCTAssertEqual(trashed, [], "the replacement is not trashed untranscribed")
        _ = await intake.scan()

        XCTAssertEqual(model.items.map(\.text).sorted(), ["first take", "second take"])
        XCTAssertEqual(trashed, ["walk.m4a"])
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
        do {
            // The first launch, which quits and so lets go of the folder.
            let intake = intake()
            _ = await intake.scan()
            _ = await intake.scan()
        }
        XCTAssertEqual(captured.count, 1)

        var failures = 0
        let refusing = VoiceMemoIntake(
            directory: directory, ledgerURL: ledgerURL, transcriber: transcriber,
            list: { _ in throw CocoaError(.fileReadNoPermission) },
            inboxHas: { _ in false }, capture: { _, _, _, _ in })
        refusing.onListFailure = { _ in failures += 1 }
        _ = await refusing.scan()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(VoiceMemoLedger.load(from: ledgerURL).value?.entries.keys.sorted(), ["walk.m4a"])
    }

    /// A ledger this build cannot load is left as it is and no memo is
    /// taken, since each would become a second capture (#989).
    func testANewerLedgerKeepsItsBytesAndTakesNoMemo() async throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let data = Data(#"{"version":\#(VoiceMemoLedger.currentVersion + 1),"entries":{}}"#.utf8)
        try data.write(to: ledgerURL)
        var statuses: [String] = []
        let intake = intake()
        intake.onStatus = { statuses.append($0) }
        files = [memo("walk.m4a")]
        _ = await intake.scan()
        _ = await intake.scan()

        XCTAssertEqual(intake.ledgerProblem, .newerVersion(VoiceMemoLedger.currentVersion + 1))
        XCTAssertTrue(captured.isEmpty)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), data)
        XCTAssertEqual(statuses, [VoiceMemoIntake.ledgerRefusedStatus], "said once")

        let aside = try intake.moveLedgerAsideAndStartOver()
        XCTAssertEqual(try Data(contentsOf: aside), data)
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(captured.map(\.text), ["words of walk.m4a"])
    }

    func testACorruptLedgerKeepsItsBytesAndTakesNoMemo() async throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let data = Data(#"{"version":1,"entries":{"walk.m4a":"#.utf8)
        try data.write(to: ledgerURL)
        let intake = intake()
        files = [memo("walk.m4a")]
        _ = await intake.scan()
        _ = await intake.scan()

        XCTAssertEqual(intake.ledgerProblem, .unreadable)
        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), data)
    }

    /// A memo that arrives while the Inbox refuses captures stays in the
    /// folder, unmarked, and becomes a capture once the Inbox starts over
    /// (#989, review of #997). Wired as the app wires it.
    func testAMemoWaitsInTheFolderWhileTheInboxIsRefused() async throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let inboxURL = workDirectory.appendingPathComponent("quick-captures.json")
        try Data("{ not json".utf8).write(to: inboxURL)
        let inbox = QuickCaptureFixture.model(
            fileURL: inboxURL, answer: ["reach": 0.9], github: FakeQuickCaptureGitHub(),
            runner: FakeQuickCaptureDraftRunner())
        var statuses: [String] = []
        let intake = VoiceMemoIntake(
            directory: directory, ledgerURL: ledgerURL, transcriber: transcriber,
            list: { [unowned self] _ in files },
            removeTranscribed: { [unowned self] url in trashed.append(url.lastPathComponent) },
            inboxHas: { id in inbox.items.contains { $0.id == id } },
            capture: { id, text, recordedAt, _ in
                _ = inbox.capture(text: text, historyRecordID: nil, id: id, capturedAt: recordedAt)
            })
        intake.inboxProblem = { inbox.storeProblem }
        intake.onStatus = { statuses.append($0) }
        files = [memo("walk.m4a")]
        _ = await intake.scan()
        _ = await intake.scan()

        XCTAssertTrue(trashed.isEmpty, "the memo stays in the folder")
        XCTAssertNil(VoiceMemoLedger.load(from: ledgerURL).value?.entries["walk.m4a"])
        XCTAssertEqual(statuses, [VoiceMemoIntake.inboxRefusedStatus])

        try inbox.moveAsideAndStartOver()
        _ = await intake.scan()
        _ = await intake.scan()
        XCTAssertEqual(inbox.items.map(\.text), ["words of walk.m4a"])
        XCTAssertEqual(trashed, ["walk.m4a"])
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
