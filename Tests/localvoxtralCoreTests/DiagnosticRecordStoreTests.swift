import Foundation
import Synchronization
import XCTest
@testable import localvoxtralCore
import localvoxtralTestSupport

/// The real folder, with a hook that runs between a patch reading a record
/// and writing it back.
private struct InterleavingDirectoryIO: DiagnosticRecordDirectoryIO {
    let base = DiagnosticRecordFileDirectoryIO()
    let afterRead: @Sendable (URL) -> Void

    func contents(of url: URL) throws -> [String]? { try base.contents(of: url) }
    func remove(at url: URL) throws { try base.remove(at: url) }
    func size(of url: URL) -> Int? { base.size(of: url) }

    func read(from url: URL) throws -> Data? {
        let data = try base.read(from: url)
        afterRead(url)
        return data
    }
}

final class DiagnosticRecordStoreTests: XCTestCase {
    /// Unique per test: the store's lock shared with other running copies
    /// is a file beside this folder, and test classes run in several
    /// processes at once.
    private let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("lvx-diagnostic-records-\(UUID().uuidString)", isDirectory: true)
    private var directory: URL { home.appendingPathComponent("diagnostic-records", isDirectory: true) }
    private var io: MemoryCaptureIO!
    private let clock = CaptureTestClock()

    override func setUp() {
        super.setUp()
        io = MemoryCaptureIO()
        clock.set(Date(timeIntervalSince1970: 1_800_000_000))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func makeStore(
        retention: DiagnosticRecordStore.Retention = .default
    ) -> DiagnosticRecordStore {
        let clock = self.clock
        return DiagnosticRecordStore(
            directoryURL: directory,
            io: io,
            directoryIO: io,
            retention: retention,
            now: { clock.now() }
        )
    }

    private func makeRecord(
        id: String = UUID().uuidString,
        capturedAt: Date? = nil,
        rawTranscript: String = "run the tests",
        screenText: String? = nil
    ) -> DiagnosticRecord {
        .storeFixture(id: id, capturedAt: capturedAt ?? clock.now(), rawTranscript: rawTranscript, screenText: screenText)
    }

    // MARK: - Writing and round-tripping

    func testWriteNamesTheFileByHistoryIDAndRoundTripsTheRecord() throws {
        let store = makeStore()
        let id = UUID()
        let record = makeRecord(id: id.uuidString, rawTranscript: "check DictationViewModel plus Session")

        let url = try store.write(record)

        let parsed = try XCTUnwrap(DiagnosticRecordFileName.parse(url.lastPathComponent))
        XCTAssertEqual(parsed.id, id)
        XCTAssertEqual(parsed.capturedAt.timeIntervalSince1970,
                       record.capturedAt.timeIntervalSince1970,
                       accuracy: 0.001)

        let data = try XCTUnwrap(io.read(from: url))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticRecord.self, from: data)
        XCTAssertEqual(decoded.id, id.uuidString)
        XCTAssertEqual(decoded.text.rawTranscript, "check DictationViewModel plus Session")
        XCTAssertEqual(decoded.schemaVersion, DiagnosticRecord.currentSchemaVersion)
        XCTAssertEqual(store.storedIDs(), [id])
        XCTAssertEqual(try store.summary().records, 1)
        XCTAssertEqual(try store.summary().bytes, data.count)
    }

    /// A record belongs to a History entry; an id that is not one is refused
    /// rather than written under a name nothing can delete it by.
    /// A record already in quarantine is never overwritten: another running
    /// copy may have moved the same record there a moment ago.
    func testQuarantineNeverOverwritesARecordAlreadyThere() throws {
        let store = makeStore()
        let record = makeRecord()
        let url = try store.write(record)
        let folder = URL(fileURLWithPath: "/tmp/lvx-quarantine-test")
        let earlier = folder.appendingPathComponent(url.lastPathComponent)
        io.seed(Data([9]), at: earlier)

        XCTAssertEqual(store.quarantine([try XCTUnwrap(UUID(uuidString: record.id))], into: folder), 1)

        XCTAssertEqual(try io.read(from: earlier), Data([9]))
        XCTAssertEqual(io.fileNames.filter { $0.hasSuffix(url.lastPathComponent) }.count, 2)
        XCTAssertTrue(store.storedIDs().isEmpty)
    }

    func testWriteRefusesAnIDThatIsNotAHistoryID() {
        XCTAssertThrowsError(try makeStore().write(makeRecord(id: "not-a-uuid"))) {
            XCTAssertEqual($0 as? DiagnosticRecordStore.StoreError, .invalidID("not-a-uuid"))
        }
        XCTAssertEqual(io.fileNames, [])
    }

    // MARK: - Retention

    func testCountRetentionRemovesOldestRecordsFirst() throws {
        let store = makeStore(retention: .init(maximumRecords: 2, maximumAge: .infinity))
        let oldest = try store.write(makeRecord())
        clock.advance(1)
        let middle = try store.write(makeRecord())
        clock.advance(1)
        let newest = try store.write(makeRecord())

        XCTAssertNil(try io.read(from: oldest), "oldest record is pruned past the count cap")
        XCTAssertNotNil(try io.read(from: middle))
        XCTAssertNotNil(try io.read(from: newest))
    }

    func testAgeRetentionRemovesRecordsPastTheWindow() throws {
        let store = makeStore(retention: .init(maximumRecords: .max, maximumAge: 60))
        let old = try store.write(makeRecord())
        clock.advance(120)
        let fresh = try store.write(makeRecord())

        XCTAssertNil(try io.read(from: old))
        XCTAssertNotNil(try io.read(from: fresh))
    }

    func testTheDefaultKeepsFiveHundredRecordsForFourteenDays() {
        XCTAssertEqual(DiagnosticRecordStore.Retention.default.maximumRecords, 500)
        XCTAssertEqual(DiagnosticRecordStore.Retention.default.maximumAge, 14 * 24 * 60 * 60)
    }

    func testPruneIgnoresFilesItCannotParse() throws {
        let store = makeStore(retention: .init(maximumRecords: 0, maximumAge: 0))
        let foreign = directory.appendingPathComponent("notes.txt")
        io.seed(Data("owner's notes".utf8), at: foreign)

        store.prune()

        XCTAssertNotNil(try io.read(from: foreign), "pruning must not remove what it cannot parse")
    }

    // MARK: - Deleting with the dictation

    func testRemoveDeletesOnlyTheNamedDictationsRecords() throws {
        let store = makeStore()
        let kept = UUID(), gone = UUID()
        try store.write(makeRecord(id: kept.uuidString))
        try store.write(makeRecord(id: gone.uuidString))

        XCTAssertEqual(store.remove([gone]), 1)
        XCTAssertEqual(store.storedIDs(), [kept])
    }

    func testRemoveAllExceptSweepsRecordsWhoseDictationIsGone() throws {
        let store = makeStore()
        let kept = UUID()
        try store.write(makeRecord(id: kept.uuidString))
        try store.write(makeRecord(id: UUID().uuidString))

        XCTAssertEqual(store.removeAll(except: [kept]), 1)
        XCTAssertEqual(store.storedIDs(), [kept])
    }

    /// The switch turned off: every record goes, and so does anything else in
    /// the folder, such as a temp file a crashed write left behind.
    func testRemoveAllEmptiesTheFolder() throws {
        let store = makeStore()
        try store.write(makeRecord())
        io.seed(Data("partial".utf8), at: directory.appendingPathComponent(".tmp-record"))

        XCTAssertEqual(store.removeAll(), 1)
        XCTAssertEqual(try io.contents(of: directory), [])
        XCTAssertEqual(try store.summary().records, 0)
    }

    /// A write decided before the user turned records off must not land
    /// after the delete.
    func testAWriteDecidedBeforeADeleteAllIsRefused() throws {
        let store = makeStore()
        let epoch = store.deletionEpoch()
        store.removeAll()

        XCTAssertThrowsError(try store.write(makeRecord(), unlessDeletedSince: epoch)) {
            XCTAssertEqual($0 as? DiagnosticRecordStore.StoreError, .deletedSinceDecision)
        }
        XCTAssertEqual(try io.contents(of: directory), [])
        XCTAssertNoThrow(try store.write(makeRecord(), unlessDeletedSince: store.deletionEpoch()))
    }

    /// Another running copy turning records off moves the generation file
    /// they share; a write this copy decided before that is refused (#1770).
    func testAnotherProcessesDeleteInvalidatesAPendingWrite() throws {
        let store = makeStore()
        let epoch = store.deletionEpoch()

        // What the other copy's `removeAll()` leaves: a later generation.
        io.seed(Data("7".utf8), at: DiagnosticRecordStore.generationURL(forDirectory: directory))

        XCTAssertThrowsError(try store.write(makeRecord(), unlessDeletedSince: epoch)) {
            XCTAssertEqual($0 as? DiagnosticRecordStore.StoreError, .deletedSinceDecision)
        }
        XCTAssertEqual(try io.contents(of: directory), [])
        XCTAssertNoThrow(try store.write(makeRecord(), unlessDeletedSince: store.deletionEpoch()))
    }

    /// On disk, under a data folder that is 0755 as on a real install: the
    /// hardened writer refuses a file loose in such a folder, so the
    /// generation must still move and still refuse a write decided before
    /// the delete.
    func testTheGenerationMovesOnDiskUnderALooseDataFolder() throws {
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let clock = self.clock
        let store = DiagnosticRecordStore(directoryURL: directory, retention: .default, now: { clock.now() })
        let other = DiagnosticRecordStore(directoryURL: directory, retention: .default, now: { clock.now() })
        let epoch = store.deletionEpoch()

        other.removeAll()

        XCTAssertNotEqual(store.deletionEpoch(), epoch)
        XCTAssertThrowsError(try store.write(makeRecord(), unlessDeletedSince: epoch))
        XCTAssertNoThrow(try store.write(makeRecord(), unlessDeletedSince: store.deletionEpoch()))
    }

    /// A generation file that cannot be read refuses the write: a delete
    /// may have happened that this copy cannot see.
    func testAnUnreadableGenerationRefusesTheWrite() throws {
        let store = makeStore()
        let epoch = store.deletionEpoch()
        io.seed(Data("garbage".utf8), at: DiagnosticRecordStore.generationURL(forDirectory: directory))

        XCTAssertThrowsError(try store.write(makeRecord(), unlessDeletedSince: epoch))
        XCTAssertThrowsError(try store.write(makeRecord(), unlessDeletedSince: store.deletionEpoch()))
        store.removeAll()
        XCTAssertNoThrow(try store.write(makeRecord(), unlessDeletedSince: store.deletionEpoch()))
    }

    /// A write that died between its temp file and the rename leaves a whole
    /// record under a name no sweep lists; the launch sweep deletes it and
    /// nothing else.
    func testRemoveStrayFilesDeletesInterruptedWritesOnly() throws {
        let store = makeStore()
        let kept = try store.write(makeRecord())
        let stray = directory.appendingPathComponent(
            ".dictation-20260724T191408.000Z-\(UUID().uuidString).json.4242.99.tmp")
        let foreign = directory.appendingPathComponent("notes.txt")
        io.seed(Data("partial record".utf8), at: stray)
        io.seed(Data("owner's notes".utf8), at: foreign)

        store.removeStrayFiles()

        XCTAssertNil(try io.read(from: stray))
        XCTAssertNotNil(try io.read(from: kept))
        XCTAssertNotNil(try io.read(from: foreign))
    }

    /// Re-encoding a newer build's record drops the fields this build does
    /// not know, so the patch leaves it alone (#1042).
    func testAttachBehaviorLeavesANewerSchemaRecordUnchanged() throws {
        let store = makeStore()
        var record = makeRecord()
        record.schemaVersion = DiagnosticRecord.currentSchemaVersion + 1
        let url = try store.write(record)
        let before = try XCTUnwrap(io.read(from: url))
        let behavior = DiagnosticRecord.Behavior(
            outcome: .clean, signal: nil, secondsSinceCommitBucket: nil,
            wordCountBucket: "1-5", watchWindowSeconds: 2, outputMode: "overlayBuffer")

        XCTAssertThrowsError(try store.attachBehavior(behavior, toRecordAt: url)) {
            XCTAssertEqual(
                $0 as? DiagnosticRecordStore.StoreError,
                .newerRecord(schemaVersion: DiagnosticRecord.currentSchemaVersion + 1))
        }
        XCTAssertEqual(try io.read(from: url), before)
    }

    /// Another running copy of the app (a try-pr build beside the installed
    /// one, #990) deletes the dictation while this copy's edit watcher is
    /// patching its record. The patch must not write the record back.
    func testAnotherCopyDeletingDuringABehaviorPatchIsNotUndone() throws {
        let folder = directory
        let deletedDuringPatch = Mutex(false)
        // The other copy deletes the moment it can take the lock the copies
        // share, as its History Delete does.
        let directoryIO = InterleavingDirectoryIO { url in
            guard let otherCopy = StoredFileLock.tryHolding(beside: folder) else { return }
            withExtendedLifetime(otherCopy) {
                try? FileManager.default.removeItem(at: url)
                deletedDuringPatch.withLock { $0 = true }
            }
        }
        let clock = self.clock
        let store = DiagnosticRecordStore(
            directoryURL: folder, directoryIO: directoryIO, now: { clock.now() })
        let id = UUID()
        let url = try store.write(makeRecord(id: id.uuidString))
        let behavior = DiagnosticRecord.Behavior(
            outcome: .clean, signal: nil, secondsSinceCommitBucket: nil,
            wordCountBucket: "1-5", watchWindowSeconds: 2, outputMode: "overlayBuffer")

        try store.attachBehavior(behavior, toRecordAt: url)
        if !deletedDuringPatch.withLock({ $0 }) {
            // Locked out until the patch finished: the delete runs now.
            DiagnosticRecordStore(directoryURL: folder, now: { clock.now() }).remove([id])
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileNameParsingRejectsForeignNames() {
        XCTAssertNil(DiagnosticRecordFileName.parse("notes.txt"))
        XCTAssertNil(DiagnosticRecordFileName.parse("dictation-garbage.json"))
        XCTAssertNil(DiagnosticRecordFileName.parse("dictation-20260724T191408.000Z-abc123.json"),
                     "an id that is not a History id is not a record name")
        let id = UUID()
        XCTAssertEqual(
            DiagnosticRecordFileName.parse("dictation-20260724T191408.000Z-\(id.uuidString).json")?.id, id)
    }
}

/// Secret-shaped redaction, one test per shape a terminal shows. Shape is the
/// only thing redaction can match: the app does not know the secrets.
final class DiagnosticRecordRedactionTests: XCTestCase {
    /// Base64url but not hex, so only the enrollment-token rule can match it.
    private func token(length: Int) -> String {
        String(repeating: "z", count: length)
    }

    /// `text` redacted, asserting `secret` is gone, `kept` survives, and
    /// exactly `expected` runs were counted.
    private func assertRedacts(
        _ secret: String, in text: String, keeping kept: String, count expected: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var count = 0
        let result = DiagnosticRecordRedaction.redacting(text, count: &count)
        XCTAssertFalse(result.contains(secret), "left in: \(result)", file: file, line: line)
        XCTAssertTrue(result.contains(kept), "lost the context: \(result)", file: file, line: line)
        XCTAssertTrue(result.contains(DiagnosticRecordRedaction.placeholder), file: file, line: line)
        XCTAssertEqual(count, expected, file: file, line: line)
    }

    func testRedactsAPEMPrivateKeyBlock() {
        let key = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\nq9ZLkJ3xS1b2"
        assertRedacts(
            key,
            in: "$ cat id_rsa\n-----BEGIN RSA PRIVATE KEY-----\n\(key)\n-----END RSA PRIVATE KEY-----\n$ ls",
            keeping: "$ ls"
        )
    }

    /// A screen that cut the block off still loses everything after BEGIN.
    func testRedactsAPEMBlockTheScreenCutOff() {
        assertRedacts(
            "MIIEvQIBADANBgkqhkiG9w0BAQEF",
            in: "$ cat key.pem\n-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEF",
            keeping: "$ cat key.pem"
        )
    }

    func testRedactsAJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        assertRedacts(jwt, in: "token: \(jwt) (expires in 1h)", keeping: "(expires in 1h)")
    }

    func testRedactsABearerTokenAndKeepsTheLabel() {
        assertRedacts(
            "0b7e.Qx9-r2LmT",
            in: "curl -H 'Authorization: Bearer 0b7e.Qx9-r2LmT' https://api.example.com",
            keeping: "Authorization: Bearer "
        )
    }

    /// "bearer" in prose is followed by a word, not a token.
    func testLeavesTheWordBearerInProseAlone() {
        var count = 0
        let text = "the bearer instruments were signed"
        XCTAssertEqual(DiagnosticRecordRedaction.redacting(text, count: &count), text)
        XCTAssertEqual(count, 0)
    }

    /// Each key is its service prefix plus a body, joined at run time: the
    /// repository's push protection rejects a literal that looks live.
    func testRedactsServiceKeysByPrefix() {
        let keys = [
            ("sk-ant-", "api03-Xk2v9QmLr7TzPq1Wn4Hs8Yd"),
            ("sk-proj-", "4fQm9XvL2rT7pKw1Zn8Hs3Yd6Bc"),
            ("ghp_", "1a2B3c4D5e6F7g8H9i0J1k2L3m4N5o6P7q8R"),
            ("github_pat_", "11ABCDEFG0123456789_abcdefghijklmnopqrstu"),
            ("xoxb-", "1234567890-abcdefghijkl"),
            ("AKIA", "IOSFODNN7EXAMPLE"),
            ("AIza", "SyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY"),
            ("glpat-", "xY9zW8vU7tS6rQ5pO4nM"),
            ("hf_", "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"),
            ("sk_" + "live_", "4eC39HqLyjWDarjtT1zdp7dc"),
            ("npm_", "aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5"),
        ].map { $0.0 + $0.1 }
        for key in keys {
            assertRedacts(key, in: "value \(key) end", keeping: "value ")
        }
    }

    func testRedactsASecretNamedShellAssignmentAndKeepsTheName() {
        assertRedacts(
            "s3cr3t-Pa55word",
            in: "export DB_PASSWORD=\"s3cr3t-Pa55word\"; npm start",
            keeping: "export DB_PASSWORD=\""
        )
        assertRedacts("vK8q2mZ9", in: "MISTRAL_API_KEY=vK8q2mZ9 vibe", keeping: "MISTRAL_API_KEY=")
    }

    /// A variable named only for the secret, with nothing before the word
    /// (#1571).
    func testRedactsAnAssignmentToABareSecretName() {
        for name in ["PASSWORD", "SECRET", "TOKEN", "KEY"] {
            assertRedacts(
                "s3cr3t-Pa55word",
                in: "export \(name)=\"s3cr3t-Pa55word\"; npm start",
                keeping: "export \(name)=\""
            )
        }
    }

    /// Code that reads a key is not a secret: only an uppercase shell
    /// variable being assigned is.
    func testLeavesCodeThatNamesAKeyAlone() {
        var count = 0
        let text = "let apiKey = settings.mistralAPIKey ?? fallbackValue"
        XCTAssertEqual(DiagnosticRecordRedaction.redacting(text, count: &count), text)
        XCTAssertEqual(count, 0)
    }

    func testRedactsLongHex() {
        let hex = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        assertRedacts(hex, in: "sha256 \(hex)  model.safetensors", keeping: "model.safetensors")
    }

    /// Short hex is a short commit hash or a colour, not a secret.
    func testLeavesShortHexAlone() {
        var count = 0
        let text = "commit 4951dcce on main, color #ff00aa"
        XCTAssertEqual(DiagnosticRecordRedaction.redacting(text, count: &count), text)
        XCTAssertEqual(count, 0)
    }

    func testRedactsATokenLengthBase64URLRun() {
        var count = 0
        let secret = token(length: 43)
        let result = DiagnosticRecordRedaction.redacting(
            "enroll \(secret) && claude plugin install",
            count: &count
        )

        XCTAssertEqual(count, 1)
        XCTAssertFalse(result.contains(secret))
        XCTAssertTrue(result.contains(ClaudeRemoteTokenRedaction.placeholder))
        XCTAssertTrue(result.contains("claude plugin install"), "surrounding text is preserved")
    }

    /// A token is fixed width. Matching "long base64-ish thing" instead would
    /// shred the hashes, identifiers, and blobs a review needs to read.
    func testLeavesRunsOfOtherLengthsAlone() {
        for length in [42, 44, 64] {
            var count = 0
            let text = "value=\(token(length: length))"
            XCTAssertEqual(DiagnosticRecordRedaction.redacting(text, count: &count), text)
            XCTAssertEqual(count, 0, "length \(length) must not be treated as a token")
        }
    }

    func testRedactsAcrossEveryContentBearingFieldOfARecord() {
        let secret = token(length: 43)
        var record = DiagnosticRecord(
            id: UUID().uuidString,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            session: .init(outputMode: "overlayBuffer"),
            screen: .init(
                decision: "render",
                sanitizedCharacterCount: "token \(secret) on screen".count,
                sanitizedText: "token \(secret) on screen"
            ),
            allocation: [],
            sources: [
                .init(
                    source: "repository",
                    harvest: ["\(secret)", "DictationViewModel.swift"],
                    harvestCount: 2,
                    // A proposal's term comes out of the harvest and its heard
                    // spans out of the transcript, so both can carry a token
                    // that the harvest itself already leaked into.
                    entries: [.init(term: secret, heard: ["heard \(secret)"])],
                    phoneticEntries: [
                        .init(term: "PolishContextGrounding", heard: [secret])
                    ],
                    verificationEntries: [.init(term: secret, heard: ["spoken"])],
                    isFallbackOnly: false,
                    renderedExcerpt: "excerpt with \(secret)"
                )
            ],
            text: .init(
                rawTranscript: "raw \(secret)",
                workingText: "working \(secret)",
                groundedText: "grounded \(secret)",
                systemPrompt: "system \(secret)",
                userPrompts: ["prompt \(secret)"],
                polishedOutput: "polished \(secret)",
                committedText: "committed \(secret)"
            ),
            timings: .init()
        )

        let redactions = DiagnosticRecordRedaction.redact(&record)

        // Seven text stages, the screen text, one harvest term, the rendered
        // excerpt, and four across the three entry arrays (entry term + heard,
        // phonetic heard, verification term).
        XCTAssertEqual(redactions, 14)
        let encoded = String(
            data: try! JSONEncoder().encode(record),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(encoded.contains(secret), "no field may carry the token to disk")
    }

    // MARK: - The prompt sent to the agent

    private func recordCarrying(_ text: String) -> DiagnosticRecord {
        DiagnosticRecord(
            id: UUID().uuidString,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            session: .init(outputMode: "overlayBuffer"),
            screen: .init(decision: "render", sanitizedCharacterCount: text.count, sanitizedText: text),
            allocation: [],
            sources: [
                .init(
                    source: "claude", harvest: [], harvestCount: 0, entries: [],
                    phoneticEntries: [], verificationEntries: [], isFallbackOnly: false,
                    renderedExcerpt: text
                )
            ],
            text: .init(
                rawTranscript: "rename the hook publisher",
                workingText: "rename the hook publisher",
                groundedText: "rename the hook publisher",
                systemPrompt: text,
                userPrompts: [text],
                polishedOutput: nil,
                committedText: nil
            ),
            timings: .init()
        )
    }

    /// The prompt last sent to the agent rides the session context into the
    /// rendered prompts, the agent source's excerpt and the screen; the record
    /// must not keep it anywhere (docs/dictation.md: the app never saves it).
    func testWithholdsThePriorPromptFromEveryContextField() throws {
        let prompt = "Please rename ClaudeHookPublisher to HookPublisher\nand update the tests in HookTests.swift"
        let context = "workspace: localvoxtral\n\nprevious request to the agent: \(prompt)\n\nfiles the agent recently touched:\nSources/App.swift (edit)"
        var record = recordCarrying(context)

        DiagnosticRecordRedaction.withholdPrompt(prompt, from: &record)

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
        XCTAssertFalse(encoded.contains("ClaudeHookPublisher to HookPublisher"))
        XCTAssertFalse(encoded.contains("update the tests in HookTests"))
        XCTAssertTrue(encoded.contains(DiagnosticRecordRedaction.withheldPromptPlaceholder))
        XCTAssertTrue(
            record.text.userPrompts[0].contains("Sources/App.swift (edit)"), "the rest of the context stays")
        XCTAssertEqual(record.text.rawTranscript, "rename the hook publisher",
                       "this dictation's own words are not the prior prompt")
    }

    /// A prompt too short for the line pass ("fix bug") is still found behind
    /// its label.
    func testWithholdsAShortPriorPromptBehindItsLabel() throws {
        var record = recordCarrying("workspace: app\n\nprevious request to the agent: fix bug\n\nfiles")

        DiagnosticRecordRedaction.withholdPrompt("fix bug", from: &record)

        XCTAssertEqual(
            record.text.userPrompts,
            ["workspace: app\n\nprevious request to the agent: \(DiagnosticRecordRedaction.withheldPromptPlaceholder)\n\nfiles"]
        )
    }

    /// An excerpt that kept only the start of a long prompt line still loses it.
    func testWithholdsAPromptLineTheExcerptCutShort() {
        let prompt = "Refactor the SessionContextResolver so the join is resolved once per dictation"
        var record = recordCarrying("previous request to the agent: Refactor the SessionContextResolver so[…]\nnext line")

        DiagnosticRecordRedaction.withholdPrompt(prompt, from: &record)

        XCTAssertEqual(
            record.sources[0].renderedExcerpt,
            "previous request to the agent: \(DiagnosticRecordRedaction.withheldPromptPlaceholder)\nnext line"
        )
    }

    /// A terminal shows a long prompt line soft-wrapped at the pane width,
    /// with its tab expanded to the next tab stop, so a row holds a stretch
    /// from the middle of the line that no whole-line or prefix pass matches
    /// (#1121).
    func testWithholdsAPromptTheScreenSoftWrappedAndTabExpanded() throws {
        let prompt = "Rename the SessionContextResolver join cache\tso every dictation resolves the pane"
            + " once, then update DiagnosticRecordStoreTests and the field-debugging doc so the probe"
            + " and the record agree on the arm they name"
        var expanded = ""
        for character in "> " + prompt {
            if character == "\t" {
                repeat { expanded.append(" ") } while expanded.count % 8 != 0
            } else {
                expanded.append(character)
            }
        }
        let rows = stride(from: 0, to: expanded.count, by: 80).map { start in
            String(Array(expanded)[start..<min(start + 80, expanded.count)])
        }
        XCTAssertGreaterThan(rows.count, 2)
        var record = recordCarrying("files the agent recently touched")
        record.screen?.sanitizedText = (["$ git status"] + rows + ["Done. 3 files changed"])
            .joined(separator: "\n")

        DiagnosticRecordRedaction.withholdPrompt(prompt, from: &record)

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
        for form in [prompt, expanded] {
            let characters = Array(form)
            for start in 0...(characters.count - 12) {
                let fragment = String(characters[start..<start + 12])
                guard !fragment.contains("\t") else { continue }
                XCTAssertFalse(encoded.contains(fragment), "'\(fragment)' survived")
            }
        }
        XCTAssertEqual(
            record.screen?.sanitizedText,
            "$ git status\n> \(DiagnosticRecordRedaction.withheldPromptPlaceholder)\nDone. 3 files changed")
        XCTAssertEqual(record.text.rawTranscript, "rename the hook publisher")
    }

    // MARK: - The unsent prompt draft

    /// A cursor in the middle of a one-line draft splits no line: the screen
    /// shows `QuokkaLedger` whole, and its halves are each too short to look
    /// for.
    func testWithholdsAOneLineDraftTheCursorSplits() throws {
        let draft = ClaudePromptDraft(sessionID: "s1", beforeCursor: "Quokka", afterCursor: "Ledger")
        let screen = "$ claude\n> QuokkaLedger\n  ? for shortcuts"
        var record = recordCarrying("files the agent recently touched")
        record.screen?.sanitizedText = screen

        DiagnosticRecordRedaction.withhold(.draft(draft), from: &record)

        XCTAssertEqual(
            record.screen?.sanitizedText,
            "$ claude\n> \(DiagnosticRecordRedaction.withheldDraftPlaceholder)\n  ? for shortcuts")
        XCTAssertFalse(
            DiagnosticRecordRedaction.withholding(.draft(draft), in: screen, softWrapped: true)
                .contains("QuokkaLedger"),
            "the screen's harvest is taken from this text")
    }

    /// A field may hold one side of the cursor on its own, which the joined
    /// draft's lines do not spell.
    func testWithholdsEachSideOfTheCursorOnItsOwn() {
        let draft = ClaudePromptDraft(
            sessionID: "s1", beforeCursor: "rename the table\nQuokka", afterCursor: "Ledger and its tests"
        )

        let clipboard = DiagnosticRecordRedaction.withholding(
            .draft(draft), in: "copied:\nLedger and its tests\nend", softWrapped: true)

        XCTAssertEqual(clipboard, "copied:\n\(DiagnosticRecordRedaction.withheldDraftPlaceholder)\nend")
    }

    /// A prior prompt can spell part of the draft's label ("prompt box"):
    /// masked first, it would rewrite the label, and a draft too short for
    /// the line pass would be left behind it.
    func testWithholdsAShortDraftWhoseLabelThePriorPromptSpells() throws {
        var snapshot = ClaudeSessionSnapshot(
            sessionID: "s1", origin: .localAuthenticated(peerUID: 501), agent: .claude,
            firstSeen: Date(timeIntervalSince1970: 0)
        )
        snapshot.latestPriorUserPrompt = "prompt box"
        let draft = ClaudePromptDraft(sessionID: "s1", beforeCursor: "tidy up", afterCursor: "")
        let context = ClaudeSessionContextText.text(for: snapshot, draft: draft)
        let withheld = [DiagnosticRecordRedaction.Withheld.priorPrompt("prompt box"), .draft(draft)]
            .compactMap { $0 }
        var record = recordCarrying(context)

        DiagnosticRecordRedaction.withhold(withheld, from: &record)

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(record), encoding: .utf8))
        XCTAssertFalse(encoded.contains("tidy up"), encoded)
        XCTAssertFalse(
            DiagnosticRecordRedaction.withholding(withheld, in: context, softWrapped: false).contains("tidy up"),
            "the agent source's harvest is taken from this text")
    }
}
