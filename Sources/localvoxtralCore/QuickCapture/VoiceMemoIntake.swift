import Foundation

/// A memo's words and its audio as 16 kHz mono PCM16.
package struct VoiceMemoTranscript: Sendable {
    package let text: String
    package let pcm16: Data

    package init(text: String, pcm16: Data) {
        self.text = text
        self.pcm16 = pcm16
    }
}

/// Decodes a memo file and streams it through the speech engine.
package protocol VoiceMemoTranscribing: Sendable {
    /// Throws `VoiceMemoUnreadable` for a file no retry will fix; any other
    /// error leaves the memo for a later scan.
    func transcribe(_ url: URL) async throws -> VoiceMemoTranscript
}

package struct VoiceMemoUnreadable: Error {
    package init() {}
}

/// Turns each new file in the voice memo folder into a quick capture (#925).
///
/// A file is taken once its bytes are on this Mac and its size and date held
/// still across two scans, so a memo iCloud is still writing is never read
/// half-done. Each file becomes one capture: the ledger records the Inbox
/// item a file was handed to before the engine runs, and a file moves to
/// the Trash once its capture's words and audio are on disk. A Mac that was
/// asleep catches up on its next scan.
@MainActor
package final class VoiceMemoIntake {
    package static let scanInterval: Duration = .seconds(30)

    private let directory: URL
    private let ledgerURL: URL?
    private let transcriber: any VoiceMemoTranscribing
    private let clock: SessionClock
    private let list: @MainActor (URL) async throws -> [VoiceMemoFile]
    private let requestDownload: @MainActor (URL) -> Void
    private let removeTranscribed: @MainActor (URL) throws -> Void
    private let inboxHas: @MainActor (UUID) -> Bool
    private let capture: @MainActor (_ itemID: UUID, _ text: String, _ recordedAt: Date, _ pcm16: Data) throws -> Void

    /// False while a dictation runs: the memo waits rather than share the engine.
    package var canTranscribe: @MainActor () -> Bool = { true }
    /// Set while the Inbox refuses captures (#989): a memo taken then would
    /// be marked captured and moved to the Trash with no Inbox item.
    package var inboxProblem: @MainActor () -> StoredFileProblem? = { nil }
    /// One short sentence for the menu bar popover.
    package var onStatus: (@MainActor (String) -> Void)?
    /// The folder could not be listed; the app decides whether that means
    /// iCloud Drive access was refused.
    package var onListFailure: (@MainActor (Error) -> Void)?

    private var ledger: VoiceMemoLedger
    /// Set, the ledger could not be loaded: it is left as it is and no memo
    /// is taken, since each would be taken again (#989).
    package private(set) var ledgerProblem: StoredFileProblem?
    private var reportedLedgerProblem = false
    private var reportedInboxProblem = false
    private var lastSeen: [String: VoiceMemoFile] = [:]
    private var isScanning = false
    private var lastListFailure: String?

    package init(
        directory: URL,
        ledgerURL: URL?,
        transcriber: any VoiceMemoTranscribing,
        clock: SessionClock = .live,
        // Off the main thread: while iCloud Drive access is undecided, the
        // read waits for the user to answer the prompt.
        list: @escaping @MainActor (URL) async throws -> [VoiceMemoFile] = { url in
            try await Task.detached { try VoiceMemoFolder.list(url) }.value
        },
        requestDownload: @escaping @MainActor (URL) -> Void = VoiceMemoFolder.requestDownload,
        removeTranscribed: @escaping @MainActor (URL) throws -> Void = VoiceMemoFolder.removeTranscribed,
        inboxHas: @escaping @MainActor (UUID) -> Bool,
        /// Throws when the capture's words or audio are not on disk: the
        /// memo then stays in the folder (#988).
        capture: @escaping @MainActor (_ itemID: UUID, _ text: String, _ recordedAt: Date, _ pcm16: Data) throws -> Void
    ) {
        self.directory = directory
        self.ledgerURL = ledgerURL
        self.transcriber = transcriber
        self.clock = clock
        self.list = list
        self.requestDownload = requestDownload
        self.removeTranscribed = removeTranscribed
        self.inboxHas = inboxHas
        self.capture = capture
        let load = ledgerURL.map(VoiceMemoLedger.load(from:)) ?? .absent
        ledger = load.value ?? VoiceMemoLedger()
        ledgerProblem = load.problem
    }

    /// The popover's sentence while the Inbox is refused.
    package static let inboxRefusedStatus = "Voice memos paused: Inbox unreadable"

    /// The popover's sentence while the ledger is refused.
    package static let ledgerRefusedStatus = "Voice memos paused: list unreadable"

    /// Settings' Start Over: moves the refused ledger aside
    /// (`StoredFile.moveAside`) and starts an empty one. Every memo still in
    /// the folder becomes a capture on the next scan.
    @discardableResult
    package func moveLedgerAsideAndStartOver() throws -> URL {
        guard ledgerProblem != nil, let ledgerURL else { throw StoredFile.MoveAsideFailed() }
        let aside = try StoredFile.moveAside(ledgerURL)
        ledger = VoiceMemoLedger()
        ledgerProblem = nil
        return aside
    }

    /// Scans now and every `scanInterval` after, until the task is cancelled.
    package func run() async {
        while !Task.isCancelled {
            await scan()
            await clock.sleep(Self.scanInterval)
        }
    }

    /// One pass over the folder. Returns how many memos became captures.
    @discardableResult
    package func scan() async -> Int {
        guard !isScanning else { return 0 }
        guard ledgerProblem == nil else {
            // Once, not every 30 s.
            if !reportedLedgerProblem {
                reportedLedgerProblem = true
                Log.persistence.error("Voice memos: not scanning, the ledger could not be loaded")
                onStatus?(Self.ledgerRefusedStatus)
            }
            return 0
        }
        guard inboxProblem() == nil else {
            if !reportedInboxProblem {
                reportedInboxProblem = true
                Log.persistence.error("Voice memos: not scanning, the Inbox file could not be loaded")
                onStatus?(Self.inboxRefusedStatus)
            }
            return 0
        }
        reportedInboxProblem = false
        isScanning = true
        defer { isScanning = false }

        let files: [VoiceMemoFile]
        do {
            files = try await list(directory)
        } catch {
            // Every 30 s while the folder stays unreadable: log a change only.
            let description = error.localizedDescription
            if lastListFailure != description {
                lastListFailure = description
                Log.backends.error("Voice memos: cannot list the folder: \(description, privacy: .public)")
            }
            onListFailure?(error)
            return 0
        }
        lastListFailure = nil
        let previous = lastSeen
        lastSeen = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let before = ledger
        ledger.prune(keeping: Set(lastSeen.keys))
        if ledger != before { saveLedger() }

        var captured = 0
        for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            guard ledger.needsCapture(file, inboxHas: { inboxHas($0) }) else { continue }
            let url = directory.appendingPathComponent(file.name)
            guard file.isDownloaded else {
                requestDownload(url)
                continue
            }
            guard file.size > 0, previous[file.name] == file else { continue }
            guard canTranscribe() else { break }
            let outcome = await take(file, at: url)
            if outcome == .captured { captured += 1 }
            // The engine or the disk failed; the rest would fail the same way.
            if outcome == .stopPass { break }
        }
        return captured
    }

    private enum Outcome {
        case captured
        /// Left in the folder: unreadable or silent.
        case left
        /// Left for a later scan, and the rest of this pass waits too.
        case stopPass
    }

    private func take(_ file: VoiceMemoFile, at url: URL) async -> Outcome {
        let itemID = UUID()
        record(file, .transcribing(itemID: itemID))
        Log.backends.info("Voice memos: transcribing a \(file.size, privacy: .public)-byte memo")
        let transcript: VoiceMemoTranscript
        do {
            transcript = try await transcriber.transcribe(url)
        } catch is VoiceMemoUnreadable {
            Log.backends.error("Voice memos: a memo is not audio this Mac can decode; left in the folder")
            record(file, .unreadable)
            onStatus?("A voice memo could not be read.")
            return .left
        } catch {
            Log.backends.error("Voice memos: transcription failed, retrying on the next scan: \(String(describing: error), privacy: .public)")
            ledger.entries[file.name] = nil
            saveLedger()
            onStatus?("Voice memo waits for the speech engine.")
            return .stopPass
        }
        guard !transcript.text.isEmpty else {
            Log.backends.info("Voice memos: no words in a memo; left in the folder")
            record(file, .noSpeech)
            return .left
        }
        do {
            try capture(itemID, transcript.text, file.modifiedAt, transcript.pcm16)
        } catch {
            // The ledger keeps `.transcribing`: a relaunch retries the memo
            // unless its words reached the Inbox file meanwhile.
            Log.persistence.error("Voice memos: capture not saved, the memo stays in the folder: \(error.localizedDescription, privacy: .public)")
            onStatus?("A voice memo could not be saved.")
            return .stopPass
        }
        record(file, .captured(itemID: itemID))
        Log.backends.info("Voice memos: \(transcript.text.count, privacy: .public) chars to the inbox")
        do {
            try removeTranscribed(url)
        } catch {
            // The ledger keeps it from being captured twice.
            Log.backends.error("Voice memos: could not move a transcribed memo to the Trash: \(error.localizedDescription, privacy: .public)")
        }
        return .captured
    }

    private func record(_ file: VoiceMemoFile, _ state: VoiceMemoLedger.State) {
        ledger.entries[file.name] = VoiceMemoLedger.Entry(size: file.size, state: state)
        saveLedger()
    }

    private func saveLedger() {
        guard let ledgerURL, ledgerProblem == nil else { return }
        do {
            try ledger.save(to: ledgerURL)
        } catch {
            Log.persistence.error("Voice memos: ledger save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
