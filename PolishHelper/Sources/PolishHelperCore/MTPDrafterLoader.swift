import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// How the helper decodes. `mtp` drafts with the checkpoint's own
/// multi-token-prediction head and verifies with the model, which keeps the
/// output identical to plain greedy decoding.
public enum SpeculativeDecodingMode: String, Sendable {
    case off
    case mtp
}

/// Loads the Qwen3.5 multi-token-prediction head that OptiQ checkpoints ship
/// beside the model weights (`optiq/mtp.safetensors`, named by config.json's
/// `mtp_file`).
///
/// mlx-swift-lm's drafter factory cannot load it: it reads weights from the
/// top level of a directory only, and its Qwen3.5 text registration refuses a
/// config.json with a vision tower, which every OptiQ checkpoint has. So the
/// drafter is built from the same config.json and fed the one file through a
/// staging directory that holds nothing else.
public enum MTPDrafterLoader {
    public enum LoadError: Error, CustomStringConvertible {
        case noMTPFile
        case missingWeights(String)

        public var description: String {
            switch self {
            case .noMTPFile:
                "config.json names no mtp_file; this checkpoint has no MTP head"
            case .missingWeights(let path):
                "MTP head \(path) is not downloaded"
            }
        }
    }

    public static func load(modelDirectory: URL) async throws -> Qwen35MTPDraftModel {
        let configData = try Data(contentsOf: modelDirectory.appending(component: "config.json"))
        let root = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        let extras = root["mlx_lm_extra_tensors"] as? [String: Any]
        guard let mtpFile = root["mtp_file"] as? String ?? extras?["mtp_file"] as? String
        else {
            throw LoadError.noMTPFile
        }
        let weightsURL = modelDirectory.appending(path: mtpFile)
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw LoadError.missingWeights(mtpFile)
        }

        let configuration = try JSONDecoder.json5().decode(
            Qwen35Configuration.self, from: configData)
        // OptiQ stores the head's norms zero-centred, as upstream Qwen does,
        // so the drafter applies the +1 shift the main weights already carry.
        let drafter = Qwen35MTPDraftModel(configuration)

        let staging = FileManager.default.temporaryDirectory
            .appending(component: "polishd-mtp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createSymbolicLink(
            at: staging.appending(component: "model.safetensors"),
            withDestinationURL: weightsURL)

        try await loadWeights(
            modelDirectory: staging,
            model: drafter,
            quantization: mtpQuantization(root: root))
        return drafter
    }

    /// The head's own quantization when config.json states it (OptiQ:
    /// `mtplx_mtp_quantization`), else the model's default. Either way only
    /// layers whose weights carry `.scales` are quantized.
    static func mtpQuantization(root: [String: Any]) -> BaseConfiguration.Quantization {
        for key in ["mtplx_mtp_quantization", "quantization"] {
            if let entry = root[key] as? [String: Any],
                let bits = entry["bits"] as? Int,
                let groupSize = entry["group_size"] as? Int
            {
                return .init(groupSize: groupSize, bits: bits)
            }
        }
        return .init(groupSize: 64, bits: 4)
    }
}
