import XCTest
@testable import localvoxtral

/// #988: the launch sweep of voice memo recordings keeps every capture still
/// in the Inbox, follow-ups included, whether voice memos are on or off.
@MainActor
final class VoiceMemoRecordingSweepTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMemoRecordingSweepTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testARelaunchKeepsTheRecordingsOfAnUnfiledCaptureAndItsFollowUp() throws {
        for enabled in [true, false] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let inboxURL = directory.appendingPathComponent("quick-captures.json")
            let parent = UUID()
            let followUp = UUID()
            let filed = UUID()
            let discarded = UUID()
            var inbox = QuickCaptureInbox()
            let capturedAt = Date(timeIntervalSince1970: 1_000_000)
            inbox.add(QuickCaptureItem(id: parent, capturedAt: capturedAt, text: "Add a dark mode"))
            inbox.add(QuickCaptureItem(id: followUp, capturedAt: capturedAt, text: "Also the settings window"))
            XCTAssertTrue(inbox.join(followUp, into: parent))
            var filedItem = QuickCaptureItem(id: filed, capturedAt: capturedAt, text: "Fix the crash")
            filedItem.state = .filed
            filedItem.filedAt = capturedAt
            inbox.add(filedItem)
            try QuickCaptureInboxFile.save(inbox, to: inboxURL)

            let audioStore = DictationAudioStore(directoryURL: directory.appendingPathComponent("voice-memo-audio"))
            for id in [parent, followUp, filed, discarded] {
                try audioStore.write(pcm16: Data(repeating: 1, count: 320), for: id)
            }

            let defaults = makeSettingsDefaults()
            let settings = makeSettings(defaults: defaults)
            settings.voiceMemosEnabled = enabled
            let inboxModel = QuickCaptureInboxViewModel(
                settings: settings, learnedTerms: { LearnedTerms() }, fileURL: inboxURL, applicationSupport: directory
            )
            _ = VoiceMemoController(
                settings: settings,
                inbox: inboxModel,
                audioStore: audioStore,
                ledgerURL: directory.appendingPathComponent("voice-memos.json"),
                transcriber: UnusedTranscriber(),
                isDictationActive: { false },
                saveHistory: { _, _ in nil }
            )

            XCTAssertEqual(
                audioStore.storedIDs(), [parent, followUp],
                "voice memos \(enabled ? "on" : "off"): the unfiled capture and its follow-up keep their recordings"
            )
        }
    }

    private struct UnusedTranscriber: VoiceMemoTranscribing {
        func transcribe(_ url: URL) async throws -> VoiceMemoTranscript {
            XCTFail("the sweep transcribes nothing")
            throw CancellationError()
        }
    }
}
