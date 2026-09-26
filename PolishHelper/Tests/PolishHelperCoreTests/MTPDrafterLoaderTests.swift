import XCTest

@testable import PolishHelperCore

final class MTPDrafterLoaderTests: XCTestCase {
    private func modelDirectory(config: [String: Any]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "mtp-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try JSONSerialization.data(withJSONObject: config)
            .write(to: directory.appending(component: "config.json"))
        return directory
    }

    func testCheckpointWithoutAnMTPFileIsRefused() async throws {
        let directory = try modelDirectory(config: ["model_type": "qwen3_5"])
        do {
            _ = try await MTPDrafterLoader.load(modelDirectory: directory)
            XCTFail("expected noMTPFile")
        } catch MTPDrafterLoader.LoadError.noMTPFile {
        }
    }

    func testHeadThatWasNotDownloadedIsNamed() async throws {
        let directory = try modelDirectory(config: [
            "model_type": "qwen3_5",
            "mlx_lm_extra_tensors": ["mtp_file": "optiq/mtp.safetensors"],
        ])
        do {
            _ = try await MTPDrafterLoader.load(modelDirectory: directory)
            XCTFail("expected missingWeights")
        } catch MTPDrafterLoader.LoadError.missingWeights(let path) {
            XCTAssertEqual(path, "optiq/mtp.safetensors")
        }
    }

    func testHeadQuantizationWinsOverTheModelDefault() {
        let quantization = MTPDrafterLoader.mtpQuantization(root: [
            "quantization": ["bits": 8, "group_size": 32],
            "mtplx_mtp_quantization": ["bits": 4, "group_size": 64, "prequantized": true],
        ])
        XCTAssertEqual(quantization.bits, 4)
        XCTAssertEqual(quantization.groupSize, 64)

        let fallback = MTPDrafterLoader.mtpQuantization(root: [
            "quantization": ["bits": 8, "group_size": 32]
        ])
        XCTAssertEqual(fallback.bits, 8)
        XCTAssertEqual(fallback.groupSize, 32)
    }
}
