import AVFoundation
import CryptoKit
import Darwin
import Foundation

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

struct Recording: Codable {
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
    var caseID: String?
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
          --case ID           Record only one corpus case
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
        case "--case": options.caseID = try value()
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
    let devices = AVCaptureDevice.devices(for: .audio)
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

func loadManifest(at url: URL) throws -> Manifest {
    guard fileManager.fileExists(atPath: url.path) else {
        return Manifest(schemaVersion: schemaVersion, dataFormat: dataFormat, recordings: [])
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    guard manifest.schemaVersion == schemaVersion, manifest.dataFormat == dataFormat else {
        throw HarnessError.message("unsupported manifest schema or data format at \(url.path)")
    }
    return manifest
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

func isComplete(_ item: CorpusCase, entry: Recording?, directory: URL) -> Bool {
    guard let entry,
          entry.lang == item.lang,
          entry.spokenForm == item.spokenForm,
          entry.file == "\(item.id).wav"
    else { return false }
    let url = directory.appendingPathComponent(entry.file)
    guard let data = try? Data(contentsOf: url), (try? analyzeWAV(data)) != nil else {
        return false
    }
    return sha256(data) == entry.sha256
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

/// Convert only after capture has stopped. Capturing and resampling in the
/// same real-time ffmpeg graph produced audible crackles on the owner Mac,
/// while native-rate recordings from Photo Booth were clean. Keeping the
/// realtime graph to a PCM file write avoids resampler work and timestamp
/// correction on the capture thread; the finished WAV is then normalized to
/// the exact 16 kHz mono format voxmlx expects.
func normalizeCapturedTake(ffmpeg: String, source: URL, destination: URL) throws {
    try? fileManager.removeItem(at: destination)
    let process = Process()
    let errors = Pipe()
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
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        throw HarnessError.message("ffmpeg could not normalize the take: \(detail)")
    }
}

func recordTake(ffmpeg: String, device: String, temporary: URL) throws -> WAVAnalysis {
    try? fileManager.removeItem(at: temporary)
    let nativeCapture = temporary.appendingPathExtension("native.tmp.wav")
    try? fileManager.removeItem(at: nativeCapture)
    defer { try? fileManager.removeItem(at: nativeCapture) }
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-thread_queue_size", "1024",
        "-f", "avfoundation", "-i", ":\(device)",
        "-map", "0:a:0", "-c:a", "pcm_s16le", nativeCapture.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    Thread.sleep(forTimeInterval: 0.4)
    guard process.isRunning else {
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw HarnessError.message("ffmpeg could not open microphone index \(device): \(detail)")
    }
    print("● Recording — speak the phrase, then press Return to stop.")
    _ = readLine()
    process.interrupt()
    process.waitUntilExit()
    guard fileManager.fileExists(atPath: nativeCapture.path) else {
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw HarnessError.message("ffmpeg did not produce a WAV: \(detail)")
    }
    try normalizeCapturedTake(
        ffmpeg: ffmpeg, source: nativeCapture, destination: temporary
    )
    let data = try Data(contentsOf: temporary)
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
    if let caseID = options.caseID { selected = selected.filter { $0.id == caseID } }
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
    if !options.listOnly,
        !standardizedOutput.path.hasPrefix(recordingsRoot.path + "/")
    {
        throw HarnessError.message(
            "recording output must stay under \(recordingsRoot.path) so voice data remains gitignored"
        )
    }
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
    let loadedManifest = try loadManifest(at: manifestURL)
    let currentIDs = Set(allCases.map(\.id))
    var entries: [String: Recording] = [:]
    for recording in loadedManifest.recordings where currentIDs.contains(recording.id) {
        guard entries[recording.id] == nil else {
            throw HarnessError.message("duplicate recording id in manifest: \(recording.id)")
        }
        entries[recording.id] = recording
    }
    // Abandoned temporary takes never affect resume or eval.
    for file in (try? fileManager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
    where file.lastPathComponent.hasSuffix(".tmp.wav") {
        try? fileManager.removeItem(at: file)
    }

    let completeCount = allCases.filter {
        isComplete($0, entry: entries[$0.id], directory: outputDirectory)
    }.count
    print("Human agent-eval recording set: \(options.setName)")
    print("Output: \(outputDirectory.path)")
    print("Corpus speech cases: \(allCases.count); complete: \(completeCount); remaining: \(allCases.count - completeCount)")
    print("Manifest: schema \(schemaVersion), format \(dataFormat)")
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
        defer { try? fileManager.removeItem(at: temporary) }

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
                    ffmpeg: ffmpeg, device: options.device, temporary: temporary
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
                    try? fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: temporary, to: destination)
                    let data = try Data(contentsOf: destination)
                    entries[item.id] = Recording(
                        id: item.id,
                        lang: item.lang,
                        spokenForm: item.spokenForm,
                        file: destination.lastPathComponent,
                        sha256: sha256(data)
                    )
                    try writeManifest(entries, to: manifestURL)
                    print("Accepted \(item.id); progress saved.")
                    break takeLoop
                case "r": break reviewLoop
                case "p": play(temporary)
                case "s": break takeLoop
                case "q":
                    try? fileManager.removeItem(at: temporary)
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
