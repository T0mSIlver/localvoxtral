import Foundation

/// One audio file in the voice memo folder, as a scan sees it (#925).
package struct VoiceMemoFile: Equatable, Sendable {
    package let name: String
    package let size: Int
    package let modifiedAt: Date
    /// False while iCloud holds the bytes and this Mac has only the name.
    package let isDownloaded: Bool

    package init(name: String, size: Int, modifiedAt: Date, isDownloaded: Bool = true) {
        self.name = name
        self.size = size
        self.modifiedAt = modifiedAt
        self.isDownloaded = isDownloaded
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
                isDownloaded: downloaded
            )
        }
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
/// across a quit or a failed move to the Trash (#925). Keyed by file name.
package struct VoiceMemoLedger: Codable, Equatable, Sendable {
    package static let currentVersion = 1

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
        package var size: Int
        /// Absent in entries written before #1098.
        package var modifiedAt: Date?
        package var state: State

        /// Whether `file` is the file this entry was written for: a memo
        /// replaced in iCloud may keep its name and size, not its date.
        package func describes(_ file: VoiceMemoFile) -> Bool {
            size == file.size && (modifiedAt == nil || modifiedAt == file.modifiedAt)
        }
    }

    package var version = VoiceMemoLedger.currentVersion
    package var entries: [String: Entry] = [:]

    package init() {}

    /// Whether `file` still needs a capture: new, or a different file saved
    /// under a handled one's name, or interrupted before its item was saved.
    package func needsCapture(_ file: VoiceMemoFile, inboxHas: (UUID) -> Bool) -> Bool {
        guard let entry = entries[file.name], entry.describes(file) else { return true }
        if case .transcribing(let id) = entry.state { return !inboxHas(id) }
        return false
    }

    /// Forgets files that left the folder, so a later memo may reuse a name.
    package mutating func prune(keeping names: Set<String>) {
        entries = entries.filter { names.contains($0.key) }
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
