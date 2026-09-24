import Foundation

/// The opt-in audio of saved dictations: one WAV per history record, named by
/// the record's id, in a folder under Application Support. Nothing reads it
/// but the replay eval (`docs/agent/test-tiers.md`, "Replaying stored
/// dictations"), and nothing sends it anywhere.
///
/// Every call comes from `DictationSessionStore`'s serialized write queue, so
/// a file is written in the same step as its record and deleted in the same
/// step as its record. This type only touches the folder.
final class DictationAudioStore: Sendable {
    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    static func defaultDirectoryURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("dictation-audio", isDirectory: true)
    }

    func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).wav")
    }

    func write(pcm16 pcm: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        try DictationAudioRecording.wav(fromPCM16: pcm)
            .write(to: fileURL(for: id), options: .atomic)
    }

    /// The ids that have a file.
    func storedIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return Set(names.compactMap { name in
            guard name.hasSuffix(".wav") else { return nil }
            return UUID(uuidString: String(name.dropLast(4)))
        })
    }

    /// Deletes the files of these ids. Returns how many it deleted.
    @discardableResult
    func remove(_ ids: some Sequence<UUID>) -> Int {
        var removed = 0
        for id in ids {
            if (try? FileManager.default.removeItem(at: fileURL(for: id))) != nil { removed += 1 }
        }
        return removed
    }

    /// Deletes every file whose record is gone. Retention and Delete go
    /// through the history store, so this is how their audio follows them,
    /// whatever deleted the record.
    @discardableResult
    func removeAll(except kept: Set<UUID>) -> Int {
        remove(storedIDs().subtracting(kept))
    }

    /// Deletes the folder. Returns how many recordings were in it.
    @discardableResult
    func removeAll() -> Int {
        let count = storedIDs().count
        try? FileManager.default.removeItem(at: directoryURL)
        return count
    }

    /// Bytes on disk, for the Settings row.
    func totalBytes() -> Int {
        storedIDs().reduce(0) { total, id in
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL(for: id).path))?[.size]
            return total + ((size as? NSNumber)?.intValue ?? 0)
        }
    }
}
