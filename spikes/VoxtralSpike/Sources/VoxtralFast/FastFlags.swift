import Foundation
import MLX
import MLXNN

/// Each optimization is individually switchable so a single run can bisect which one
/// breaks correctness (the first A/B produced word-accuracy 0.000 with all three on,
/// while the stock engine scored 0.804 on the same audio in the same run).
///
/// Default ON; set the env var to "0" to fall back to the upstream behavior.
public enum FastFlags {
    static let fusedRoPE = ProcessInfo.processInfo.environment["VOXFAST_ROPE"] != "0"
    static let asyncDecode = ProcessInfo.processInfo.environment["VOXFAST_ASYNC"] != "0"
    static let maskDtype = ProcessInfo.processInfo.environment["VOXFAST_MASK"] != "0"
    /// Tied-embedding LM head via `asLinear` instead of a transposed-view matmul.
    static let fusedHead = ProcessInfo.processInfo.environment["VOXFAST_HEAD"] != "0"
    /// Keep activations in the weights' dtype: cast the mel at the conv-stem seam AND
    /// force any float32 parameter to float16 at load.
    static let fp16 = ProcessInfo.processInfo.environment["VOXFAST_FP16"] != "0"
    /// Don't dump the Metal buffer pool on every chunk.
    static let keepCache = ProcessInfo.processInfo.environment["VOXFAST_KEEPCACHE"] != "0"
    /// Manual RoPE, but dtype-preserving (cast cos/sin to the activation dtype). The
    /// minimal, upstream-shaped alternative to swapping in the fused MLXFast.RoPE kernel.
    static let ropeCast = ProcessInfo.processInfo.environment["VOXFAST_ROPECAST"] != "0"

    public static var description: String {
        "rope=\(fusedRoPE ? 1 : 0) async=\(asyncDecode ? 1 : 0) mask=\(maskDtype ? 1 : 0) head=\(fusedHead ? 1 : 0) fp16=\(fp16 ? 1 : 0) keepcache=\(keepCache ? 1 : 0) ropecast=\(ropeCast ? 1 : 0)"
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
        case convStem, encoder, decodeTokens, decoderForward, logits, headProbe
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
    nonisolated(unsafe) public private(set) static var probes = 0
    static func countProbe() { if enabled { probes += 1 } }
    static func countStep() { if enabled { steps += 1 } }

    public static func snapshot() -> [String: Double] {
        var out = totals
        out["tokens"] = Double(tokens)
        out["steps"] = Double(steps)
        out["probes"] = Double(probes)
        return out
    }
}

/// Micro-benchmark of the tied-embedding LM head in isolation.
///
/// Needed because MLX is LAZY: timing `logits(...)` and calling `eval` on its output
/// charges the ENTIRE decoder graph (32 layers) to the head. This times the head alone,
/// with a materialised input, both ways.
public func voxtralHeadBenchmark(dim: Int = 3072, vocab: Int = 131072, iters: Int = 50)
    -> [String: Double]
{
    let w = MLXRandom.normal([vocab, dim]).asType(.float16)
    let h = MLXRandom.normal([dim]).asType(.float16)
    MLX.eval(w, h)

    let emb = Embedding(embeddingCount: vocab, dimensions: dim)
    emb.update(parameters: ModuleParameters.unflattened([("weight", w)]))
    MLX.eval(emb)

    // transposed-view matmul (what upstream does)
    var t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iters {
        let l = MLX.matmul(h, w.transposed(1, 0))
        MLX.eval(l)
    }
    let matmulMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(iters)

    // asLinear (what voxmlx's as_linear does)
    t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iters {
        let l = emb.asLinear(h)
        MLX.eval(l)
    }
    let asLinearMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(iters)

    return ["matmul_transposed_ms": matmulMs, "as_linear_ms": asLinearMs]
}
