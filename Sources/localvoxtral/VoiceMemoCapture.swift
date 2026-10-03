import AppKit
import AVFoundation
import Foundation

/// A memo file as the 16 kHz mono PCM16 the speech engine and the audio
/// store take (#925).
enum VoiceMemoAudioDecoder {
    private static let readFrames: AVAudioFrameCount = 16_384

    /// Throws `VoiceMemoUnreadable` for a file that is not audio, or longer
    /// than a kept dictation may be.
    static func pcm16(from url: URL) throws -> Data {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw VoiceMemoUnreadable()
        }
        let input = file.processingFormat
        guard input.sampleRate > 0,
              Double(file.length) / input.sampleRate <= Double(DictationAudioRecording.maxSeconds),
              let output = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: Double(DictationAudioRecording.sampleRate),
                  channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: readFrames)
        else { throw VoiceMemoUnreadable() }
        // A stereo memo to the engine's mono.
        converter.downmix = true

        let outputCapacity = AVAudioFrameCount(Double(readFrames) * output.sampleRate / input.sampleRate) + 1_024
        var pcm = Data()
        var reachedEnd = false
        var readFailed = false
        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outputCapacity) else {
                throw VoiceMemoUnreadable()
            }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                // Reading at the end throws rather than returning no frames.
                if reachedEnd || file.framePosition >= file.length {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inputBuffer)
                } catch {
                    readFailed = true
                }
                if readFailed || inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error || readFailed {
                Log.backends.error(
                    "Voice memos: decoding failed (read failed: \(readFailed, privacy: .public), converter: \(conversionError?.localizedDescription ?? "-", privacy: .public))"
                )
                throw VoiceMemoUnreadable()
            }
            if outputBuffer.frameLength > 0, let samples = outputBuffer.int16ChannelData {
                pcm.append(Data(bytes: samples[0], count: Int(outputBuffer.frameLength) * 2))
            }
            if status == .endOfStream { break }
        }
        return pcm
    }
}

/// Decodes a memo and streams it through the dictation engine: the bundled
/// helper, started if it is not running, or the server or Mistral model the
/// user dictates with. A realtime socket, never a batch model.
struct VoiceMemoEngineTranscriber: VoiceMemoTranscribing {
    /// What a dictation would dial now, with its engine ready, and the
    /// server's context budget when it has one.
    let prepare: @MainActor @Sendable () async throws -> (
        RealtimeSessionConfiguration, RealtimeContextBudget?, @Sendable () -> any RealtimeClient
    )

    func transcribe(_ url: URL) async throws -> VoiceMemoTranscript {
        let pcm = try VoiceMemoAudioDecoder.pcm16(from: url)
        let (configuration, contextBudget, makeClient) = try await prepare()
        let text = try await RealtimeFileTranscriber(makeClient: makeClient)
            .transcribe(pcm16: pcm, configuration: configuration, contextBudget: contextBudget)
        return VoiceMemoTranscript(text: text, pcm16: pcm)
    }
}

/// Voice memos from the phone (#925): watches the iCloud Drive folder while
/// the setting is on, and keeps each memo's audio until its capture is filed
/// or discarded.
@MainActor
final class VoiceMemoController {
    static let refusedStatus = "iCloud Drive access refused."
    static let iCloudDriveOffStatus = "Turn on iCloud Drive for voice memos."

    private let settings: SettingsStore
    private let inbox: QuickCaptureInboxViewModel
    private let audioStore: DictationAudioStore
    private let ledgerURL: URL
    private let transcriber: any VoiceMemoTranscribing
    private let isDictationActive: @MainActor () -> Bool
    private let saveHistory: @MainActor (_ text: String, _ recordedAt: Date) -> UUID?
    private var intake: VoiceMemoIntake?
    /// Turned off with a memo in flight: kept until that memo is done.
    private var finishingIntake: VoiceMemoIntake?
    private var runTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    /// Lives as long as the app, like this controller.
    private var wakeObserver: NSObjectProtocol?
    /// One short sentence for the menu bar popover.
    var onStatus: (@MainActor (String) -> Void)?
    /// The ledger was refused, or no longer is (#989).
    var onLedgerProblem: (@MainActor (StoredFileProblem?) -> Void)?
    var isTranscribing: Bool {
        intake?.isTranscribing == true || finishingIntake?.isTranscribing == true
    }

    /// A dictation starts on the engine the memo streams through: the memo
    /// is cancelled and taken again on a later scan (#1317).
    func yieldToDictation() {
        intake?.yieldToDictation()
        finishingIntake?.yieldToDictation()
    }

    init(
        settings: SettingsStore,
        inbox: QuickCaptureInboxViewModel,
        audioStore: DictationAudioStore,
        ledgerURL: URL,
        transcriber: any VoiceMemoTranscribing,
        isDictationActive: @escaping @MainActor () -> Bool,
        saveHistory: @escaping @MainActor (_ text: String, _ recordedAt: Date) -> UUID?
    ) {
        self.settings = settings
        self.inbox = inbox
        self.audioStore = audioStore
        self.ledgerURL = ledgerURL
        self.transcriber = transcriber
        self.isDictationActive = isDictationActive
        self.saveHistory = saveHistory

        // Kept audio goes with its capture, whatever the setting says now.
        inbox.model.onDone = { [audioStore] id in audioStore.remove([id]) }
        // An Inbox that did not load may hold any of them: keep them all (#988).
        if inbox.model.storeProblem == nil {
            let removed = audioStore.removeAll(except: inbox.model.recordingIDsToKeep)
            if removed > 0 { Log.persistence.info("Voice memos: removed \(removed, privacy: .public) recordings with no capture") }
        } else {
            Log.persistence.error("Voice memos: recordings kept, the inbox file could not be loaded")
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanNow() }
        }
    }

    static func defaultAudioDirectoryURL() -> URL {
        DictationAudioStore.defaultDirectoryURL().deletingLastPathComponent()
            .appendingPathComponent("voice-memo-audio", isDirectory: true)
    }

    static func defaultLedgerURL() -> URL {
        DictationAudioStore.defaultDirectoryURL().deletingLastPathComponent()
            .appendingPathComponent("voice-memos.json")
    }

    /// Starts or stops watching to match the setting. Turning it on is the
    /// first read of iCloud Drive, so the access prompt follows that click.
    func apply() {
        guard settings.voiceMemosEnabled else {
            if intake != nil { Log.backends.info("Voice memos: off") }
            startTask?.cancel()
            startTask = nil
            if let intake, intake.isTranscribing {
                // The memo in flight finishes, whichever scan runs it (#1313).
                intake.stopAfterCurrentMemo()
                finishingIntake = intake
                intake.onTranscriptionEnded = { [weak self, weak intake] in
                    guard let self, let intake, self.finishingIntake === intake else { return }
                    self.finishingIntake = nil
                }
            } else {
                runTask?.cancel()
            }
            runTask = nil
            intake = nil
            onLedgerProblem?(nil)
            return
        }
        guard intake == nil, startTask == nil else { return }
        let folder = VoiceMemoFolder.defaultURL()
        startTask = Task { [weak self] in
            let outcome = await Task.detached { Self.prepareFolder(folder) }.value
            guard let self, !Task.isCancelled else { return }
            self.startTask = nil
            switch outcome {
            case .ready:
                self.start(folder: folder)
            case .iCloudDriveOff:
                Log.backends.error("Voice memos: iCloud Drive is off on this Mac (no \(VoiceMemoFolder.iCloudDriveURL().path, privacy: .public)); turning the setting off")
                self.turnOff(status: Self.iCloudDriveOffStatus)
            case .refused(let description):
                self.logRefusal(description)
                self.turnOff(status: Self.refusedStatus)
            }
        }
    }

    /// Settings' Start Over for a refused ledger: memos still in the folder
    /// become captures again on the next scans.
    func startOverLedger() throws {
        guard let intake else { throw StoredFile.MoveAsideFailed() }
        try intake.moveLedgerAsideAndStartOver()
        onLedgerProblem?(nil)
        scanNow()
    }

    /// Checks now, as after the Mac wakes. A memo iCloud has just brought
    /// in is taken on the scan after the one that first sees it.
    func scanNow() {
        guard let intake else { return }
        Task { await intake.scan() }
    }

    private enum FolderOutcome: Sendable {
        case ready
        case iCloudDriveOff
        case refused(String)
    }

    nonisolated private static func prepareFolder(_ folder: URL) -> FolderOutcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: VoiceMemoFolder.iCloudDriveURL().path) else { return .iCloudDriveOff }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try fileManager.contentsOfDirectory(atPath: folder.path)
            return .ready
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    private func start(folder: URL) {
        let inbox = inbox
        let audioStore = audioStore
        let saveHistory = saveHistory
        let intake = VoiceMemoIntake(
            directory: folder,
            ledgerURL: ledgerURL,
            transcriber: transcriber,
            inboxHas: { id in inbox.model.holds(id) },
            inboxIsSaved: { !inbox.model.hasUnsavedChanges },
            capture: { id, text, recordedAt, pcm in
                do {
                    try audioStore.write(pcm16: pcm, for: id)
                } catch {
                    Log.persistence.error("Voice memos: audio write failed: \(error.localizedDescription, privacy: .public)")
                    throw error
                }
                let recordID = saveHistory(text, recordedAt)
                try inbox.model.captureVoiceMemo(text: text, historyRecordID: recordID, id: id, capturedAt: recordedAt)
            }
        )
        intake.canTranscribe = { [isDictationActive] in !isDictationActive() }
        intake.inboxProblem = { inbox.model.storeProblem }
        intake.onStatus = { [weak self] in self?.onStatus?($0) }
        intake.onListFailure = { [weak self] error in
            guard let self, Self.isPermissionError(error) else { return }
            self.logRefusal(error.localizedDescription)
            self.turnOff(status: Self.refusedStatus)
        }
        self.intake = intake
        onLedgerProblem?(intake.ledgerProblem)
        runTask = Task { await intake.run() }
        Log.backends.info("Voice memos: watching iCloud Drive/\(VoiceMemoFolder.name, privacy: .public)")
    }

    private func logRefusal(_ description: String) {
        Log.backends.error(
            "Voice memos: iCloud Drive access refused (\(description, privacy: .public)); turning the setting off. Allow localvoxtral under System Settings > Privacy & Security > Files & Folders, then turn it on again"
        )
    }

    private func turnOff(status: String) {
        settings.voiceMemosEnabled = false
        apply()
        onStatus?(status)
    }

    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return posix.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(posix.code)
    }
}
