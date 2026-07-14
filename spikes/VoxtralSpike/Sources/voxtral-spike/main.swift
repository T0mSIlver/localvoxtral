import AVFoundation
import Foundation
import MLX
import MLXAudioSTT

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
let chunkMs = Int(arg("chunk-ms", default: "80")!)!
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

// MARK: - Run

GPU.set(cacheLimit: 4 * 1024 * 1024 * 1024)  // mirrors voxmlx's mx.metal.set_cache_limit

let samples = try loadPCM16kMono(wavPath)
let audioSeconds = Double(samples.count) / 16000.0
let expected = expectedPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""

FileHandle.standardError.write(
    "loading \(repoID) …\n".data(using: .utf8)!)
let loadStart = CFAbsoluteTimeGetCurrent()
let model = try await VoxtralRealtimeModel.fromPretrained(repoID)
let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStart

// Warm the Metal pipelines so the first measured chunk isn't paying kernel-compile
// cost. The real app warms on its first dictation the same way.
let warm = model.makeStreamSession(temperature: 0.0)
_ = warm.step(Array(samples.prefix(16000)))
_ = warm.finish()

let chunkSamples = max(1, 16000 * chunkMs / 1000)
var report: [[String: Any]] = []

for spec in delaySpecs {
    let delayMs: Int? = spec == "default" ? nil : Int(spec)
    let session = model.makeStreamSession(temperature: 0.0, transcriptionDelayMs: delayMs)

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

        let newText = session.text
        if !prevText.isEmpty && !newText.hasPrefix(prevText) {
            reemits += 1
            if reemitExamples.count < 3 {
                reemitExamples.append("was:'\(prevText.suffix(24))' now:'\(newText.suffix(24))'")
            }
        }
        if firstDeltaAfterAudioSec == nil && !delta.text.isEmpty {
            firstDeltaAfterAudioSec = Double(end) / 16000.0
        }
        prevText = newText
        idx = end
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    _ = session.finish()
    let finishMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    let computeSeconds = CFAbsoluteTimeGetCurrent() - runStart

    let text = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    ])
    FileHandle.standardError.write("  delay=\(spec) done\n".data(using: .utf8)!)
}

let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
