import Foundation
import MLX

/// Points MLX at the speech helper's own Metal kernels.
///
/// Both MLX helpers live in `Contents/MacOS` of one app, so every place MLX looks for its
/// kernels by default (`mlx.metallib` beside the binary, then `mlx-swift_Cmlx.bundle` in the
/// main bundle) is shared between them, and packaging can keep only one copy: the polishing
/// helper's. When the two helpers pin different mlx-swift versions, the speech helper then
/// runs its code against the other version's kernels; on mlx-swift 0.32.3 against 0.31.6
/// kernels, Nemotron decoded nothing but blanks (#1947). `package_app.sh` therefore ships
/// this helper's kernels under a name of their own, and this sets MLX's override path to them
/// before the first MLX call.
public enum SpeechMetalLibrary {
    public static let resourceName = "localvoxtral-speechd"

    public enum Error: Swift.Error, CustomStringConvertible {
        case missing(bundlePath: String)

        public var description: String {
            switch self {
            case .missing(let bundlePath):
                return "\(resourceName).metallib is missing from \(bundlePath)/Contents/Resources; "
                    + "the shared MLX kernels may belong to another mlx-swift version"
            }
        }
    }

    /// Call before any MLX work. Inside an app bundle the file is required: running on the
    /// shared kernels is the silent failure this exists to prevent. Outside one (a
    /// `swift build` binary in development) MLX keeps its default lookup.
    public static func useBundledKernels(bundle: Bundle = .main) throws -> String {
        guard let url = bundle.url(forResource: resourceName, withExtension: "metallib") else {
            if bundle.bundleURL.pathExtension == "app" {
                throw Error.missing(bundlePath: bundle.bundleURL.path)
            }
            return "speechd: no \(resourceName).metallib outside an app bundle; "
                + "MLX uses its default kernel lookup"
        }
        GPU.metallib = url
        return "speechd: Metal kernels from \(url.path)"
    }
}
