import Foundation

package struct ModelDownloadProgress: Equatable, Sendable {
    package var downloadedBytes: Int64
    package var totalBytes: Int64?

    package init(downloadedBytes: Int64, totalBytes: Int64?) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }

    package var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
}

package enum ManagedBackendStatus: Equatable, Sendable {
    case preparingModel(progress: ModelDownloadProgress)
    /// The user paused the model download. The bytes already transferred are
    /// kept (see `HFModelDownloadTransport.retainedResumeData`), and `progress`
    /// is the last reading before the pause so the row keeps its bar. Nothing
    /// resumes on its own: the next `ensureReady` for this backend does.
    case pausedModelDownload(progress: ModelDownloadProgress)
    case starting
    case ready
    case stopped
    case failed(summary: String, detail: String?)
}
