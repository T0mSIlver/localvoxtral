#if LOCALVOXTRAL_DOGFOOD

import Foundation
import Synchronization

/// Directory operations the store needs beyond writing one file. Split out as a
/// protocol for the same reason the registry splits its own IO: the pruning
/// rules are the part worth testing, and they should be testable without a real
/// directory or a real clock.
protocol DogfoodCaptureDirectoryIO: Sendable {
    /// File names directly inside `url`, or nil when the directory is absent.
    func contents(of url: URL) throws -> [String]?
    func remove(at url: URL) throws
    func read(from url: URL) throws -> Data?
}

struct DogfoodCaptureFileDirectoryIO: DogfoodCaptureDirectoryIO {
    func contents(of url: URL) throws -> [String]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    func remove(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func read(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}

/// Writes and prunes `DogfoodCaptureRecord`s on disk.
///
/// Compiled only into a `LOCALVOXTRAL_DOGFOOD` build. Within one, records are
/// still written only while the runtime opt-in is armed — the compile gate keeps
/// the code out of shipped builds, and the setting keeps it off until the owner
/// deliberately turns it on.
///
/// Design notes worth keeping:
///
/// * **The hardened write is reused, not reimplemented.**
///   `ClaudeRemoteHostFileStoreIO` already creates the directory 0700 (refusing
///   a symlinked, foreign-owned, or group-writable one), writes the temp file
///   `O_CREAT|O_EXCL|O_NOFOLLOW` at 0600, fsyncs, and replaces by `rename(2)`.
///   These records hold repository contents and screen text; they deserve the
///   same handling as the token store, and a second implementation of it would
///   only be a second thing to get wrong.
/// * **The flag lives in the FILE NAME, not the JSON.** Pruning has to know
///   which records are flagged, and reading every record to find out would make
///   a routine prune read every captured prompt back off disk. Flagging renames
///   the file instead, so the retention pass is a directory listing.
/// * **There is no uploader and must never be one.** The compile gate exists to
///   make "this build cannot exfiltrate context" a property of the artifact
///   rather than a promise about a setting.
struct DogfoodCaptureStore: Sendable {
    struct Retention: Sendable, Equatable {
        /// Unflagged records kept, newest first. Flagged records are never
        /// counted against this — they are the review queue and the corpus
        /// candidates, and silently deleting one would lose the exact case the
        /// cycle exists to find.
        var maximumUnflaggedRecords: Int
        /// Unflagged records older than this are removed. Flagged records are
        /// exempt for the same reason.
        var maximumUnflaggedAge: TimeInterval

        static let `default` = Retention(
            maximumUnflaggedRecords: 500,
            maximumUnflaggedAge: 14 * 24 * 60 * 60
        )
    }

    enum StoreError: Error, Equatable {
        case encodingFailed
        /// The record exists but could not be read back or decoded. Flagging
        /// refuses rather than proceeding — see `flagMostRecentRecord`.
        case unreadableRecord(path: String)
    }

    /// Serializes every read-modify-write over a record file.
    ///
    /// The store is a value type and its two mutating paths run on different
    /// isolation domains — flagging from the menu on the main actor, the
    /// behavior patch from a detached task — over the same file. Their
    /// interleaving is not theoretical: flagging RENAMES (write flagged, remove
    /// plain), so a patch that read the plain file, lost the race, and then
    /// wrote it back would resurrect the unflagged copy ALONGSIDE the flagged
    /// one. Two records for one dictation, one of them stale and exempt from
    /// nothing, is exactly the contradiction `flagMostRecentRecord` refuses to
    /// create for itself.
    ///
    /// Process-wide (`static`) rather than per-instance because the identity
    /// that matters is the directory, and every store in a process points at the
    /// same one. Held across locate/read/encode/write only — never across an
    /// `await`, and never re-entered: the locked paths call the private
    /// unlocked bodies, not each other.
    private static let recordMutationLock = Mutex(0)

    private let directoryURL: URL
    private let io: ClaudeRemoteHostStoreIO
    private let directoryIO: DogfoodCaptureDirectoryIO
    private let retention: Retention
    private let now: @Sendable () -> Date

    init(
        directoryURL: URL? = nil,
        io: ClaudeRemoteHostStoreIO = ClaudeRemoteHostFileStoreIO(),
        directoryIO: DogfoodCaptureDirectoryIO = DogfoodCaptureFileDirectoryIO(),
        retention: Retention = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directoryURL = directoryURL ?? DogfoodCaptureStore.defaultDirectoryURL()
        self.io = io
        self.directoryIO = directoryIO
        self.retention = retention
        self.now = now
    }

    static func defaultDirectoryURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("dogfood", isDirectory: true)
    }

    var directory: URL { directoryURL }

    // MARK: - Writing

    /// Writes `record` and prunes. Returns the file it wrote.
    @discardableResult
    func write(_ record: DogfoodCaptureRecord) throws -> URL {
        try Self.recordMutationLock.withLock { _ in try writeLocked(record) }
    }

    private func writeLocked(_ record: DogfoodCaptureRecord) throws -> URL {
        var redacted = record
        let redactions = DogfoodCaptureRedaction.redact(&redacted)
        if redactions > 0 {
            // Never silent: a review that finds `<redacted>` in an excerpt needs
            // to know it was the redactor, not the pipeline, that put it there.
            Log.diagnostics.info(
                "Dogfood capture: redacted \(redactions, privacy: .public) token-shaped run(s)"
            )
        }

        guard let data = try? makeEncoder().encode(redacted) else {
            throw StoreError.encodingFailed
        }

        let url = directoryURL.appendingPathComponent(
            DogfoodCaptureFileName.name(for: redacted, flagged: redacted.flagged),
            isDirectory: false
        )
        try io.write(data, to: url)
        try? pruneLocked()
        return url
    }

    // MARK: - Patching

    /// Attaches the post-commit behavior signal to an already-written record,
    /// returning where it landed.
    ///
    /// A patch rather than a delayed write: the record is what the commit path
    /// knew AT commit, and holding it back for up to fifteen seconds to wait for
    /// a signal would lose every record to a quit, a crash, or a cancelled task
    /// — including the ones whose commit went wrong, which are exactly the ones
    /// worth having.
    ///
    /// Read-modify-write of the SAME file, never `write(_:)`: that recomputes
    /// the file name from the record, and `capturedAt` has lost its milliseconds
    /// to the ISO-8601 round trip by the time it is decoded again, so a
    /// rewritten record would land beside the original as a duplicate rather
    /// than on top of it. Following `flagMostRecentRecord`, the name on disk is
    /// authoritative and is preserved.
    ///
    /// The behavior block is fixed slugs and numbers, so no re-redaction is
    /// needed (and the rest of the record was redacted on its way in).
    @discardableResult
    func attachBehavior(
        _ behavior: DogfoodCaptureRecord.Behavior,
        toRecordAt url: URL
    ) throws -> URL {
        try Self.recordMutationLock.withLock { _ in
            try attachBehaviorLocked(behavior, toRecordAt: url)
        }
    }

    private func attachBehaviorLocked(
        _ behavior: DogfoodCaptureRecord.Behavior,
        toRecordAt url: URL
    ) throws -> URL {
        // Flagging renames; a record flagged during the watch window is still
        // this dictation's record and must still receive its signal. The
        // locate/read/write below is one critical section, so a concurrent
        // flag either completes before the locate (and is followed) or after
        // the write (and carries the behavior with it).
        let target = try locateRecord(writtenAt: url)
        guard
            let data = try directoryIO.read(from: target),
            var record = try? makeDecoder().decode(DogfoodCaptureRecord.self, from: data)
        else {
            throw StoreError.unreadableRecord(path: target.path)
        }

        record.behavior = behavior
        guard let encoded = try? makeEncoder().encode(record) else {
            throw StoreError.encodingFailed
        }
        try io.write(encoded, to: target)
        return target
    }

    /// The record's current location: where it was written, or its flagged
    /// rename. Throws when neither exists — a pruned or hand-deleted record is
    /// not something to recreate.
    private func locateRecord(writtenAt url: URL) throws -> URL {
        if (try? directoryIO.read(from: url)) ?? nil != nil { return url }

        let name = url.lastPathComponent
        guard name.hasSuffix(DogfoodCaptureFileName.plainSuffix) else {
            throw StoreError.unreadableRecord(path: url.path)
        }
        let base = String(name.dropLast(DogfoodCaptureFileName.plainSuffix.count))
        let flagged = url.deletingLastPathComponent().appendingPathComponent(
            base + DogfoodCaptureFileName.flaggedSuffix,
            isDirectory: false
        )
        guard (try? directoryIO.read(from: flagged)) ?? nil != nil else {
            throw StoreError.unreadableRecord(path: url.path)
        }
        return flagged
    }

    // MARK: - Flagging

    /// Marks the most recently captured record for review, returning its new
    /// location. Nil when nothing has been captured yet.
    ///
    /// Flagging an already-flagged record is a no-op rather than an error: the
    /// affordance is a single menu item and pressing it twice should not fail.
    /// Refuses rather than guessing when the record cannot be read back or
    /// decoded. The obvious alternative — rename the file and leave its bytes
    /// alone — produces a record whose NAME says flagged and whose JSON says it
    /// is not, and the name is what every later `listRecords` believes. That
    /// contradiction is permanent (a second flag call sees "already flagged" and
    /// no-ops) and it silently disarms retention's flagged exemption on a
    /// record the owner explicitly asked to keep. Better to fail loudly.
    @discardableResult
    func flagMostRecentRecord() throws -> URL? {
        try Self.recordMutationLock.withLock { _ in try flagMostRecentRecordLocked() }
    }

    private func flagMostRecentRecordLocked() throws -> URL? {
        guard let latest = try listRecords().first else { return nil }
        guard !latest.flagged else { return latest.url }

        guard
            let data = try directoryIO.read(from: latest.url),
            var record = try? makeDecoder().decode(DogfoodCaptureRecord.self, from: data)
        else {
            throw StoreError.unreadableRecord(path: latest.url.path)
        }

        // The name is the index; the JSON is the truth. Both are updated, so a
        // record read on its own still reports its own flagged state.
        record.flagged = true
        guard let updated = try? makeEncoder().encode(record) else {
            throw StoreError.encodingFailed
        }

        // Anchored to the suffix, not `replacingOccurrences`: an unanchored
        // replacement rewrites the first `.json` anywhere in the name.
        let base = String(latest.fileName.dropLast(DogfoodCaptureFileName.plainSuffix.count))
        let destination = directoryURL.appendingPathComponent(
            base + DogfoodCaptureFileName.flaggedSuffix,
            isDirectory: false
        )
        try io.write(updated, to: destination)
        try? directoryIO.remove(at: latest.url)
        return destination
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Listing & pruning

    struct Entry: Sendable, Equatable {
        var fileName: String
        var url: URL
        var capturedAt: Date
        var flagged: Bool
    }

    /// Every record in the directory, newest first. Files that do not parse as
    /// capture names are ignored rather than deleted — the directory is the
    /// owner's, and pruning has no business removing something it cannot read.
    func listRecords() throws -> [Entry] {
        guard let names = try directoryIO.contents(of: directoryURL) else { return [] }
        return names.compactMap { name -> Entry? in
            guard let parsed = DogfoodCaptureFileName.parse(name) else { return nil }
            return Entry(
                fileName: name,
                url: directoryURL.appendingPathComponent(name, isDirectory: false),
                capturedAt: parsed.capturedAt,
                flagged: parsed.flagged
            )
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Applies the retention rules. Flagged records are never removed.
    func prune() throws {
        try Self.recordMutationLock.withLock { _ in try pruneLocked() }
    }

    /// The retention body, without the lock. Callers already inside the
    /// critical section use this — `Mutex` is not recursive.
    private func pruneLocked() throws {
        let records = try listRecords()
        let cutoff = now().addingTimeInterval(-retention.maximumUnflaggedAge)

        // `records` is newest-first, so this is a POSITION, not a survivor
        // count: the first `maximumUnflaggedRecords` unflagged records are the
        // ones kept, and everything past that position goes regardless of how
        // many of the earlier ones the age rule already removed.
        var unflaggedSeen = 0
        for record in records where !record.flagged {
            unflaggedSeen += 1
            let tooOld = record.capturedAt < cutoff
            let beyondCount = unflaggedSeen > retention.maximumUnflaggedRecords
            guard tooOld || beyondCount else { continue }
            do {
                try directoryIO.remove(at: record.url)
            } catch {
                // Loud, per the repo's rule about silent failure paths: a prune
                // that decided to delete and then could not is why a capture
                // directory grows without explanation.
                Log.diagnostics.notice(
                    "Dogfood capture: prune failed for \(record.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

/// Capture file naming. The timestamp and the flag both live in the name so a
/// retention pass never has to open a record.
enum DogfoodCaptureFileName {
    static let prefix = "dictation-"
    static let flaggedSuffix = ".flagged.json"
    static let plainSuffix = ".json"

    static func name(for record: DogfoodCaptureRecord, flagged: Bool) -> String {
        let stamp = makeStampFormatter().string(from: record.capturedAt)
        let shortID = String(record.id.prefix(8))
        return "\(prefix)\(stamp)-\(shortID)\(flagged ? flaggedSuffix : plainSuffix)"
    }

    static func parse(_ name: String) -> (capturedAt: Date, flagged: Bool)? {
        guard name.hasPrefix(prefix) else { return nil }
        let flagged = name.hasSuffix(flaggedSuffix)
        guard flagged || name.hasSuffix(plainSuffix) else { return nil }

        let body = name.dropFirst(prefix.count)
            .dropLast((flagged ? flaggedSuffix : plainSuffix).count)
        // `<stamp>-<shortID>`; the stamp itself contains no hyphen.
        guard let separator = body.firstIndex(of: "-") else { return nil }
        let stamp = String(body[body.startIndex..<separator])
        guard let capturedAt = makeStampFormatter().date(from: stamp) else { return nil }
        return (capturedAt, flagged)
    }

    /// Compact, sortable, hyphen-free (the name uses `-` as its separator), and
    /// fixed to UTC so records sort the same way regardless of where the Mac was
    /// when they were written.
    ///
    /// Millisecond resolution, not seconds: the write path replaces by
    /// `rename(2)`, so two records that produced the same name would leave only
    /// the later one, silently. Seconds plus eight UUID characters makes that
    /// vanishingly unlikely in the field but perfectly reachable from a test
    /// with a frozen injected clock.
    ///
    /// A factory rather than a shared instance, matching `DiagnosticsExporter`:
    /// `DateFormatter` is not `Sendable`, and a stored one would either need an
    /// unsafe opt-out or pin this type to an actor it has no reason to be on.
    static func makeStampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}

/// Scrubs token-shaped runs out of a record before it reaches disk.
///
/// The remote-enrollment token is 43 base64url characters with no prefix, and
/// dogfooding the remote integration means running the enrollment command in a
/// terminal — which is precisely the screen this build captures. The registry
/// stores only hashes, so redaction cannot match a known plaintext; it matches
/// the shape instead.
///
/// It errs in BOTH directions, deliberately, and it is worth being precise
/// about which:
///
/// * It over-matches any isolated 43-character base64url run that is not a
///   token. Rare in prose and code, and the cost is one masked line of a
///   dev-only record.
/// * It under-matches a token GLUED to other base64url characters — inside a
///   longer path segment, or concatenated with an identifier — because that
///   forms a run longer than 43. It also misses a token that lost or gained a
///   character in transcription.
///
/// Widening it to "any long base64-ish thing" would shred the hashes, blobs,
/// and identifiers a review needs to read, so the exact-length rule stays. This
/// is a backstop for a dev-only artifact, not a guarantee — the guarantee is
/// that the file never leaves the machine.
enum DogfoodCaptureRedaction {
    static let tokenLength = 43

    /// Redacts in place, returning how many runs were replaced.
    static func redact(_ record: inout DogfoodCaptureRecord) -> Int {
        var count = 0

        func scrub(_ text: inout String) {
            let redacted = redacting(text, count: &count)
            text = redacted
        }
        func scrubOptional(_ text: inout String?) {
            guard let value = text else { return }
            text = redacting(value, count: &count)
        }

        scrub(&record.text.rawTranscript)
        scrub(&record.text.workingText)
        scrub(&record.text.groundedText)
        scrubOptional(&record.text.systemPrompt)
        scrubOptional(&record.text.polishedOutput)
        scrubOptional(&record.text.committedText)
        record.text.userPrompts = record.text.userPrompts.map { redacting($0, count: &count) }

        if var screen = record.screen {
            scrubOptional(&screen.sanitizedText)
            record.screen = screen
        }

        // Every string a source carries, not just the obviously bulky ones. A
        // proposal's `term` comes out of the harvest and its `heard` spans come
        // out of the transcript, so a token the collector walked into — or one
        // the user read aloud — reaches disk through an entry just as easily as
        // through the harvest itself.
        func scrubEntries(_ entries: inout [DogfoodCaptureRecord.Source.Entry]) {
            for index in entries.indices {
                entries[index].term = redacting(entries[index].term, count: &count)
                entries[index].heard = entries[index].heard.map {
                    redacting($0, count: &count)
                }
            }
        }

        for index in record.sources.indices {
            record.sources[index].harvest = record.sources[index].harvest.map {
                redacting($0, count: &count)
            }
            scrubOptional(&record.sources[index].renderedExcerpt)
            scrubEntries(&record.sources[index].entries)
            scrubEntries(&record.sources[index].phoneticEntries)
            scrubEntries(&record.sources[index].verificationEntries)
        }

        return count
    }

    /// Replaces every maximal base64url run of exactly `tokenLength`
    /// characters. Runs of any other length are left alone: a token is fixed
    /// width, and matching "long base64-ish thing" would shred hashes and blobs
    /// the review needs to read.
    static func redacting(_ text: String, count: inout Int) -> String {
        guard text.count >= tokenLength else { return text }

        var output = ""
        output.reserveCapacity(text.count)
        var run = ""

        func flush() {
            if run.count == tokenLength {
                output += ClaudeRemoteTokenRedaction.placeholder
                count += 1
            } else {
                output += run
            }
            run.removeAll(keepingCapacity: true)
        }

        for character in text {
            if isBase64URL(character) {
                run.append(character)
            } else {
                flush()
                output.append(character)
            }
        }
        flush()
        return output
    }

    private static func isBase64URL(_ character: Character) -> Bool {
        character.isLetter && character.isASCII
            || character.isNumber && character.isASCII
            || character == "-"
            || character == "_"
    }
}

#endif
