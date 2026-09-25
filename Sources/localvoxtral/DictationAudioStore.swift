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

    /// Deletes the files of these ids. Returns how many it deleted. A file
    /// that will not go is logged and left for the next sweep (every trim,
    /// and launch), and the Settings row keeps counting it.
    @discardableResult
    func remove(_ ids: some Sequence<UUID>) -> Int {
        var removed = 0
        for id in ids {
            let url = fileURL(for: id)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                Log.persistence.error(
                    "History: could not delete the audio of dictation \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
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

    /// Deletes whatever in the folder is not a recording: the temporary file
    /// an atomic write leaves when the app dies mid-write. Launch only, when
    /// no write is in flight.
    func removeStrayFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        for name in names {
            let isRecording = name.hasSuffix(".wav") && UUID(uuidString: String(name.dropLast(4))) != nil
            guard !isRecording else { continue }
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(name))
        }
    }

    /// Deletes every recording. Returns how many it deleted.
    @discardableResult
    func removeAll() -> Int {
        remove(storedIDs())
    }

    /// Bytes on disk, for the Settings row.
    func totalBytes() -> Int {
        storedIDs().reduce(0) { total, id in
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL(for: id).path))?[.size]
            return total + ((size as? NSNumber)?.intValue ?? 0)
        }
    }
}
