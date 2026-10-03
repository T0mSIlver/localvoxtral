import Foundation

/// One audio file in the voice memo folder, as a scan sees it (#925).
package struct VoiceMemoFile: Equatable, Sendable {
    package let name: String
    package let size: Int
    package let modifiedAt: Date
    /// False while iCloud holds the bytes and this Mac has only the name.
    package let isDownloaded: Bool
    /// The file's inode: the recording's identity, which a rename keeps
    /// (#1508). Nil when it could not be read.
    package let fileNumber: UInt64?

    package init(name: String, size: Int, modifiedAt: Date, isDownloaded: Bool = true, fileNumber: UInt64? = nil) {
        self.name = name
        self.size = size
        self.modifiedAt = modifiedAt
        self.isDownloaded = isDownloaded
        self.fileNumber = fileNumber
    }
}

/// The iCloud Drive folder an iPhone or Apple Watch Shortcut saves voice
/// memos into.
package enum VoiceMemoFolder {
    /// The folder's name in iCloud Drive, which the Shortcut recipe names.
    package static let name = "localvoxtral"

    /// Formats a Shortcut's Record Audio or a Voice Memos share can produce.
    package static let audioExtensions: Set<String> = ["m4a", "wav", "caf", "aac", "mp3", "aif", "aiff"]

    /// iCloud Drive's root on this Mac. Reading it is what raises the
    /// "access files in iCloud Drive" prompt.
    package static func iCloudDriveURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    package static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        iCloudDriveURL(home: home).appendingPathComponent(name, isDirectory: true)
    }

    /// Hidden files are iCloud's own (an old-style `.name.icloud` stub, a
    /// partial download) or the Finder's.
    package static func isAudioFileName(_ name: String) -> Bool {
        !name.hasPrefix(".") && audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The audio files directly in `directory`.
    package static func list(_ directory: URL) throws -> [VoiceMemoFile] {
        var keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        #if canImport(Darwin)
        keys.append(.ubiquitousItemDownloadingStatusKey)
        #endif
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [])
        return urls.compactMap { url in
            guard isAudioFileName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }
            var downloaded = true
            #if canImport(Darwin)
            // Nil outside iCloud: a plain local folder is always downloaded.
            if let status = values.ubiquitousItemDownloadingStatus { downloaded = status == .current }
            #endif
            return VoiceMemoFile(
                name: url.lastPathComponent,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                isDownloaded: downloaded,
                fileNumber: fileNumber(url)
            )
        }
    }

    /// The inode, which a rename keeps and an atomic replace does not. The
    /// resource identifier key is no use here: Apple documents it as not
    /// persistent across restarts, and the ledger outlives them.
    package static func fileNumber(_ url: URL) -> UInt64? {
        let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber]
        return (number as? NSNumber)?.uint64Value
    }

    /// Asks iCloud to bring a placeholder's bytes to this Mac; a later scan
    /// picks the file up once they are here.
    package static func requestDownload(_ url: URL) {
        #if canImport(Darwin)
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            Log.backends.error("Voice memos: download request failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Moves a transcribed memo out of iCloud Drive into the Trash, where it
    /// can still be restored.
    package static func removeTranscribed(_ url: URL) throws {
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }
}

/// Which memo files have been handled, so each becomes one capture even
/// across a quit, a failed move to the Trash or a rename (#925, #1508).
/// Keyed by the recording's identity (`key(for:)`): its inode, else its name.
package struct VoiceMemoLedger: Codable, Equatable, Sendable {
    /// 2 keys entries by identity (#1508); 1 keyed them by file name.
    package static let currentVersion = 2

    package enum State: Codable, Equatable, Sendable {
        /// Handed to the engine as this Inbox item. A quit before the item
        /// was saved retries the file; after, the file is done.
        case transcribing(itemID: UUID)
        case captured(itemID: UUID)
        /// The engine heard no words. Left in the folder for the user.
        case noSpeech
        /// Not audio this Mac can decode. Left in the folder for the user.
        case unreadable
    }

    package struct Entry: Codable, Equatable, Sendable {
        /// The name the file had when last seen.
        package var name: String
        /// Nil in entries read from format 1 until a scan matches them by name.
        package var fileNumber: UInt64?
        package var size: Int
        /// Absent in entries written before #1098.
        package var modifiedAt: Date?
        package var state: State

        package init(name: String, fileNumber: UInt64? = nil, size: Int, modifiedAt: Date? = nil, state: State) {
            self.name = name
            self.fileNumber = fileNumber
            self.size = size
            self.modifiedAt = modifiedAt
            self.state = state
        }

        package init(_ file: VoiceMemoFile, state: State) {
            self.init(name: file.name, fileNumber: file.fileNumber, size: file.size, modifiedAt: file.modifiedAt, state: state)
        }

        /// Whether `file` is the file this entry was written for: a memo
        /// replaced in iCloud may keep its name and size, not its date.
        package func describes(_ file: VoiceMemoFile) -> Bool {
            size == file.size && (modifiedAt == nil || modifiedAt == file.modifiedAt)
        }
    }

    /// Format 1's entry, keyed by file name.
    private struct EntryV1: Decodable {
        var size: Int
        var modifiedAt: Date?
        var state: State
    }

    package var entries: [String: Entry] = [:]

    package init() {}

    private enum CodingKeys: String, CodingKey { case version, entries }

    /// Reads format 1 as entries keyed by name (`key(forName:)`), which the
    /// next scan rekeys to each file's identity (`adopt`).
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        if version < 2 {
            let old = try container.decodeIfPresent([String: EntryV1].self, forKey: .entries) ?? [:]
            entries = Dictionary(uniqueKeysWithValues: old.map { name, entry in
                (Self.key(forName: name),
                 Entry(name: name, size: entry.size, modifiedAt: entry.modifiedAt, state: entry.state))
            })
        } else {
            entries = try container.decode([String: Entry].self, forKey: .entries)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(entries, forKey: .entries)
    }

    package static func key(for file: VoiceMemoFile) -> String {
        file.fileNumber.map { "inode:\($0)" } ?? key(forName: file.name)
    }

    package static func key(forName name: String) -> String { "name:\(name)" }

    package func entry(for file: VoiceMemoFile) -> Entry? { entries[Self.key(for: file)] }

    /// Rekeys each listed file's entry to its current key before `prune`,
    /// and returns the keys of entries whose file was renamed.
    ///
    /// An entry keyed by the file's identity follows a rename. One keyed
    /// otherwise moves over when its name, size and date match: a format-1
    /// entry, or a file whose inode changed when iCloud downloaded it again.
    /// An entry still keyed by another listed file's inode stays with it.
    @discardableResult
    package mutating func adopt(_ files: [VoiceMemoFile]) -> Set<String> {
        let listedKeys = Set(files.map(Self.key(for:)))
        var renamed: Set<String> = []
        for file in files {
            let key = Self.key(for: file)
            if var entry = entries[key] {
                if entry.name != file.name {
                    entry.name = file.name
                    entries[key] = entry
                    renamed.insert(key)
                }
                continue
            }
            guard let (oldKey, entry) = entries.first(where: { oldKey, entry in
                !listedKeys.contains(oldKey) && entry.name == file.name && entry.describes(file)
            }) else { continue }
            entries[oldKey] = nil
            var moved = entry
            moved.fileNumber = file.fileNumber
            entries[key] = moved
        }
        return renamed
    }

    /// Whether `file` still needs a capture: new, or a different file saved
    /// under a handled one's name, or interrupted before its item was saved.
    package func needsCapture(_ file: VoiceMemoFile, inboxHas: (UUID) -> Bool) -> Bool {
        guard let entry = entry(for: file), entry.describes(file) else { return true }
        if case .transcribing(let id) = entry.state { return !inboxHas(id) }
        return false
    }

    /// Forgets files that left the folder, so a later memo may reuse a name.
    package mutating func prune(keeping keys: Set<String>) {
        entries = entries.filter { keys.contains($0.key) }
    }

    /// An unreadable or future ledger is refused and left in place (#989):
    /// read as empty, every memo still in the folder would become a second
    /// capture.
    package static func load(from url: URL) -> StoredFileLoad<VoiceMemoLedger> {
        StoredFile.load(VoiceMemoLedger.self, from: url, currentVersion: currentVersion)
    }

    package func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(encoder.encode(self), to: url)
    }
}
