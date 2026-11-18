import MLX
import MLXAudioSTT
import MLXNN

/// Keeps a Voxtral session in float16 (LVX-127).
///
/// The catalog checkpoint stores its 4-bit layers' scales and biases as float16, and
/// its linear biases and norm weights as float32. The first float32 bias or norm weight
/// makes every activation after it float32, and MLX's quantized matmul then converts
/// that layer's scales and biases to float32 on each call. On an M1 Pro that made a
/// step 68 ms where 38 ms does the same work. Casting the float32 parameters once,
/// before the first session, keeps the activations float16 and changes none of the
/// 4-bit weights.
enum VoxtralParameterPrecision {
    /// Casts every float32 parameter of `model` to float16. Returns how many it cast.
    static func castToFloat16(_ model: VoxtralRealtimeModel) -> Int {
        var cast = 0
        model.apply(map: { array in
            guard array.dtype == .float32 else { return array }
            cast += 1
            return array.asType(.float16)
        })
        // Evaluated here, so the weight lock wraps the float16 buffers a session reads.
        MLX.eval(model.parameters().flattened().map { $0.1 })
        return cast
    }
}
