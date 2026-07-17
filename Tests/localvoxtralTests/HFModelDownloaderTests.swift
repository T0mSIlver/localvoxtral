import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

@MainActor
final class HFModelDownloaderTests: XCTestCase {
    func testDefaultCacheRootMatchesHuggingFaceEnvironmentPrecedence() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(
            HFModelDownloader.defaultCacheRoot(
                environment: ["HF_HUB_CACHE": "/custom/hub", "HF_HOME": "/ignored"],
                home: home
            ).path,
            "/custom/hub"
        )
        XCTAssertEqual(
            HFModelDownloader.defaultCacheRoot(environment: ["HF_HOME": "/custom/hf"], home: home).path,
            "/custom/hf/hub"
        )
        XCTAssertEqual(
            HFModelDownloader.defaultCacheRoot(environment: [:], home: home).path,
            "/Users/tester/.cache/huggingface/hub"
        )
    }

    func testPinnedPreparationDownloadsOnlyMatchingFilesAtExactRevision() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let pin = "0123456789abcdef0123456789abcdef01234567"
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(
                sha: pin,
                files: ["config.json", "model.safetensors", "notes.md"]
            ),
            payloads: [
                "config.json": Data("config".utf8),
                "model.safetensors": Data("weights".utf8),
            ]
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)
        var progress: [ModelDownloadProgress] = []

        try await downloader.prepare(
            ModelPreparationRequest(
                backendID: "speechd",
                displayName: "Dictation engine",
                repoID: "org/model",
                revision: pin,
                includePatterns: ["config.json", "model*.safetensors"]
            )
        ) { progress.append($0) }

        XCTAssertEqual(
            transport.repositoryInfoURLs,
            [HFModelDownloader.repositoryInfoURL(repoID: "org/model", revision: pin)]
        )
        XCTAssertEqual(Set(transport.downloadedFileNames), ["config.json", "model.safetensors"])
        XCTAssertFalse(transport.downloadedFileNames.contains("notes.md"))
        let snapshot = cache
            .appendingPathComponent("models--org--model/snapshots/\(pin)", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: snapshot.appendingPathComponent("config.json"), encoding: .utf8),
            "config"
        )
        XCTAssertEqual(
            try String(contentsOf: snapshot.appendingPathComponent("model.safetensors"), encoding: .utf8),
            "weights"
        )
        XCTAssertEqual(
            progress,
            [
                ModelDownloadProgress(downloadedBytes: 0, totalBytes: 13),
                ModelDownloadProgress(downloadedBytes: 6, totalBytes: 13),
                ModelDownloadProgress(downloadedBytes: 13, totalBytes: 13),
            ]
        )
    }

    func testUnpinnedPreparationTracksMainAndWritesResolvedRef() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let resolved = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: resolved, files: ["config.json"]),
            payloads: ["config.json": Data("{}".utf8)]
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)

        try await downloader.prepare(
            ModelPreparationRequest(
                backendID: "polishd",
                displayName: "Polishing engine",
                repoID: "org/custom",
                includePatterns: ["*.json"]
            )
        ) { _ in }

        XCTAssertEqual(
            transport.repositoryInfoURLs,
            [HFModelDownloader.repositoryInfoURL(repoID: "org/custom", revision: nil)]
        )
        let ref = cache.appendingPathComponent("models--org--custom/refs/main")
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), "\(resolved)\n")
    }

    func testPinnedPreparationRejectsResolvedRevisionMismatchBeforeDownloading() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: "moved", files: ["config.json"]),
            payloads: ["config.json": Data()]
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)

        do {
            try await downloader.prepare(
                ModelPreparationRequest(
                    backendID: "speechd",
                    displayName: "Dictation engine",
                    repoID: "org/model",
                    revision: "pinned",
                    includePatterns: ["*.json"]
                )
            ) { _ in }
            XCTFail("expected revision mismatch")
        } catch let error as ModelDownloadError {
            guard case .resolvedRevisionMismatch(let expected, let actual) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, "pinned")
            XCTAssertEqual(actual, "moved")
        }
        XCTAssertTrue(transport.downloadedFileNames.isEmpty)
    }

    func testRepositoryPathCannotEscapeSnapshotRoot() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let transport = FakeHFModelDownloadTransport(
            repositoryJSON: repositoryJSON(sha: "pin", files: ["../outside.json"]),
            payloads: ["outside.json": Data()]
        )
        let downloader = HFModelDownloader(cacheRoot: cache, transport: transport)

        do {
            try await downloader.prepare(
                ModelPreparationRequest(
                    backendID: "speechd",
                    displayName: "Dictation engine",
                    repoID: "org/model",
                    revision: "pin",
                    includePatterns: ["*.json"]
                )
            ) { _ in }
            XCTFail("expected unsafe path rejection")
        } catch let error as ModelDownloadError {
            guard case .invalidRepositoryPath(let path) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, "../outside.json")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("outside.json").path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HFModelDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryJSON(sha: String, files: [String]) -> Data {
        let siblings = files.map { ["rfilename": $0] }
        return try! JSONSerialization.data(withJSONObject: ["sha": sha, "siblings": siblings])
    }
}

private final class FakeHFModelDownloadTransport: HFModelDownloadTransport, @unchecked Sendable {
    private struct State {
        var repositoryInfoURLs: [URL] = []
        var downloadedFileNames: [String] = []
    }

    private let repositoryJSON: Data
    private let payloads: [String: Data]
    private let state = Mutex(State())

    init(repositoryJSON: Data, payloads: [String: Data]) {
        self.repositoryJSON = repositoryJSON
        self.payloads = payloads
    }

    var repositoryInfoURLs: [URL] { state.withLock { $0.repositoryInfoURLs } }
    var downloadedFileNames: [String] { state.withLock { $0.downloadedFileNames } }

    func repositoryInfo(from url: URL) async throws -> (data: Data, statusCode: Int) {
        state.withLock { $0.repositoryInfoURLs.append(url) }
        return (repositoryJSON, 200)
    }

    func contentLength(of url: URL) async throws -> Int64? {
        Int64(payloads[url.lastPathComponent]?.count ?? 0)
    }

    func download(from url: URL) async throws -> (temporaryURL: URL, statusCode: Int) {
        let fileName = url.lastPathComponent
        state.withLock { $0.downloadedFileNames.append(fileName) }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-hf-download-\(UUID().uuidString)")
        try (payloads[fileName] ?? Data()).write(to: temporary)
        return (temporary, 200)
    }
}
