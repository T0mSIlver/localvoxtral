import AVFoundation
import Foundation
import MLX
import MLXAudioSTT
import VoxtralFast

// THROWAWAY SPIKE. Feeds a WAV through mlx-audio-swift's VoxtralRealtime online
// streaming session exactly the way the app feeds the mic (fixed-size 16 kHz
// mono chunks, in order, no lookahead) and reports:
//
//   * realtime headroom  — GPU compute per chunk vs the chunk's wall-clock budget
//   * accuracy           — word-level Levenshtein vs the expected phrase
//   * emission latency   — how much audio must be fed before the first text appears
//   * delta integrity    — counts steps where the transcript is NOT a prefix-extension
//                          of the previous one (the re-emit bug: our insertion path has
//                          no backspaces, so a re-emit would duplicate text on screen)
//
// It also sweeps `transcriptionDelayMs`, which the Python backend hardcodes at 480 ms.

// MARK: - Args

func arg(_ name: String, default def: String? = nil) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return def }
    return args[i + 1]
}

let repoID = arg("repo", default: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit")!
let wavPath = arg("wav")!
let expectedPath = arg("expected")
// Every fixed per-step cost (encoder pass, kernel launches, the O(n) conv-stem
// recompute, the GPU sync) is paid ONCE PER CHUNK — so chunk size is a first-class
// performance knob, not just a plumbing detail. Upstream's own CLI feeds 480 ms.
let chunkSpecs = (arg("chunks", default: arg("chunk-ms", default: "80")!)!)
    .split(separator: ",").compactMap { Int($0) }
let chunkMs = chunkSpecs.first!
// "default" = don't pass the parameter at all (whatever the model's config says).
let delaySpecs = (arg("delays", default: "default")!).split(separator: ",").map(String.init)
let label = arg("label", default: "run")!

// MARK: - Audio

/// Decode a WAV to 16 kHz mono Float — the same format the mic capture service produces.
func loadPCM16kMono(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
        let converter = AVAudioConverter(from: file.processingFormat, to: outFormat),
        let inBuf = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw NSError(domain: "spike", code: 1) }

    try file.read(into: inBuf)
    let ratio = 16000.0 / file.processingFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
        throw NSError(domain: "spike", code: 2)
    }

    var supplied = false
    var err: NSError?
    converter.convert(to: outBuf, error: &err) { _, status in
        if supplied {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return inBuf
    }
    if let err { throw err }
    guard let ch = outBuf.floatChannelData else { throw NSError(domain: "spike", code: 3) }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
}

// MARK: - Scoring (mirrors IntegrationTestSupport.wordAccuracy: word-level Levenshtein)

func words(_ s: String) -> [String] {
    s.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "'éèêàçùûôîïüö")).inverted)
        .filter { !$0.isEmpty }
}

func wordAccuracy(expected: String, actual: String) -> Double {
    let e = words(expected), a = words(actual)
    if e.isEmpty { return a.isEmpty ? 1.0 : 0.0 }
    var prev = Array(0...a.count)
    var cur = [Int](repeating: 0, count: a.count + 1)
    for i in 1...e.count {
        cur[0] = i
        for j in 1...max(a.count, 1) where a.count > 0 {
            cur[j] = min(
                prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (e[i - 1] == a[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    let distance = a.isEmpty ? e.count : prev[a.count]
    let denom = max(e.count, a.count)
    return max(0.0, 1.0 - Double(distance) / Double(denom))
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, max(0, Int((p / 100.0) * Double(s.count - 1)).advanced(by: 0)))]
}

// MARK: - Python voxmlx baseline (same audio, same chunking, same clock)

/// Streams the WAV to the running Python voxmlx server over its realtime websocket and
/// measures the same way the in-process path is measured. Both engines therefore see
/// identical GPU contention — the only fair way to compare on a machine that is also
/// running the owner's app.
func runWebSocketBaseline(url: String, samples: [Float], chunkSamples: Int, expected: String)
    async throws -> [String: Any]
{
    let task = URLSession.shared.webSocketTask(with: URL(string: url)!)
    task.resume()

    let collected = Mutex2<(deltas: [String], final: String?, firstDeltaAt: Double?)>(([], nil, nil))
    let start = CFAbsoluteTimeGetCurrent()

    // Receive loop.
    let receiver = Task {
        while !Task.isCancelled {
            let msg = try await task.receive()
            guard case .string(let s) = msg,
                let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                let type = obj["type"] as? String
            else { continue }
            if type.hasSuffix("transcript.delta"), let d = obj["delta"] as? String {
                collected.withLock {
                    if $0.firstDeltaAt == nil { $0.firstDeltaAt = CFAbsoluteTimeGetCurrent() }
                    $0.deltas.append(d)
                }
            } else if type.hasSuffix("transcript.done") {
                collected.withLock { $0.final = (obj["text"] as? String) ?? $0.final }
                return
            }
        }
    }

    func send(_ o: [String: Any]) async throws {
        let d = try JSONSerialization.data(withJSONObject: o)
        try await task.send(.string(String(data: d, encoding: .utf8)!))
    }

    try await send(["type": "session.update", "model": "voxtral-realtime"])

    let sendStart = CFAbsoluteTimeGetCurrent()
    var idx = 0
    while idx < samples.count {
        let end = min(idx + chunkSamples, samples.count)
        // PCM16 LE, exactly what MicrophoneCaptureService produces.
        var pcm = Data(capacity: (end - idx) * 2)
        for s in samples[idx..<end] {
            let v = Int16(max(-32768, min(32767, s * 32768))).littleEndian
            withUnsafeBytes(of: v) { pcm.append(contentsOf: $0) }
        }
        try await send([
            "type": "input_audio_buffer.append", "audio": pcm.base64EncodedString(),
        ])
        idx = end
    }
    try await send(["type": "input_audio_buffer.commit", "final": true])

    _ = try await withThrowingTaskGroup(of: Bool.self) { group -> Bool in
        group.addTask { _ = await receiver.result; return true }
        group.addTask {
            try await Task.sleep(for: .seconds(120))
            receiver.cancel()
            return false
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
    let totalSeconds = CFAbsoluteTimeGetCurrent() - sendStart
    task.cancel(with: .goingAway, reason: nil)

    let snap = collected.withLock { $0 }
    let text = (snap.final ?? snap.deltas.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
    let audioSeconds = Double(samples.count) / 16000.0
    return [
        "engine": "python-voxmlx(ws)",
        "audio_sec": audioSeconds,
        "compute_sec": totalSeconds,
        "rtf": totalSeconds / audioSeconds,
        "first_delta_sec": snap.firstDeltaAt.map { $0 - sendStart } ?? -1,
        "word_accuracy": expected.isEmpty ? -1 : wordAccuracy(expected: expected, actual: text),
        "transcript": text,
        "connect_overhead_sec": sendStart - start,
    ]
}

/// Minimal lock (the spike can't import the app's Mutex helpers).
final class Mutex2<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Run

// voxmlx caps its Metal cache at 4 GB; the spike takes 1 GB because it may run while
// the owner's app already holds a 4B ASR model (8471) and a 4B polish model (8472)
// resident on the same GPU.
GPU.set(cacheLimit: 1024 * 1024 * 1024)

FileHandle.standardError.write(
    "physical RAM: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB\n"
        .data(using: .utf8)!)

let samples = try loadPCM16kMono(wavPath)
let audioSeconds = Double(samples.count) / 16000.0
let expected = expectedPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""

let chunkSamplesForBaseline = max(1, 16000 * chunkMs / 1000)
var baseline: [String: Any]?
// Run the Python baseline BEFORE loading the Swift model, so the Swift 4B isn't
// resident on the GPU during its measurement (production runs one engine, not two).
if let ws = arg("ws") {
    FileHandle.standardError.write("baseline: streaming to \(ws) …\n".data(using: .utf8)!)
    do {
        baseline = try await runWebSocketBaseline(
            url: ws, samples: samples, chunkSamples: chunkSamplesForBaseline, expected: expected)
    } catch {
        baseline = ["engine": "python-voxmlx(ws)", "error": "\(error)"]
    }
}

// Numeric equivalence check for the fused RoPE against the manual one it replaces.
// Runs before any model work so a layout/convention error is caught on its own terms
// instead of showing up as a mysteriously empty transcript.
if arg("selftest") != nil {
    let diffs = voxtralRoPESelfTest()
    let worst = diffs.values.max() ?? 0
    print(
        "rope-selftest \(diffs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
    )
    print("rope-selftest worst=\(worst) verdict=\(worst < 1e-2 ? "MATCH" : "MISMATCH")")
    exit(worst < 1e-2 ? 0 : 3)
}

// One engine per process: the stock upstream engine, or the vendored+optimized one.
// Never both — two 4B models resident would distort the measurement (and may get the
// process jetsam'd while the owner's app holds two more).
let engineName = arg("engine", default: "stock")!

/// Uniform handle so both engines are measured by identical code.
struct Engine {
    let makeSession: (Int?) -> (step: ([Float]) -> String, finish: () -> String, text: () -> String)
}

FileHandle.standardError.write(
    "loading \(repoID) [engine=\(engineName)] …\n".data(using: .utf8)!)
let loadStart = CFAbsoluteTimeGetCurrent()

let engine: Engine
switch engineName {
case "fast":
    let fast = try await FastEngine(repo: repoID)
    engine = Engine(makeSession: { delay in
        let s = fast.makeSession(transcriptionDelayMs: delay)
        return (step: { s.step($0) }, finish: { s.finish() }, text: { s.text })
    })
default:
    let stock = try await MLXAudioSTT.VoxtralRealtimeModel.fromPretrained(repoID)
    engine = Engine(makeSession: { delay in
        let s = stock.makeStreamSession(temperature: 0.0, transcriptionDelayMs: delay)
        return (step: { s.step($0).text }, finish: { s.finish().text }, text: { s.text })
    })
}
let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStart

// Warm the Metal pipelines so the first measured chunk isn't paying kernel-compile cost.
let warm = engine.makeSession(nil)
_ = warm.step(Array(samples.prefix(16000)))
_ = warm.finish()

var report: [[String: Any]] = []

for (chunkMs, spec) in chunkSpecs.flatMap({ c in delaySpecs.map { (c, $0) } }) {
    let chunkSamples = max(1, 16000 * chunkMs / 1000)
    let delayMs: Int? = spec == "default" ? nil : Int(spec)
    let session = engine.makeSession(delayMs)

    var stepMs: [Double] = []
    var reemits = 0
    var reemitExamples: [String] = []
    var firstDeltaAfterAudioSec: Double?
    var prevText = ""
    var idx = 0

    let runStart = CFAbsoluteTimeGetCurrent()
    while idx < samples.count {
        let end = min(idx + chunkSamples, samples.count)
        let t0 = CFAbsoluteTimeGetCurrent()
        let delta = session.step(Array(samples[idx..<end]))
        stepMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)

        let newText = session.text()
        if !prevText.isEmpty && !newText.hasPrefix(prevText) {
            reemits += 1
            if reemitExamples.count < 3 {
                reemitExamples.append("was:'\(prevText.suffix(24))' now:'\(newText.suffix(24))'")
            }
        }
        if firstDeltaAfterAudioSec == nil && !delta.isEmpty {
            firstDeltaAfterAudioSec = Double(end) / 16000.0
        }
        prevText = newText
        idx = end
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    _ = session.finish()
    let finishMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    let computeSeconds = CFAbsoluteTimeGetCurrent() - runStart

    let text = session.text().trimmingCharacters(in: .whitespacesAndNewlines)
    let acc = expected.isEmpty ? -1 : wordAccuracy(expected: expected, actual: text)

    report.append([
        "label": label,
        "delay_ms": delayMs.map(String.init) ?? "default",
        "chunk_ms": chunkMs,
        "audio_sec": audioSeconds,
        "compute_sec": computeSeconds,
        "rtf": computeSeconds / audioSeconds,
        "step_mean_ms": stepMs.reduce(0, +) / Double(stepMs.count),
        "step_p50_ms": pct(stepMs, 50),
        "step_p95_ms": pct(stepMs, 95),
        "step_max_ms": stepMs.max() ?? 0,
        "chunk_budget_ms": Double(chunkMs),
        "finish_ms": finishMs,
        "first_delta_after_audio_sec": firstDeltaAfterAudioSec ?? -1,
        "reemits": reemits,
        "reemit_examples": reemitExamples,
        "word_accuracy": acc,
        "transcript": text,
        "peak_gpu_gb": Double(GPU.snapshot().peakMemory) / 1_073_741_824.0,
        "load_sec": loadSeconds,
        // Every 20th step: if the session re-encodes history instead of working
        // incrementally, this series climbs with position instead of staying flat.
        "step_ms_every_20": stride(from: 0, to: stepMs.count, by: 20).map {
            (Double(round(stepMs[$0] * 10)) / 10)
        },
        "engine": "swift-\(engineName)",
        "fast_flags": FastFlags.description,
        "profile_ms": FastProfile.snapshot(),
    ])
    FileHandle.standardError.write("  delay=\(spec) done\n".data(using: .utf8)!)
}

if let baseline { report.append(baseline) }

let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
