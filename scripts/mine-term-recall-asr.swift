#!/usr/bin/env swift
// Mac-side ASR-corruption miner for the PRIVATE term-recall eval set.
//
// Input:  EvalRecordings/term-recall/cases.json   (from
//         scripts/harvest-term-recall-cases.py, run on the Linux box; the
//         file is transcript-derived and gitignored — see /EvalRecordings/
//         in the root .gitignore).
//
// For every case it:
//   1. synthesizes the sentence with /usr/bin/say using the agent-dictation
//      eval harness's exact TTS conventions — same cache directory
//      (~/Library/Caches/localvoxtral-eval/wav), same LEI16@16000 data
//      format, and the same length-prefixed SHA-256 cache key
//      (AgentDictationE2EEvalSupport.wavCacheKey), so WAVs are shared with
//      the E2E eval and reruns are pure cache hits;
//   2. transcribes it against live voxmlx over the realtime websocket
//      protocol the production client speaks (session.update ->
//      input_audio_buffer.append -> final input_audio_buffer.commit ->
//      transcription.done); finals are joined directly, mirroring the E2E
//      harness;
//   3. keeps cases where a target term got corrupted, with a word-aligned
//      best-effort (intended, heard) pair per corrupted term.
//
// Output (both under EvalRecordings/term-recall/, private):
//   mined.jsonl          — one record per case, appended IMMEDIATELY after
//                          each case completes (resumable, the ablation-tool
//                          convention); reruns skip unchanged cases.
//   asr-corruptions.json — only the corrupted cases:
//                          {id, spoken_text, asr_text,
//                           corrupted_terms: [{intended, heard}]}
//
// Stdout ends with a sentinel-delimited report (harness convention, distinct
// sentinel name so ablate-agent-eval.py can never mistake it for an E2E
// inspection report):
//   === TERM-RECALL-MINING-REPORT-BEGIN ===
//   {header}\n{record}\n...
//   === TERM-RECALL-MINING-REPORT-END ===
//
// Run via scripts/mine-term-recall-asr.sh (warms voxmlx through
// scripts/mac/lv-test-servers.sh ensure, like run-agent-eval-local.sh).

import CryptoKit
import Foundation

// MARK: - CLI

struct Options {
    var casesPath = "EvalRecordings/term-recall/cases.json"
    var minedPath = "EvalRecordings/term-recall/mined.jsonl"
    var corruptionsPath = "EvalRecordings/term-recall/asr-corruptions.json"
    var endpoint = "ws://127.0.0.1:8000/v1/realtime"
    var model = "mistralai/Voxtral-Mini-4B-Realtime-2602"
    var voice: String?  // nil = system default voice, keyed as "default"
    var limit: Int?
    var caseIDs: [String] = []
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else {
            FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
            exit(2)
        }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--cases": o.casesPath = value(a)
        case "--out": o.minedPath = value(a)
        case "--corruptions": o.corruptionsPath = value(a)
        case "--endpoint": o.endpoint = value(a)
        case "--model": o.model = value(a)
        case "--voice": o.voice = value(a)
        case "--limit": o.limit = Int(value(a))
        case "--case": o.caseIDs.append(value(a))
        case "-h", "--help":
            print(
                """
                usage: mine-term-recall-asr.swift [--cases PATH] [--out PATH]
                    [--corruptions PATH] [--endpoint WS_URL] [--model NAME]
                    [--voice NAME] [--limit N] [--case ID]...
                """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(a)\n".utf8))
            exit(2)
        }
    }
    return o
}

// MARK: - Case input

struct HarvestCase: Decodable {
    let id: String
    let text: String
    let targetTerms: [String]

    enum CodingKeys: String, CodingKey {
        case id, text
        case targetTerms = "target_terms"
    }
}

struct HarvestFile: Decodable {
    let cases: [HarvestCase]
}

// MARK: - TTS (harness conventions: cache dir, data format, cache key)

let ttsDataFormat = "LEI16@16000"

/// Identical to AgentDictationE2EEvalSupport.wavCacheKey: SHA-256 over
/// length-prefixed (text, voice ?? "default", dataFormat). Length prefixes
/// (UInt64 little-endian byte counts) prevent separator-join collisions.
func wavCacheKey(text: String, voice: String?, dataFormat: String = ttsDataFormat) -> String {
    var hasher = SHA256()
    for field in [text, voice ?? "default", dataFormat] {
        let bytes = Data(field.utf8)
        withUnsafeBytes(of: UInt64(bytes.count).littleEndian) {
            hasher.update(bufferPointer: $0)
        }
        hasher.update(data: bytes)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

struct MiningError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func synthesizedWAV(text: String, voice: String?) throws -> URL {
    let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/localvoxtral-eval/wav", isDirectory: true)
    try FileManager.default.createDirectory(
        at: cacheDirectory, withIntermediateDirectories: true)
    let key = wavCacheKey(text: text, voice: voice)
    let wavURL = cacheDirectory.appendingPathComponent("\(key).wav")
    if FileManager.default.fileExists(atPath: wavURL.path) {
        // A corrupt cached file must not poison the cache (harness rule).
        if let pcm = try? pcm16Data(fromWAVAt: wavURL), !pcm.isEmpty {
            return wavURL
        }
        try? FileManager.default.removeItem(at: wavURL)
    }
    // Temp name then move, so a crash mid-`say` never leaves a half-written
    // file under the final key (harness rule).
    let temporary = cacheDirectory.appendingPathComponent("tmp-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: temporary) }
    var arguments = [
        "-o", temporary.path,
        "--file-format=WAVE",
        "--data-format=\(ttsDataFormat)",
    ]
    if let voice { arguments += ["-v", voice] }
    arguments.append(text)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw MiningError("say failed (status \(process.terminationStatus))")
    }
    try FileManager.default.moveItem(at: temporary, to: wavURL)
    return wavURL
}

/// Minimal RIFF/WAVE reader: returns the raw bytes of the `data` chunk.
func pcm16Data(fromWAVAt url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    guard data.count > 44,
        data.prefix(4) == Data("RIFF".utf8),
        data.subdata(in: 8..<12) == Data("WAVE".utf8)
    else { throw MiningError("not a RIFF/WAVE file: \(url.path)") }
    var offset = 12
    while offset + 8 <= data.count {
        let chunkID = data.subdata(in: offset..<offset + 4)
        let sizeBytes = data.subdata(in: offset + 4..<offset + 8)
        let size = sizeBytes.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        if chunkID == Data("data".utf8) {
            let end = min(offset + 8 + size, data.count)
            return data.subdata(in: offset + 8..<end)
        }
        offset += 8 + size + (size % 2)
    }
    throw MiningError("no data chunk in \(url.path)")
}

// MARK: - Realtime ASR (the protocol the production client speaks)

final class RealtimeTranscriber: NSObject, URLSessionWebSocketDelegate {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var finals: [String] = []
    private var lastError: String?
    private let sessionCreated = DispatchSemaphore(value: 0)
    private let finalized = DispatchSemaphore(value: 0)

    init(endpoint: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: endpoint)
        super.init()
    }

    func transcribe(pcm16: Data, model: String, timeout: TimeInterval) throws -> String {
        task.resume()
        receiveLoop()
        // voxmlx sends session.created on connect; the production client then
        // sends session.update with the model name.
        guard sessionCreated.wait(timeout: .now() + 15) == .success else {
            throw MiningError("timed out waiting for session.created")
        }
        try send(json: ["type": "session.update", "model": model])
        // Stream in 1 s chunks (32000 bytes of 16 kHz mono PCM16).
        let chunkSize = 32000
        var offset = 0
        while offset < pcm16.count {
            let end = min(offset + chunkSize, pcm16.count)
            try send(json: [
                "type": "input_audio_buffer.append",
                "audio": pcm16.subdata(in: offset..<end).base64EncodedString(),
            ])
            offset = end
        }
        try send(json: ["type": "input_audio_buffer.commit", "final": true])
        guard finalized.wait(timeout: .now() + timeout) == .success else {
            throw MiningError("timed out waiting for transcription.done")
        }
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
        lock.lock()
        defer { lock.unlock() }
        if let lastError { throw MiningError("realtime error: \(lastError)") }
        // Finals joined directly — mirrors the E2E harness (no live-session
        // overlap merge in the loop).
        return finals.joined(separator: " ")
    }

    private func send(json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MiningError("could not encode websocket frame")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        task.send(.string(text)) { error in
            sendError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let sendError { throw sendError }
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.lock()
                self.lastError = self.lastError ?? "\(error)"
                self.lock.unlock()
                self.sessionCreated.signal()
                self.finalized.signal()
            case .success(let message):
                if case .string(let text) = message,
                    let data = text.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    self.handle(json: json)
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        switch type {
        case "session.created":
            sessionCreated.signal()
        case "transcription.done",
            "response.audio_transcript.done",
            "conversation.item.input_audio_transcription.completed":
            if let text = firstString(in: json, keys: ["text", "transcript", "delta"]) {
                lock.lock()
                finals.append(text)
                lock.unlock()
            }
            finalized.signal()
        case "error":
            lock.lock()
            lastError = firstString(in: json, keys: ["message", "error", "detail"])
                ?? "unknown realtime error"
            lock.unlock()
            sessionCreated.signal()
            finalized.signal()
        default:
            break
        }
    }

    private func firstString(in json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String { return value }
            if let nested = json[key] as? [String: Any],
                let value = firstString(in: nested, keys: keys)
            {
                return value
            }
        }
        return nil
    }
}

// MARK: - Term corruption detection

/// Speech-level normalization: lowercase, split on every non-alphanumeric.
/// "mlx-lm" -> ["mlx","lm"]; matching tolerates ASR re-spacing/joining.
func speechTokens(_ text: String) -> [String] {
    text.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
}

func termPreserved(term: String, inASR asrTokens: [String]) -> Bool {
    let termTokens = speechTokens(term)
    guard !termTokens.isEmpty else { return true }
    // Contiguous token match.
    if asrTokens.count >= termTokens.count {
        for i in 0...(asrTokens.count - termTokens.count)
        where Array(asrTokens[i..<i + termTokens.count]) == termTokens {
            return true
        }
    }
    // Glued match ("SwiftPM" heard as "swift pm" or vice versa).
    let glued = termTokens.joined()
    if asrTokens.joined().contains(glued) { return true }
    return false
}

/// (spokenIndex, asrIndex) pairs where the tokens match EXACTLY on a minimum
/// word-level edit path. These are the reliable anchors around a corruption.
func exactAlignmentPairs(spoken: [String], asr: [String]) -> [(Int, Int)] {
    let n = spoken.count, m = asr.count
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { dp[i][0] = i }
    for j in 0...m { dp[0][j] = j }
    if n > 0 && m > 0 {
        for i in 1...n {
            for j in 1...m {
                let cost = spoken[i - 1] == asr[j - 1] ? 0 : 1
                dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
            }
        }
    }
    var pairs: [(Int, Int)] = []
    var i = n, j = m
    while i > 0 || j > 0 {
        if i > 0, j > 0, spoken[i - 1] == asr[j - 1], dp[i][j] == dp[i - 1][j - 1] {
            pairs.append((i - 1, j - 1))
            i -= 1
            j -= 1
        } else if i > 0, j > 0, dp[i][j] == dp[i - 1][j - 1] + 1 {
            i -= 1
            j -= 1
        } else if j > 0, dp[i][j] == dp[i][j - 1] + 1 {
            j -= 1
        } else {
            i -= 1
        }
    }
    return pairs
}

/// Best-effort "heard" span for a corrupted term: the ASR tokens BETWEEN the
/// nearest exactly-matched anchor words on either side of the term. Robust
/// to word splits ("worktree" heard as "work tree") and spell-outs
/// ("mlx-lm" heard as "em el ex el em"); returns "" when ASR dropped the
/// term entirely (validated by the paired Python reference in the set README
/// before porting: 8/8 span-extraction cases).
func heardSpan(term: String, spokenText: String, asrTokens: [String]) -> String {
    let spoken = speechTokens(spokenText)
    let termTokens = speechTokens(term)
    guard !termTokens.isEmpty, !spoken.isEmpty else { return "" }
    var start: Int?
    if spoken.count >= termTokens.count {
        for i in 0...(spoken.count - termTokens.count)
        where Array(spoken[i..<i + termTokens.count]) == termTokens {
            start = i
            break
        }
    }
    guard let start else { return "" }
    let end = start + termTokens.count
    let pairs = exactAlignmentPairs(spoken: spoken, asr: asrTokens)
    let left = pairs.filter { $0.0 < start }.map(\.1).max() ?? -1
    let right = pairs.filter { $0.0 >= end }.map(\.1).min() ?? asrTokens.count
    guard left + 1 <= right - 1 else { return "" }
    return asrTokens[(left + 1)...(right - 1)].joined(separator: " ")
}

// MARK: - Resumable JSONL output

func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct MinedRecord: Codable {
    let caseID: String
    let inputSHA: String  // sha256 over text|model|voice — rerun skip key
    let spokenText: String
    let asrText: String
    let corruptedTerms: [[String]]  // [intended, heard]
    let preservedTerms: [String]
    let wavCacheKey: String

    enum CodingKeys: String, CodingKey {
        case caseID = "id"
        case inputSHA = "input_sha"
        case spokenText = "spoken_text"
        case asrText = "asr_text"
        case corruptedTerms = "corrupted_terms"
        case preservedTerms = "preserved_terms"
        case wavCacheKey = "wav_cache_key"
    }
}

func loadCompleted(minedPath: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: minedPath, encoding: .utf8) else {
        return [:]
    }
    var done: [String: String] = [:]
    let decoder = JSONDecoder()
    for line in text.split(separator: "\n") {
        if let record = try? decoder.decode(MinedRecord.self, from: Data(line.utf8)) {
            done[record.caseID] = record.inputSHA
        }
    }
    return done
}

// MARK: - Main

let options = parseOptions()
guard let endpointURL = URL(string: options.endpoint) else {
    FileHandle.standardError.write(Data("bad endpoint: \(options.endpoint)\n".utf8))
    exit(2)
}
let casesData: Data
do {
    casesData = try Data(contentsOf: URL(fileURLWithPath: options.casesPath))
} catch {
    FileHandle.standardError.write(
        Data("cannot read \(options.casesPath): \(error)\nRun scripts/harvest-term-recall-cases.py on the transcript box first, then copy EvalRecordings/term-recall/ here (it is gitignored; never commit it).\n".utf8))
    exit(1)
}
let harvest: HarvestFile
do {
    harvest = try JSONDecoder().decode(HarvestFile.self, from: casesData)
} catch {
    FileHandle.standardError.write(Data("cannot decode cases: \(error)\n".utf8))
    exit(1)
}

var selected = harvest.cases
if !options.caseIDs.isEmpty {
    let wanted = Set(options.caseIDs)
    selected = selected.filter { wanted.contains($0.id) }
}
if let limit = options.limit { selected = Array(selected.prefix(limit)) }

let completed = loadCompleted(minedPath: options.minedPath)
if !FileManager.default.fileExists(atPath: options.minedPath) {
    // createFile OVERWRITES an existing file — guard it, or a rerun would
    // truncate the resumable journal and lose prior records.
    FileManager.default.createFile(atPath: options.minedPath, contents: nil)
}
let minedHandle: FileHandle
do {
    minedHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: options.minedPath))
    try minedHandle.seekToEnd()
} catch {
    FileHandle.standardError.write(Data("cannot open \(options.minedPath): \(error)\n".utf8))
    exit(1)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

var run = 0
var skipped = 0
var failures = 0
var corruptedRecords: [MinedRecord] = []
var allRecords: [MinedRecord] = []

for (index, harvestCase) in selected.enumerated() {
    let inputSHA = sha256Hex(
        "\(harvestCase.text)|\(options.model)|\(options.voice ?? "default")")
    if completed[harvestCase.id] == inputSHA {
        skipped += 1
        continue
    }
    print("[\(index + 1)/\(selected.count)] \(harvestCase.id): \(harvestCase.text.prefix(70))")
    do {
        let wavURL = try synthesizedWAV(text: harvestCase.text, voice: options.voice)
        let pcm = try pcm16Data(fromWAVAt: wavURL)
        let transcriber = RealtimeTranscriber(endpoint: endpointURL)
        let asrText = try transcriber.transcribe(
            pcm16: pcm, model: options.model, timeout: 120)
        let asrTokens = speechTokens(asrText)
        var corrupted: [[String]] = []
        var preserved: [String] = []
        for term in harvestCase.targetTerms {
            if termPreserved(term: term, inASR: asrTokens) {
                preserved.append(term)
            } else {
                corrupted.append([
                    term,
                    heardSpan(term: term, spokenText: harvestCase.text, asrTokens: asrTokens),
                ])
            }
        }
        let record = MinedRecord(
            caseID: harvestCase.id,
            inputSHA: inputSHA,
            spokenText: harvestCase.text,
            asrText: asrText,
            corruptedTerms: corrupted,
            preservedTerms: preserved,
            wavCacheKey: wavCacheKey(text: harvestCase.text, voice: options.voice)
        )
        let line = try encoder.encode(record)
        minedHandle.write(line)
        minedHandle.write(Data("\n".utf8))
        allRecords.append(record)
        if !corrupted.isEmpty { corruptedRecords.append(record) }
        run += 1
    } catch {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL \(harvestCase.id): \(error)\n".utf8))
    }
}
try? minedHandle.close()

// Recompute the corruption summary over EVERYTHING in mined.jsonl (this run
// plus prior resumed runs), so the summary is always whole-set.
var byID: [String: MinedRecord] = [:]
if let text = try? String(contentsOfFile: options.minedPath, encoding: .utf8) {
    let decoder = JSONDecoder()
    for line in text.split(separator: "\n") {
        if let record = try? decoder.decode(MinedRecord.self, from: Data(line.utf8)) {
            byID[record.caseID] = record  // last write wins
        }
    }
}
let allCorrupted = byID.values.filter { !$0.corruptedTerms.isEmpty }
    .sorted { $0.caseID < $1.caseID }
struct CorruptionOut: Encodable {
    let id: String
    let spoken_text: String
    let asr_text: String
    let corrupted_terms: [[String]]
}
let summary = allCorrupted.map {
    CorruptionOut(
        id: $0.caseID, spoken_text: $0.spokenText, asr_text: $0.asrText,
        corrupted_terms: $0.corruptedTerms)
}
let summaryEncoder = JSONEncoder()
summaryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try summaryEncoder.encode(summary)
    .write(to: URL(fileURLWithPath: options.corruptionsPath))

// Sentinel-delimited report (harness convention; distinct sentinel name).
print("=== TERM-RECALL-MINING-REPORT-BEGIN ===")
let header: [String: Any] = [
    "schemaVersion": 1,
    "endpoint": options.endpoint,
    "model": options.model,
    "voice": options.voice ?? "default",
    "casesSelected": selected.count,
    "casesRun": run,
    "casesSkippedUpToDate": skipped,
    "failures": failures,
    "corruptedCases": allCorrupted.count,
]
if let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
    let headerText = String(data: headerData, encoding: .utf8)
{
    print(headerText)
}
for record in allCorrupted {
    if let line = try? encoder.encode(record), let text = String(data: line, encoding: .utf8) {
        print(text)
    }
}
print("=== TERM-RECALL-MINING-REPORT-END ===")
print("mined \(run) case(s), skipped \(skipped) up-to-date, \(failures) failure(s)")
print("corrupted: \(allCorrupted.count) case(s) -> \(options.corruptionsPath)")
if failures > 0 { exit(1) }
