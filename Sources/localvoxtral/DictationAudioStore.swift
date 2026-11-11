import Foundation

/// What a saved dictation keeps in the audio store, taken at stop.
struct KeptDictationAudio: Sendable {
    /// 16 kHz, the file the replay eval reads.
    let pcm16: Data?
    /// At the input device's own rate, with "Keep audio at full quality" on.
    let fullQuality: FullQualityAudio?
}

/// The opt-in audio of saved dictations: one WAV per history record, named by
/// the record's id, in a folder under Application Support, and with "Keep
/// audio at full quality" on a second one of the same name in the sibling
/// `<folder>-full-quality`. Nothing reads them but the replay eval
/// (`docs/agent/test-tiers.md`, "Replaying stored dictations"), which reads
/// the 16 kHz file, and nothing sends them anywhere.
///
/// A sibling folder, not a second name in this one: a build from before
/// full quality sweeps every file here that is not `<uuid>.wav` into the
/// quarantine, and never looks anywhere else.
///
/// Every call comes from `DictationSessionStore`'s serialized write queue, so
/// a file is written in the same step as its record and deleted in the same
/// step as its record. This type only touches the two folders, and treats
/// them as one: an id is stored when either folder holds its file, and
/// every delete, move and count covers both.
final class DictationAudioStore: Sendable {
    let directoryURL: URL
    let fullQualityDirectoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        fullQualityDirectoryURL = directoryURL.deletingLastPathComponent()
            .appendingPathComponent("\(directoryURL.lastPathComponent)-full-quality", isDirectory: true)
    }

    func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).wav")
    }

    func fullQualityFileURL(for id: UUID) -> URL {
        fullQualityDirectoryURL.appendingPathComponent("\(id.uuidString).wav")
    }

    /// Both of an id's files, 16 kHz first.
    private func fileURLs(for id: UUID) -> [URL] {
        [fileURL(for: id), fullQualityFileURL(for: id)]
    }

    private var directories: [URL] { [directoryURL, fullQualityDirectoryURL] }

    func write(pcm16 pcm: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        try DictationAudioRecording.wav(fromPCM16: pcm)
            .write(to: fileURL(for: id), options: .atomic)
    }

    func write(fullQuality audio: FullQualityAudio, for id: UUID) throws {
        try FileManager.default.createDirectory(
            at: fullQualityDirectoryURL, withIntermediateDirectories: true)
        try DictationAudioRecording.wav(fromPCM16: audio.pcm16, sampleRate: audio.sampleRate)
            .write(to: fullQualityFileURL(for: id), options: .atomic)
    }

    /// The ids that have a file in either folder.
    func storedIDs() -> Set<UUID> {
        directories.reduce(into: Set<UUID>()) { ids, directory in
            ids.formUnion(Self.recordingIDs(in: directory))
        }
    }

    private static func recordingIDs(in directory: URL) -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap(recordingID(fromFileName:)))
    }

    private static func recordingID(fromFileName name: String) -> UUID? {
        guard name.hasSuffix(".wav") else { return nil }
        return UUID(uuidString: String(name.dropLast(4)))
    }

    /// Deletes the files of these ids. Returns how many recordings lost a
    /// file. A file that will not go is logged and left for the next sweep
    /// (every trim, and launch), and the Settings row keeps counting it.
    @discardableResult
    func remove(_ ids: some Sequence<UUID>) -> Int {
        var removed = 0
        for id in ids {
            var removedOne = false
            for url in fileURLs(for: id) {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    removedOne = true
                } catch {
                    Log.persistence.error(
                        "History: could not delete the audio of dictation \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            if removedOne { removed += 1 }
        }
        return removed
    }

    /// Deletes every file whose id is not in `kept`.
    @discardableResult
    func removeAll(except kept: Set<UUID>) -> Int {
        remove(storedIDs().subtracting(kept))
    }

    /// Moves the files of exactly these ids into `folder`, for the sweeps:
    /// nothing they find is deleted outright (#985). A full-quality file
    /// goes in as `<id>.full-quality.wav`, beside its 16 kHz one. Returns
    /// how many recordings moved.
    @discardableResult
    func quarantine(_ ids: some Sequence<UUID>, into folder: URL) -> Int {
        var moved = 0
        for id in ids {
            var movedOne = false
            let url = fileURL(for: id)
            if FileManager.default.fileExists(atPath: url.path), Self.move(url, into: folder) {
                movedOne = true
            }
            let fullQuality = fullQualityFileURL(for: id)
            if FileManager.default.fileExists(atPath: fullQuality.path),
               Self.move(fullQuality, into: folder, as: "\(id.uuidString).full-quality.wav")
            {
                movedOne = true
            }
            if movedOne { moved += 1 }
        }
        return moved
    }

    /// Moves into `folder` whatever in either folder is not a recording and
    /// was last written before `cutoff`: the temporary file an atomic write
    /// leaves when the app dies mid-write. A newer one may be another copy
    /// of the app writing right now.
    func quarantineStrayFiles(writtenBefore cutoff: Date, into folder: URL) {
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where Self.recordingID(fromFileName: name) == nil {
                let url = directory.appendingPathComponent(name)
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                guard let modified, modified < cutoff else { continue }
                Self.move(url, into: folder)
            }
        }
    }

    @discardableResult
    private static func move(_ url: URL, into folder: URL, as name: String? = nil) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Never over a file already there: another running copy may have
            // quarantined the same recording a moment ago.
            let name = name ?? url.lastPathComponent
            var destination = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(UUID().uuidString)-\(name)")
            }
            try FileManager.default.moveItem(at: url, to: destination)
            return true
        } catch {
            Log.persistence.error(
                "History: could not move \(url.lastPathComponent, privacy: .public) to quarantine: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Deletes every recording. Returns how many it deleted.
    @discardableResult
    func removeAll() -> Int {
        remove(storedIDs())
    }

    /// How many dictations have audio and its size, both folders' files
    /// together, for the Settings row. A missing folder holds none; a folder
    /// that will not list throws, so the row never reads a failure as
    /// nothing to delete (#1166).
    func summary() throws -> (recordings: Int, bytes: Int) {
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return (0, 0) }
        for directory in existing {
            _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }
        return (storedIDs().count, totalBytes())
    }

    func totalBytes() -> Int {
        storedIDs().reduce(0) { total, id in
            fileURLs(for: id).reduce(total) { total, url in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                return total + ((size as? NSNumber)?.intValue ?? 0)
            }
        }
    }
}
