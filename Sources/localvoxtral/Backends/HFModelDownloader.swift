import Darwin
import Foundation

struct ModelDownloadProgress: Equatable, Sendable {
    var downloadedBytes: Int64
    var totalBytes: Int64?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
}

struct ModelPreparationRequest: Equatable, Sendable {
    let backendID: String
    let displayName: String
    let repoID: String
    /// Pinned commit, or nil to track the repo's `main` (custom repo ids).
    let revision: String?
    let includePatterns: [String]

    init(
        backendID: String,
        displayName: String,
        repoID: String,
        revision: String? = nil,
        includePatterns: [String]
    ) {
        self.backendID = backendID
        self.displayName = displayName
        self.repoID = repoID
        self.revision = revision
        self.includePatterns = includePatterns
    }
}

protocol ModelPreparing: Sendable {
    func prepare(
        _ request: ModelPreparationRequest,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws
}

enum ModelDownloadError: LocalizedError, Sendable {
    case repositoryRequestFailed(repoID: String, statusCode: Int)
    case resolvedRevisionMismatch(expected: String, actual: String)
    case noMatchingFiles(repoID: String)
    case invalidRepositoryPath(String)
    case fileRequestFailed(path: String, statusCode: Int)
    case transport(message: String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .repositoryRequestFailed(let repoID, let statusCode):
            return "Model repository request failed for \(repoID) (HTTP \(statusCode))."
        case .resolvedRevisionMismatch(let expected, let actual):
            return "Model revision mismatch: expected \(expected), resolved \(actual)."
        case .noMatchingFiles(let repoID):
            return "Model repository \(repoID) contains none of the required files."
        case .invalidRepositoryPath(let path):
            return "Model repository returned an unsafe file path: \(path)."
        case .fileRequestFailed(let path, let statusCode):
            return "Model file download failed for \(path) (HTTP \(statusCode))."
        case .transport(let message, _):
            return message.trimmed.isEmpty ? "Model download failed." : message
        }
    }

    var technicalDetails: String? {
        if case .transport(_, let detail) = self { return detail }
        return errorDescription
    }
}

struct HFModelRepositoryInfo: Equatable, Sendable {
    let sha: String
    let fileNames: [String]
}

protocol HFModelDownloadTransport: Sendable {
    func repositoryInfo(from url: URL) async throws -> (data: Data, statusCode: Int)
    func contentLength(of url: URL) async throws -> Int64?
    func download(from url: URL) async throws -> (temporaryURL: URL, statusCode: Int)
}

struct URLSessionHFModelDownloadTransport: HFModelDownloadTransport {
    func repositoryInfo(from url: URL) async throws -> (data: Data, statusCode: Int) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func contentLength(of url: URL) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else { return nil }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    func download(from url: URL) async throws -> (temporaryURL: URL, statusCode: Int) {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        return (temporaryURL, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct HFModelDownloader: ModelPreparing {
    private struct RepositoryResponse: Decodable {
        struct Sibling: Decodable { let rfilename: String }
        let sha: String
        let siblings: [Sibling]
    }

    private let cacheRoot: URL
    private let transport: any HFModelDownloadTransport
    private let fileManager: FileManager

    init(
        cacheRoot: URL? = nil,
        transport: any HFModelDownloadTransport = URLSessionHFModelDownloadTransport(),
        fileManager: FileManager = .default
    ) {
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot()
        self.transport = transport
        self.fileManager = fileManager
    }

    func prepare(
        _ request: ModelPreparationRequest,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws {
        do {
            let info = try await repositoryInfo(for: request)
            let wanted = info.fileNames.filter { fileName in
                request.includePatterns.contains { fnmatch($0, fileName, 0) == 0 }
            }
            guard !wanted.isEmpty else {
                throw ModelDownloadError.noMatchingFiles(repoID: request.repoID)
            }

            let snapshot = snapshotDirectory(repoID: request.repoID, revision: info.sha)
            try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
            let missing = try wanted.filter { fileName in
                let destination = try safeDestination(for: fileName, under: snapshot)
                return !fileManager.fileExists(atPath: destination.path)
            }

            var sizes: [String: Int64] = [:]
            for fileName in missing {
                try Task.checkCancellation()
                if let size = try await transport.contentLength(
                    of: Self.fileURL(repoID: request.repoID, revision: info.sha, fileName: fileName)
                ) {
                    sizes[fileName] = size
                }
            }
            let total = sizes.count == missing.count ? sizes.values.reduce(0, +) : nil
            await Self.report(ModelDownloadProgress(downloadedBytes: 0, totalBytes: total), progress)

            var downloaded: Int64 = 0
            for fileName in missing {
                try Task.checkCancellation()
                let source = Self.fileURL(
                    repoID: request.repoID,
                    revision: info.sha,
                    fileName: fileName
                )
                let result = try await transport.download(from: source)
                guard (200..<300).contains(result.statusCode) else {
                    throw ModelDownloadError.fileRequestFailed(
                        path: fileName,
                        statusCode: result.statusCode
                    )
                }
                let destination = try safeDestination(for: fileName, under: snapshot)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: result.temporaryURL, to: destination)
                downloaded += sizes[fileName] ?? fileSize(at: destination)
                await Self.report(
                    ModelDownloadProgress(downloadedBytes: downloaded, totalBytes: total),
                    progress
                )
            }

            if request.revision == nil {
                let refs = repositoryDirectory(repoID: request.repoID)
                    .appendingPathComponent("refs", isDirectory: true)
                try fileManager.createDirectory(at: refs, withIntermediateDirectories: true)
                try Data("\(info.sha)\n".utf8).write(
                    to: refs.appendingPathComponent("main"),
                    options: .atomic
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ModelDownloadError {
            throw error
        } catch {
            throw ModelDownloadError.transport(
                message: "Model download failed.",
                detail: error.localizedDescription
            )
        }
    }

    static func defaultCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            return URL(fileURLWithPath: hubCache, isDirectory: true)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome, isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }

    static func repositoryInfoURL(repoID: String, revision: String?) -> URL {
        URL(string: "https://huggingface.co/api/models/\(repoID)/revision/\(revision ?? "main")")!
    }

    static func fileURL(repoID: String, revision: String, fileName: String) -> URL {
        URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(fileName)")!
    }

    private func repositoryInfo(for request: ModelPreparationRequest) async throws -> HFModelRepositoryInfo {
        let result = try await transport.repositoryInfo(
            from: Self.repositoryInfoURL(repoID: request.repoID, revision: request.revision)
        )
        guard result.statusCode == 200 else {
            throw ModelDownloadError.repositoryRequestFailed(
                repoID: request.repoID,
                statusCode: result.statusCode
            )
        }
        let response = try JSONDecoder().decode(RepositoryResponse.self, from: result.data)
        if let revision = request.revision, response.sha != revision {
            throw ModelDownloadError.resolvedRevisionMismatch(
                expected: revision,
                actual: response.sha
            )
        }
        return HFModelRepositoryInfo(
            sha: response.sha,
            fileNames: response.siblings.map(\.rfilename)
        )
    }

    private func repositoryDirectory(repoID: String) -> URL {
        cacheRoot.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
    }

    private func snapshotDirectory(repoID: String, revision: String) -> URL {
        repositoryDirectory(repoID: repoID)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    private func safeDestination(for fileName: String, under snapshot: URL) throws -> URL {
        let root = snapshot.standardizedFileURL
        let destination = root.appendingPathComponent(fileName).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw ModelDownloadError.invalidRepositoryPath(fileName)
        }
        return destination
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    @MainActor
    private static func report(
        _ event: ModelDownloadProgress,
        _ progress: @MainActor @Sendable (ModelDownloadProgress) -> Void
    ) {
        progress(event)
    }
}

extension HFModelDownloader: @unchecked Sendable {}
