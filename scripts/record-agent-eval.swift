import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Synchronization

// Interactive, resumable human-audio capture for AgentDictationE2EEvalTests.
// Microphone access belongs to ffmpeg (an ordinary signed executable), not to
// this unbundled Swift script, so macOS can grant the invoking terminal access
// without requiring a throwaway app bundle and Info.plist.

struct CorpusCase: Decodable {
    let id: String
    let lang: String
    let spokenForm: String
}

struct Stratum: Decodable {
    let pipeline: String?
    let cases: [CorpusCase]
}

struct Recording: Codable, Equatable {
    let id: String
    let lang: String
    let spokenForm: String
    let file: String
    let sha256: String
}

struct Manifest: Codable {
    let schemaVersion: Int
    let dataFormat: String
    var recordings: [Recording]
}

struct Options {
    var setName = "owner"
    var output: String?
    var device = "default"
    var caseIDs: [String] = []
    var language: String?
    var redo = false
    var listOnly = false
    var listDevices = false
}

enum HarnessError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let value):
            return value
        }
    }
}

let schemaVersion = 1
let dataFormat = "pcm_s16le@16000Hz-mono"
let recoveryJournalFileName = "accepted-recordings.jsonl"
let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

func usage() -> Never {
    print(
        """
        Usage: ./scripts/record-agent-eval.sh [options]

          --set NAME          Recording-set name (default: owner)
          --output PATH       Override output directory (must remain under EvalRecordings)
          --device INDEX      AVFoundation audio index, or default (default: default)
          --list-devices      Print available microphone indexes and exit
          --case ID           Record a corpus case (repeat for a focused batch)
          --lang en|fr        Record only one language
          --redo              Include already completed matching cases
          --list              List selected pending/completed cases without recording
          -h, --help          Show this help

        Takes are written to the gitignored directory
        EvalRecordings/agent-dictation/<set>/. Playback is optional; Return
        accepts a take, while single keys replay, re-record, skip, or quit.
        Run the command again to resume.
        """
    )
    exit(0)
}

func parseOptions() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        func value() throws -> String {
            guard !args.isEmpty else { throw HarnessError.message("\(arg) needs a value") }
            return args.removeFirst()
        }
        switch arg {
        case "--set": options.setName = try value()
        case "--output": options.output = try value()
        case "--device": options.device = try value()
        case "--case": options.caseIDs.append(try value())
        case "--lang": options.language = try value()
        case "--redo": options.redo = true
        case "--list": options.listOnly = true
        case "--list-devices": options.listDevices = true
        case "-h", "--help": usage()
        default: throw HarnessError.message("unknown option: \(arg)")
        }
    }
    guard !options.setName.isEmpty,
          options.setName.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
    else { throw HarnessError.message("--set may contain only letters, numbers, dot, underscore, dash") }
    guard options.device == "default"
            || (!options.device.isEmpty && options.device.allSatisfy(\.isNumber))
    else {
        throw HarnessError.message("--device must be default or an AVFoundation audio index")
    }
    if let language = options.language, language != "en" && language != "fr" {
        throw HarnessError.message("--lang must be en or fr")
    }
    return options
}

func findExecutable(_ name: String, additional: [String] = []) -> String? {
    let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map { String($0) + "/" + name }
    return (additional + pathCandidates).first { fileManager.isExecutableFile(atPath: $0) }
}

/// Enumerate through AVFoundation directly. Invoking ffmpeg with
/// `-list_devices true` can remain alive indefinitely on some macOS/ffmpeg
/// combinations even after it prints the list; device discovery itself does
/// not require opening the microphone or starting a child process.
func listAudioDevices() {
    let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    ).devices
    print("AVFoundation audio inputs:")
    print("  [default] System default input (recommended)")
    if devices.isEmpty {
        print("  No indexed audio inputs were discovered.")
        return
    }
    for (index, device) in devices.enumerated() {
        print("  [\(index)] \(device.localizedName)")
    }
}

func loadCases() throws -> [CorpusCase] {
    let directory = repoRoot
        .appendingPathComponent("EvalCorpus/agent-dictation/strata", isDirectory: true)
    let files = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let decoder = JSONDecoder()
    var cases: [CorpusCase] = []
    for file in files {
        let stratum = try decoder.decode(Stratum.self, from: Data(contentsOf: file))
        // polish-only inputs carry written spacing artifacts and never run ASR.
        if stratum.pipeline != "polish-only" { cases.append(contentsOf: stratum.cases) }
    }
    var seen = Set<String>()
    for item in cases where !seen.insert(item.id).inserted {
        throw HarnessError.message("duplicate corpus case id: \(item.id)")
    }
    return cases
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct WAVAnalysis {
    let pcmByteCount: Int
    let peak: Double

    var duration: Double { Double(pcmByteCount) / Double(16_000 * 2) }
    var peakDBFS: Double { 20 * log10(max(peak, 1e-12)) }
}

func readLE16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

/// Mirrors AgentDictationE2EEvalSupport.recordedPCM16 closely. A take that the
/// recorder calls complete must not surprise the operator with an eval
/// preflight failure after all 146 phrases have been recorded.
func analyzeWAV(_ wav: Data) throws -> WAVAnalysis {
    guard wav.count >= 44,
          String(data: wav[0..<4], encoding: .ascii) == "RIFF",
          String(data: wav[8..<12], encoding: .ascii) == "WAVE"
    else { throw HarnessError.message("take is not a RIFF/WAVE file") }

    var format: (code: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
    var pcm: Data?
    var index = 12
    while index + 8 <= wav.count {
        let chunkID = String(data: wav[index..<(index + 4)], encoding: .ascii) ?? ""
        let size = Int(readLE32(wav, at: index + 4))
        let start = index + 8
        let end = start + size
        guard end <= wav.count else {
            throw HarnessError.message("take has a truncated WAV chunk")
        }
        if chunkID == "fmt ", size >= 16 {
            format = (
                readLE16(wav, at: start), readLE16(wav, at: start + 2),
                readLE32(wav, at: start + 4), readLE16(wav, at: start + 14)
            )
        } else if chunkID == "data" {
            pcm = wav.subdata(in: start..<end)
        }
        index = end + (size % 2)
    }
    guard let format,
          format.code == 1, format.channels == 1,
          format.rate == 16_000, format.bits == 16
    else {
        throw HarnessError.message("take must be mono 16-bit PCM at 16000 Hz")
    }
    guard let pcm, pcm.count >= 8_000, pcm.count.isMultiple(of: 2) else {
        throw HarnessError.message("take is missing or shorter than 0.25 seconds")
    }

    var peakMagnitude: Int32 = 0
    var offset = 0
    while offset < pcm.count {
        let sample = Int16(bitPattern: readLE16(pcm, at: offset))
        peakMagnitude = max(peakMagnitude, abs(Int32(sample)))
        offset += 2
    }
    guard peakMagnitude > 0 else {
        throw HarnessError.message(
            "take is digitally silent; run from a local GUI terminal and grant that "
                + "terminal app Microphone access in System Settings"
        )
    }
    return WAVAnalysis(
        pcmByteCount: pcm.count,
        peak: Double(peakMagnitude) / 32_768
    )
}

func loadManifest(at url: URL) -> Manifest {
    guard fileManager.fileExists(atPath: url.path) else {
        return Manifest(schemaVersion: schemaVersion, dataFormat: dataFormat, recordings: [])
    }
    do {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == schemaVersion, manifest.dataFormat == dataFormat else {
            throw HarnessError.message("unsupported schema or data format")
        }
        return manifest
    } catch {
        print("Warning: manifest.json is unreadable (\(error)); recovering accepted takes from the journal.")
        return Manifest(schemaVersion: schemaVersion, dataFormat: dataFormat, recordings: [])
    }
}

func writeManifest(_ entries: [String: Recording], to url: URL) throws {
    let manifest = Manifest(
        schemaVersion: schemaVersion,
        dataFormat: dataFormat,
        recordings: entries.values.sorted { $0.id < $1.id }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(manifest)
    data.append(0x0a)
    try data.write(to: url, options: .atomic)
}

/// The manifest is convenient for the eval, while this append-only journal is
/// the durable source of truth for the recorder. Each accepted take is flushed
/// here before its WAV is installed. On restart, a journal entry can recover
/// either the installed WAV or the still-pending temporary WAV.
func appendRecoveryRecord(_ recording: Recording, to url: URL) throws {
    var data = try JSONEncoder().encode(recording)
    data.append(0x0a)
    if !fileManager.fileExists(atPath: url.path) {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw HarnessError.message("could not create recovery journal at \(url.path)")
        }
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

func loadRecoveryRecords(at url: URL) -> [Recording] {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
    let decoder = JSONDecoder()
    var records: [Recording] = []
    var ignoredLines = 0
    for line in data.split(separator: 0x0a) {
        do {
            records.append(try decoder.decode(Recording.self, from: Data(line)))
        } catch {
            ignoredLines += 1
        }
    }
    if ignoredLines > 0 {
        print("Warning: ignored \(ignoredLines) incomplete recovery-journal line(s).")
    }
    return records
}

func atomicallyInstall(_ source: URL, at destination: URL) throws {
    let result = source.path.withCString { sourcePath in
        destination.path.withCString { destinationPath in
            Darwin.rename(sourcePath, destinationPath)
        }
    }
    guard result == 0 else {
        let code = errno
        throw HarnessError.message(
            "could not atomically save \(destination.lastPathComponent): "
                + String(cString: strerror(code))
        )
    }
}

func recordingMatches(_ recording: Recording, item: CorpusCase) -> Bool {
    recording.id == item.id
        && recording.lang == item.lang
        && recording.spokenForm == item.spokenForm
        && recording.file == "\(item.id).wav"
}

func dataMatches(_ recording: Recording, at url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url),
          (try? analyzeWAV(data)) != nil
    else { return false }
    return sha256(data) == recording.sha256
}

/// Recover a fully accepted entry. If the process stopped after journaling but
/// before the atomic rename, finish installing the normalized temporary WAV.
func recoverRecording(
    _ recording: Recording,
    item: CorpusCase,
    directory: URL,
    mayInstallTemporary: Bool
) -> Bool {
    guard recordingMatches(recording, item: item) else { return false }
    let destination = directory.appendingPathComponent(recording.file)
    if dataMatches(recording, at: destination) { return true }
    guard mayInstallTemporary else { return false }
    let temporary = directory.appendingPathComponent(".\(item.id).tmp.wav")
    guard dataMatches(recording, at: temporary) else { return false }
    do {
        try atomicallyInstall(temporary, at: destination)
        print("Recovered interrupted save for \(item.id).")
        return true
    } catch {
        print("Warning: could not recover \(item.id): \(error)")
        return false
    }
}

func isComplete(_ item: CorpusCase, entry: Recording?, directory: URL) -> Bool {
    guard let entry, recordingMatches(entry, item: item) else { return false }
    return dataMatches(entry, at: directory.appendingPathComponent(entry.file))
}

func play(_ url: URL) {
    guard fileManager.isExecutableFile(atPath: "/usr/bin/afplay") else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    process.arguments = [url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

func makeErrorCapture(near destination: URL) throws -> (url: URL, handle: FileHandle) {
    let url = destination.deletingLastPathComponent().appendingPathComponent(
        ".ffmpeg-errors-\(UUID().uuidString).log"
    )
    guard fileManager.createFile(atPath: url.path, contents: nil) else {
        throw HarnessError.message("could not create temporary ffmpeg error log")
    }
    return (url, try FileHandle(forWritingTo: url))
}

func readCapturedErrors(_ capture: (url: URL, handle: FileHandle)) -> String {
    try? capture.handle.close()
    guard let data = try? Data(contentsOf: capture.url) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

/// Convert only after capture has stopped. Capturing and resampling in the
/// same real-time ffmpeg graph produced audible crackles on the owner Mac,
/// while native-rate recordings from Photo Booth were clean. Keeping the
/// realtime graph to a PCM file write avoids resampler work and timestamp
/// correction on the capture thread; the finished WAV is then normalized to
/// the exact 16 kHz mono format voxmlx expects.
func normalizeCapturedTake(ffmpeg: String, source: URL, destination: URL) throws {
    try? fileManager.removeItem(at: destination)
    let process = Process()
    let errors = try makeErrorCapture(near: destination)
    defer {
        try? errors.handle.close()
        try? fileManager.removeItem(at: errors.url)
    }
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-i", source.path,
        "-map", "0:a:0",
        "-af", "aresample=16000:async=1:first_pts=0",
        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
        destination.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors.handle
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = readCapturedErrors(errors)
        throw HarnessError.message("ffmpeg could not normalize the take: \(detail)")
    }
}

func microphoneAccessGranted() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .denied, .restricted:
        return false
    case .notDetermined:
        let result = Mutex(false)
        let completed = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            result.withLock { $0 = granted }
            completed.signal()
        }
        completed.wait()
        return result.withLock { $0 }
    @unknown default:
        return false
    }
}

/// Record the system-default input with Apple's audio stack. This bypasses
/// ffmpeg's live AVFoundation demuxer, which produced mild crackling on the
/// same microphone that recorded cleanly in Photo Booth.
func recordNativeMicrophone(to destination: URL) throws {
    guard microphoneAccessGranted() else {
        throw HarnessError.message(
            "microphone access is denied; grant Terminal/iTerm access in "
                + "System Settings → Privacy & Security → Microphone"
        )
    }
    let formatProbe = AVAudioEngine()
    let hardwareFormat = formatProbe.inputNode.inputFormat(forBus: 0)
    guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
        throw HarnessError.message("the system default microphone has no enabled input format")
    }
    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: hardwareFormat.sampleRate,
        AVNumberOfChannelsKey: Int(hardwareFormat.channelCount),
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let recorder = try AVAudioRecorder(url: destination, settings: settings)
    guard recorder.prepareToRecord(), recorder.record() else {
        throw HarnessError.message("macOS could not start the system default microphone")
    }
    print(
        "● Recording natively at \(Int(hardwareFormat.sampleRate)) Hz — "
            + "speak the phrase, then press Return to stop."
    )
    _ = readLine()
    recorder.stop()
}

func recordFFmpegMicrophone(
    ffmpeg: String,
    device: String,
    destination: URL
) throws {
    try? fileManager.removeItem(at: destination)
    let process = Process()
    let errors = try makeErrorCapture(near: destination)
    defer {
        try? errors.handle.close()
        try? fileManager.removeItem(at: errors.url)
    }
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-thread_queue_size", "1024",
        "-f", "avfoundation", "-i", ":\(device)",
        "-map", "0:a:0", "-c:a", "pcm_s16le", destination.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors.handle
    try process.run()
    Thread.sleep(forTimeInterval: 0.4)
    guard process.isRunning else {
        let detail = readCapturedErrors(errors)
        throw HarnessError.message("ffmpeg could not open microphone index \(device): \(detail)")
    }
    print("● Recording — speak the phrase, then press Return to stop.")
    _ = readLine()
    process.interrupt()
    process.waitUntilExit()
    guard fileManager.fileExists(atPath: destination.path) else {
        let detail = readCapturedErrors(errors)
        throw HarnessError.message("ffmpeg did not produce an audio file: \(detail)")
    }
}

func recordTake(
    ffmpeg: String,
    device: String,
    nativeCapture: URL,
    normalized: URL
) throws -> WAVAnalysis {
    try? fileManager.removeItem(at: nativeCapture)
    try? fileManager.removeItem(at: normalized)
    if device == "default" {
        try recordNativeMicrophone(to: nativeCapture)
    } else {
        print("Note: explicit device indexes use ffmpeg capture; 'default' uses native macOS audio.")
        try recordFFmpegMicrophone(
            ffmpeg: ffmpeg, device: device, destination: nativeCapture
        )
    }
    try normalizeCapturedTake(
        ffmpeg: ffmpeg, source: nativeCapture, destination: normalized
    )
    let data = try Data(contentsOf: normalized)
    return try analyzeWAV(data)
}

do {
    let options = try parseOptions()
    if options.listDevices {
        listAudioDevices()
        exit(0)
    }
    let ffmpeg = findExecutable(
        "ffmpeg", additional: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    )

    let allCases = try loadCases()
    var selected = allCases
    if !options.caseIDs.isEmpty {
        let requested = Set(options.caseIDs)
        let known = Set(allCases.map(\.id))
        let unknown = requested.subtracting(known).sorted()
        guard unknown.isEmpty else {
            throw HarnessError.message(
                "unknown corpus case id(s): \(unknown.joined(separator: ", "))"
            )
        }
        selected = selected.filter { requested.contains($0.id) }
    }
    if let language = options.language { selected = selected.filter { $0.lang == language } }
    guard !selected.isEmpty else { throw HarnessError.message("no corpus cases match the filters") }

    let outputDirectory: URL
    if let output = options.output {
        outputDirectory = output.hasPrefix("/")
            ? URL(fileURLWithPath: output, isDirectory: true)
            : repoRoot.appendingPathComponent(output, isDirectory: true)
    } else {
        outputDirectory = repoRoot
            .appendingPathComponent("EvalRecordings/agent-dictation", isDirectory: true)
            .appendingPathComponent(options.setName, isDirectory: true)
    }
    let recordingsRoot = repoRoot
        .appendingPathComponent("EvalRecordings/agent-dictation", isDirectory: true)
        .standardizedFileURL
    let standardizedOutput = outputDirectory.standardizedFileURL
    if !standardizedOutput.path.hasPrefix(recordingsRoot.path + "/") {
        throw HarnessError.message(
            "recording output must stay under \(recordingsRoot.path) so voice data remains gitignored"
        )
    }
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
    let journalURL = outputDirectory.appendingPathComponent(recoveryJournalFileName)
    let loadedManifest = loadManifest(at: manifestURL)
    var casesByID: [String: CorpusCase] = [:]
    for item in allCases {
        guard casesByID.updateValue(item, forKey: item.id) == nil else {
            throw HarnessError.message("corpus contains duplicate case id: \(item.id)")
        }
    }
    var entries: [String: Recording] = [:]
    var manifestIDs = Set<String>()
    for recording in loadedManifest.recordings {
        guard manifestIDs.insert(recording.id).inserted else {
            print("Warning: ignored duplicate manifest entry for \(recording.id).")
            continue
        }
        guard let item = casesByID[recording.id],
              recoverRecording(
                  recording, item: item, directory: outputDirectory,
                  mayInstallTemporary: false
              )
        else { continue }
        entries[recording.id] = recording
    }
    let recoveryRecords = loadRecoveryRecords(at: journalURL)
    for recording in recoveryRecords {
        guard let item = casesByID[recording.id],
              recoverRecording(
                  recording, item: item, directory: outputDirectory,
                  mayInstallTemporary: true
              )
        else { continue }
        entries[recording.id] = recording
    }
    // One-time migration for takes created by older recorder versions. Once
    // these records are synced, manifest loss cannot hide accepted WAVs.
    for recording in entries.values.sorted(by: { $0.id < $1.id })
    where !recoveryRecords.contains(recording)
    {
        try appendRecoveryRecord(recording, to: journalURL)
    }
    try writeManifest(entries, to: manifestURL)
    // Abandoned temporary takes never affect resume or eval.
    for file in (try? fileManager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
    where file.lastPathComponent.hasSuffix(".tmp.wav")
        || file.lastPathComponent.hasSuffix(".tmp.caf")
        || (file.lastPathComponent.hasPrefix(".ffmpeg-errors-")
            && file.pathExtension == "log")
    {
        try? fileManager.removeItem(at: file)
    }

    let completeCount = allCases.filter {
        isComplete($0, entry: entries[$0.id], directory: outputDirectory)
    }.count
    print("Human agent-eval recording set: \(options.setName)")
    print("Output: \(outputDirectory.path)")
    print("Corpus speech cases: \(allCases.count); complete: \(completeCount); remaining: \(allCases.count - completeCount)")
    print("Manifest: schema \(schemaVersion), format \(dataFormat)")
    print("Recovery journal: \(entries.count) accepted take(s) protected")
    print("Microphone: AVFoundation audio input \(options.device) (use --list-devices to inspect)\n")

    if options.listOnly {
        for item in selected {
            let complete = isComplete(item, entry: entries[item.id], directory: outputDirectory)
            print("\(complete ? "DONE" : "TODO") \(item.id) [\(item.lang)] — \(item.spokenForm)")
        }
        exit(0)
    }

    guard let ffmpeg else {
        throw HarnessError.message("ffmpeg is required; install it once with: brew install ffmpeg")
    }

    for (offset, item) in selected.enumerated() {
        if !options.redo, isComplete(item, entry: entries[item.id], directory: outputDirectory) {
            continue
        }
        let destination = outputDirectory.appendingPathComponent("\(item.id).wav")
        let temporary = outputDirectory.appendingPathComponent(".\(item.id).tmp.wav")
        let nativeTemporary = outputDirectory.appendingPathComponent(
            ".\(item.id).native.tmp.caf"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        defer { try? fileManager.removeItem(at: nativeTemporary) }

        takeLoop: while true {
            print("\n[\(offset + 1)/\(selected.count)] \(item.id) [\(item.lang)]")
            print("Say exactly:\n\n  \(item.spokenForm)\n")
            print("Press Return to start, [s] skip, [q] save and quit: ", terminator: "")
            let start = (readLine() ?? "q").lowercased()
            if start == "q" { try writeManifest(entries, to: manifestURL); exit(0) }
            if start == "s" { break takeLoop }

            let analysis: WAVAnalysis
            do {
                analysis = try recordTake(
                    ffmpeg: ffmpeg, device: options.device,
                    nativeCapture: nativeTemporary, normalized: temporary
                )
            } catch {
                print("Take rejected: \(error)")
                print("Fix the input if needed, then re-record, skip, or quit.")
                continue takeLoop
            }
            print(
                "Captured \(String(format: "%.2f", analysis.duration))s; "
                    + "peak \(String(format: "%.1f", analysis.peakDBFS)) dBFS."
            )
            if analysis.peak < 0.005 {
                print("Warning: this take is extremely quiet; listen carefully before accepting.")
            }
            reviewLoop: while true {
                print("[Return] accept  [p] play  [r] re-record  [s] skip  [q] quit: ", terminator: "")
                switch (readLine() ?? "q").lowercased() {
                case "", "a":
                    let data = try Data(contentsOf: temporary)
                    let recording = Recording(
                        id: item.id,
                        lang: item.lang,
                        spokenForm: item.spokenForm,
                        file: destination.lastPathComponent,
                        sha256: sha256(data)
                    )
                    try appendRecoveryRecord(recording, to: journalURL)
                    try atomicallyInstall(temporary, at: destination)
                    entries[item.id] = recording
                    try writeManifest(entries, to: manifestURL)
                    print("Accepted \(item.id); progress saved.")
                    break takeLoop
                case "r": break reviewLoop
                case "p": play(temporary)
                case "s": break takeLoop
                case "q":
                    try? fileManager.removeItem(at: temporary)
                    try? fileManager.removeItem(at: nativeTemporary)
                    try writeManifest(entries, to: manifestURL)
                    exit(0)
                default: print("Press Return to accept, or choose p, r, s, or q.")
                }
            }
        }
    }

    try writeManifest(entries, to: manifestURL)
    let finalComplete = allCases.filter {
        isComplete($0, entry: entries[$0.id], directory: outputDirectory)
    }.count
    print("\nRecording session complete: \(finalComplete)/\(allCases.count) accepted.")
    if finalComplete == allCases.count {
        let relative = outputDirectory.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
        print("On this Mac, run the strict human baseline with:")
        print("  ./scripts/run-agent-eval-local.sh \(relative)")
    } else {
        print("Run this command again to resume.")
    }
} catch {
    FileHandle.standardError.write(Data("record-agent-eval: \(error)\n".utf8))
    exit(1)
}
