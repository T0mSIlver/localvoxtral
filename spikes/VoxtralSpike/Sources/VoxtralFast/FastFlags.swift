import Foundation
import MLX

/// Each optimization is individually switchable so a single run can bisect which one
/// breaks correctness (the first A/B produced word-accuracy 0.000 with all three on,
/// while the stock engine scored 0.804 on the same audio in the same run).
///
/// Default ON; set the env var to "0" to fall back to the upstream behavior.
public enum FastFlags {
    static let fusedRoPE = ProcessInfo.processInfo.environment["VOXFAST_ROPE"] != "0"
    static let asyncDecode = ProcessInfo.processInfo.environment["VOXFAST_ASYNC"] != "0"
    static let maskDtype = ProcessInfo.processInfo.environment["VOXFAST_MASK"] != "0"

    public static var description: String {
        "rope=\(fusedRoPE ? 1 : 0) async=\(asyncDecode ? 1 : 0) mask=\(maskDtype ? 1 : 0)"
    }
}

/// Numeric equivalence check: the fused RoPE must reproduce the manual one it replaces.
/// Returns the max absolute deviation across a few (seqLen, offset) shapes — anything
/// above ~1e-2 in fp16 means the layout or the rotation convention is wrong.
public func voxtralRoPESelfTest() -> [String: Float] {
    var results: [String: Float] = [:]
    let nHeads = 4
    let headDim = 128
    let theta: Float = 10000.0

    for (seqLen, offset) in [(1, 0), (1, 37), (8, 0), (8, 129)] {
        let x = MLXRandom.normal([seqLen, nHeads * headDim]).asType(.float16)
        let positions = MLXArray(offset..<(offset + seqLen)).asType(.int32)

        let (cos, sin) = voxtralComputeRopeFrequencies(
            positions: positions, headDim: headDim, theta: theta)
        let manual = voxtralApplyInterleavedRoPE(
            x, cos: cos, sin: sin, nHeads: nHeads, headDim: headDim)
        let fused = voxtralFusedRoPE(
            x, nHeads: nHeads, headDim: headDim, theta: theta, offset: offset)

        let diff = MLX.abs(manual.asType(.float32) - fused.asType(.float32)).max()
        MLX.eval(diff)
        results["L\(seqLen)_off\(offset)"] = diff.item(Float.self)
    }
    return results
}

/// Phase profiler. The three "obvious" optimizations bought only ~4%, which means the
/// ~130 ms/step is somewhere else entirely — so measure it instead of theorising.
/// MLX is lazy, so each phase `eval`s its own output to attribute GPU time honestly
/// (this perturbs the total slightly; it is a diagnostic, not a benchmark).
public enum FastProfile {
    public enum Phase: String, CaseIterable, Sendable {
        case convStem, encoder, decodeTokens, logits
    }

    public static let enabled = ProcessInfo.processInfo.environment["VOXFAST_PROFILE"] == "1"

    nonisolated(unsafe) private static var totals: [String: Double] = [:]
    nonisolated(unsafe) public private(set) static var tokens = 0
    nonisolated(unsafe) public private(set) static var steps = 0

    static func time<T>(_ phase: Phase, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = body()
        totals[phase.rawValue, default: 0] += (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return r
    }

    static func countToken() { if enabled { tokens += 1 } }
    static func countStep() { if enabled { steps += 1 } }

    public static func snapshot() -> [String: Double] {
        var out = totals
        out["tokens"] = Double(tokens)
        out["steps"] = Double(steps)
        return out
    }
}
