#if LOCALVOXTRAL_DOGFOOD

import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// In-memory disk for the capture store, mirroring `MemoryStoreIO` in the
/// registry tests: the retention rules and the naming contract are the parts
/// worth asserting, and neither needs a real directory. The hardened write path
/// itself is `ClaudeRemoteHostFileStoreIO`'s, already covered by its own tests.
private final class MemoryCaptureIO: ClaudeRemoteHostStoreIO, DogfoodCaptureDirectoryIO {
    private let files = Mutex<[String: Data]>([:])

    // ClaudeRemoteHostStoreIO
    func read(from url: URL) throws -> Data? {
        files.withLock { $0[url.path] }
    }

    func write(_ data: Data, to url: URL) throws {
        files.withLock { $0[url.path] = data }
    }

    // DogfoodCaptureDirectoryIO
    func contents(of url: URL) throws -> [String]? {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return files.withLock { store in
            store.keys
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
        }
    }

    func remove(at url: URL) throws {
        files.withLock { $0[url.path] = nil }
    }

    func seed(_ data: Data, at url: URL) {
        files.withLock { $0[url.path] = data }
    }

    var fileNames: [String] {
        files.withLock { Array($0.keys.map { URL(fileURLWithPath: $0).lastPathComponent }) }
    }
}

private final class CaptureTestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}

final class DogfoodCaptureStoreTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/lvx-dogfood-test")
    private var io: MemoryCaptureIO!
    private let clock = CaptureTestClock()

    override func setUp() {
        super.setUp()
        io = MemoryCaptureIO()
        clock.set(Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func makeStore(
        retention: DogfoodCaptureStore.Retention = .default
    ) -> DogfoodCaptureStore {
        let clock = self.clock
        return DogfoodCaptureStore(
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
    ) -> DogfoodCaptureRecord {
        DogfoodCaptureRecord(
            id: id,
            capturedAt: capturedAt ?? clock.now(),
            session: .init(
                targetBundleID: "com.mitchellh.ghostty",
                targetKind: "terminal",
                outputMode: "overlayBuffer",
                promptProfile: "agent",
                endpointClass: "loopback",
                polishModel: "qwen35-4b"
            ),
            join: nil,
            screen: screenText.map {
                DogfoodCaptureRecord.Screen(
                    route: "herdrPaneRead",
                    decision: "render",
                    cause: nil,
                    sanitizedCharacterCount: $0.count,
                    sanitizedText: $0
                )
            },
            allocation: [],
            sources: [],
            text: .init(
                rawTranscript: rawTranscript,
                workingText: rawTranscript,
                groundedText: rawTranscript,
                systemPrompt: nil,
                userPrompts: [],
                polishedOutput: nil,
                committedText: nil
            ),
            timings: .init()
        )
    }

    // MARK: - Writing and round-tripping

    func testWriteProducesAParseableNameAndRoundTripsTheRecord() throws {
        let store = makeStore()
        let record = makeRecord(rawTranscript: "check DictationViewModel plus Session")

        let url = try store.write(record)

        let parsed = try XCTUnwrap(DogfoodCaptureFileName.parse(url.lastPathComponent))
        XCTAssertEqual(parsed.capturedAt.timeIntervalSince1970,
                       record.capturedAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertFalse(parsed.flagged)

        let data = try XCTUnwrap(io.read(from: url))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DogfoodCaptureRecord.self, from: data)
        XCTAssertEqual(decoded.text.rawTranscript, "check DictationViewModel plus Session")
        XCTAssertEqual(decoded.schemaVersion, DogfoodCaptureRecord.currentSchemaVersion)
    }

    // MARK: - Retention

    func testCountRetentionRemovesOldestUnflaggedRecordsFirst() throws {
        let store = makeStore(
            retention: .init(maximumUnflaggedRecords: 2, maximumUnflaggedAge: .greatestFiniteMagnitude)
        )

        let oldest = try store.write(makeRecord(id: "aaaaaaaa-oldest"))
        clock.advance(60)
        let middle = try store.write(makeRecord(id: "bbbbbbbb-middle"))
        clock.advance(60)
        let newest = try store.write(makeRecord(id: "cccccccc-newest"))

        XCTAssertNil(try io.read(from: oldest), "oldest unflagged record should be pruned")
        XCTAssertNotNil(try io.read(from: middle))
        XCTAssertNotNil(try io.read(from: newest))
    }

    func testAgeRetentionRemovesRecordsPastTheWindow() throws {
        let store = makeStore(
            retention: .init(maximumUnflaggedRecords: .max, maximumUnflaggedAge: 3600)
        )

        let stale = try store.write(makeRecord(id: "aaaaaaaa-stale"))
        clock.advance(7200)
        let fresh = try store.write(makeRecord(id: "bbbbbbbb-fresh"))

        XCTAssertNil(try io.read(from: stale))
        XCTAssertNotNil(try io.read(from: fresh))
    }

    /// The whole point of flagging: a flagged record is a corpus candidate, and
    /// retention silently eating one would lose exactly the case the dogfooding
    /// cycle exists to find.
    func testFlaggedRecordsSurviveBothRetentionRules() throws {
        let store = makeStore(
            retention: .init(maximumUnflaggedRecords: 1, maximumUnflaggedAge: 3600)
        )

        try store.write(makeRecord(id: "aaaaaaaa-keepme"))
        let flagged = try XCTUnwrap(try store.flagMostRecentRecord())

        clock.advance(7200)
        try store.write(makeRecord(id: "bbbbbbbb-newer"))
        clock.advance(7200)
        try store.write(makeRecord(id: "cccccccc-newest"))

        XCTAssertNotNil(try io.read(from: flagged),
                        "a flagged record must survive both the count and the age rule")
    }

    func testPruneIgnoresFilesItCannotParse() throws {
        let store = makeStore(
            retention: .init(maximumUnflaggedRecords: 0, maximumUnflaggedAge: 0)
        )
        let foreign = directory.appendingPathComponent("notes.txt", isDirectory: false)
        try io.write(Data("owner's own file".utf8), to: foreign)

        try store.write(makeRecord())
        try store.prune()

        XCTAssertNotNil(try io.read(from: foreign),
                        "pruning must not delete files it did not write")
    }

    // MARK: - Flagging

    func testFlaggingRenamesTheFileAndSetsTheFlagInsideIt() throws {
        let store = makeStore()
        let original = try store.write(makeRecord(id: "aaaaaaaa-flagme"))

        let flagged = try XCTUnwrap(try store.flagMostRecentRecord())

        XCTAssertNil(try io.read(from: original), "the unflagged file should be gone")
        XCTAssertTrue(flagged.lastPathComponent.hasSuffix(DogfoodCaptureFileName.flaggedSuffix))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            DogfoodCaptureRecord.self,
            from: try XCTUnwrap(io.read(from: flagged))
        )
        XCTAssertTrue(decoded.flagged, "the record must report its own flagged state")
    }

    func testFlaggingTwiceIsANoOp() throws {
        let store = makeStore()
        try store.write(makeRecord(id: "aaaaaaaa-flagme"))

        let first = try XCTUnwrap(try store.flagMostRecentRecord())
        let second = try XCTUnwrap(try store.flagMostRecentRecord())

        XCTAssertEqual(first, second)
        XCTAssertEqual(io.fileNames.count, 1)
    }

    func testFlaggingWithNoRecordsReturnsNil() throws {
        XCTAssertNil(try makeStore().flagMostRecentRecord())
    }

    /// Refusing beats renaming. A flagged NAME over unflagged CONTENT is a
    /// contradiction that never resolves: the next `listRecords` believes the
    /// name, so a second flag call no-ops, and retention's flagged exemption is
    /// silently disarmed on a record the owner asked to keep.
    func testFlaggingRefusesWhenTheRecordCannotBeDecoded() throws {
        let store = makeStore()
        let name = "dictation-20260724T191408.000Z-deadbeef.json"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        io.seed(Data("{ not a record }".utf8), at: url)

        XCTAssertThrowsError(try store.flagMostRecentRecord()) { error in
            guard case DogfoodCaptureStore.StoreError.unreadableRecord = error else {
                return XCTFail("expected unreadableRecord, got \(error)")
            }
        }
        XCTAssertNotNil(try io.read(from: url), "the original must be left untouched")
        XCTAssertEqual(io.fileNames, [name], "no flagged twin may be created")
    }

    // MARK: - Naming

    func testFileNameParsingRejectsForeignNames() {
        XCTAssertNil(DogfoodCaptureFileName.parse("notes.txt"))
        XCTAssertNil(DogfoodCaptureFileName.parse("dictation-nonsense-abc.json"))
        XCTAssertNil(DogfoodCaptureFileName.parse("dictation-20260724T191408.000Z-abc123.txt"))
        XCTAssertNotNil(DogfoodCaptureFileName.parse("dictation-20260724T191408.000Z-abc123.json"))
        XCTAssertEqual(
            DogfoodCaptureFileName.parse(
                "dictation-20260724T191408.000Z-abc123.flagged.json"
            )?.flagged,
            true
        )
    }

    /// Two records in the same clock second must not collide: the write path
    /// replaces by `rename(2)`, so a collision would silently keep only the
    /// later one.
    func testSameSecondRecordsGetDistinctNames() throws {
        let store = makeStore()
        let first = try store.write(makeRecord(id: "aaaaaaaa-first"))
        clock.advance(0.010)
        let second = try store.write(makeRecord(id: "bbbbbbbb-second"))

        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(try io.read(from: first))
        XCTAssertNotNil(try io.read(from: second))
    }
}

/// Token-shaped redaction. Enrollment tokens are 43 base64url characters with no
/// prefix and the registry keeps only hashes, so shape is the only thing
/// redaction can match — and dogfooding the remote integration means the
/// enrollment command is on the very screen this build captures.
final class DogfoodCaptureRedactionTests: XCTestCase {
    private func token(length: Int) -> String {
        String(repeating: "a", count: length)
    }

    func testRedactsATokenLengthBase64URLRun() {
        var count = 0
        let secret = token(length: 43)
        let result = DogfoodCaptureRedaction.redacting(
            "export TOKEN=\(secret) && claude plugin install",
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
            XCTAssertEqual(DogfoodCaptureRedaction.redacting(text, count: &count), text)
            XCTAssertEqual(count, 0, "length \(length) must not be treated as a token")
        }
    }

    func testRedactsAcrossEveryContentBearingFieldOfARecord() {
        let secret = token(length: 43)
        var record = DogfoodCaptureRecord(
            id: "aaaaaaaa-0000",
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

        let redactions = DogfoodCaptureRedaction.redact(&record)

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
}

#endif
