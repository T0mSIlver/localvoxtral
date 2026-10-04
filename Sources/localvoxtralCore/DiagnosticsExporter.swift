import Foundation

/// Local-first diagnostics export. Produces a single readable text report of
/// the app's runtime configuration and managed-backend state so the owner can
/// debug field issues fast — without any phone-home telemetry.
///
/// Privacy is the core product promise, so the exporter is built so secrets
/// can never enter the output:
/// - `DiagnosticsSnapshot` only carries non-secret value fields. API keys are
///   reduced to booleans ("is one set?") at snapshot-build time and the key
///   values are never copied into the snapshot.
/// - Endpoints are scrubbed of embedded credentials (userinfo/query/fragment).
/// - Dictated content / transcript stores are never read here.
package struct DiagnosticsSnapshot: Sendable, Equatable {
    package var appVersion: String
    package var appBuild: String
    package var bundleIdentifier: String
    package var osVersion: String
    package var dictationBackendMode: String
    package var polishingBackendMode: String
    package var realtimeEndpoint: String
    package var realtimeModel: String
    package var hasRealtimeAPIKey: Bool
    package var polishingSummary: String
    package var hasPolishingAPIKey: Bool
    package var speechdStatus: String
    package var polishdStatus: String
    package var speechdRecentOutput: [String]
    package var polishdRecentOutput: [String]

    package init(
        appVersion: String,
        appBuild: String,
        bundleIdentifier: String,
        osVersion: String,
        dictationBackendMode: String,
        polishingBackendMode: String,
        realtimeEndpoint: String,
        realtimeModel: String,
        hasRealtimeAPIKey: Bool,
        polishingSummary: String,
        hasPolishingAPIKey: Bool,
        speechdStatus: String,
        polishdStatus: String,
        speechdRecentOutput: [String],
        polishdRecentOutput: [String]
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.osVersion = osVersion
        self.dictationBackendMode = dictationBackendMode
        self.polishingBackendMode = polishingBackendMode
        self.realtimeEndpoint = realtimeEndpoint
        self.realtimeModel = realtimeModel
        self.hasRealtimeAPIKey = hasRealtimeAPIKey
        self.polishingSummary = polishingSummary
        self.hasPolishingAPIKey = hasPolishingAPIKey
        self.speechdStatus = speechdStatus
        self.polishdStatus = polishdStatus
        self.speechdRecentOutput = speechdRecentOutput
        self.polishdRecentOutput = polishdRecentOutput
    }
}

package enum DiagnosticsExporter {
    /// Filename prefix + format for the on-disk report. Timestamp is colons-free
    /// so it is safe in filenames on all filesystems.
    package static let filenamePrefix = "localvoxtral-diagnostics-"
    package static let filenameSuffix = ".txt"

    // Formatters are created per-call (not as `static let`) because DateFormatter
    // is non-Sendable and Swift 6.2 strict concurrency forbids shared static
    // mutable-ish state. A diagnostics export runs rarely, so this is cheap.

    private static func makeFilenameFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    private static func makeHeaderFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    // MARK: - Report rendering (pure)

    /// Renders the snapshot as a single readable text report. `now` is an
    /// injected clock seam (no `Date()` here) so tests are deterministic.
    package static func makeReport(snapshot: DiagnosticsSnapshot, now: Date) -> String {
        var lines: [String] = []
        let headerFormatter = makeHeaderFormatter()
        lines.append("localvoxtral diagnostics")
        lines.append("generated: \(headerFormatter.string(from: now))")
        lines.append("This file was generated locally and is never uploaded anywhere.")
        lines.append("Review it before sharing — backend process output below is verbatim.")
        lines.append("")

        lines.append("== App ==")
        lines.append("version: \(snapshot.appVersion) (build \(snapshot.appBuild))")
        lines.append("bundle id: \(snapshot.bundleIdentifier)")
        lines.append("")

        lines.append("== OS ==")
        lines.append(snapshot.osVersion)
        lines.append("")

        lines.append("== Backend configuration ==")
        lines.append("dictation mode: \(snapshot.dictationBackendMode)")
        lines.append("polishing mode: \(snapshot.polishingBackendMode)")
        lines.append("realtime endpoint: \(snapshot.realtimeEndpoint)")
        lines.append("realtime model: \(snapshot.realtimeModel)")
        lines.append("realtime API key: \(snapshot.hasRealtimeAPIKey ? "set" : "not set")")
        lines.append("LLM polishing: \(snapshot.polishingSummary)")
        lines.append("LLM polishing API key: \(snapshot.hasPolishingAPIKey ? "set" : "not set")")
        lines.append("")

        lines.append("== Managed backend status ==")
        lines.append("dictation engine (localvoxtral-speechd): \(snapshot.speechdStatus)")
        lines.append("polishing engine (localvoxtral-polishd): \(snapshot.polishdStatus)")
        lines.append("")

        lines.append("== Managed backend recent output ==")
        if snapshot.speechdRecentOutput.isEmpty && snapshot.polishdRecentOutput.isEmpty {
            lines.append("(no supervisor output captured)")
        } else {
            if !snapshot.speechdRecentOutput.isEmpty {
                lines.append("-- localvoxtral-speechd --")
                lines.append(contentsOf: snapshot.speechdRecentOutput)
            }
            if !snapshot.polishdRecentOutput.isEmpty {
                lines.append("-- localvoxtral-polishd --")
                lines.append(contentsOf: snapshot.polishdRecentOutput)
            }
        }

        lines.append("")
        lines.append("== end of diagnostics ==")
        return lines.joined(separator: "\n")
    }

    // MARK: - File writing (injectable destination + clock)

    /// Writes the report to `directory` as
    /// `localvoxtral-diagnostics-<timestamp>.txt`, where `<timestamp>` is
    /// derived from the injected `now`. Returns the written file URL.
    @discardableResult
    package static func writeReport(
        snapshot: DiagnosticsSnapshot,
        to directory: URL,
        now: Date
    ) throws -> URL {
        let filenameFormatter = makeFilenameFormatter()
        let stem = "\(filenamePrefix)\(filenameFormatter.string(from: now))"
        // Second-precision timestamps can collide on rapid re-export; never
        // silently overwrite an earlier report.
        var destination = directory.appendingPathComponent(stem + filenameSuffix)
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path), attempt <= 100 {
            destination = directory.appendingPathComponent("\(stem)-\(attempt)\(filenameSuffix)")
            attempt += 1
        }
        let report = makeReport(snapshot: snapshot, now: now)
        // `atomic: true` so a partial write never leaves a misleading file.
        try report.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    // MARK: - Helpers

    /// Returns a credential-free description of an endpoint URL. Userinfo,
    /// query, and fragment are stripped so embedded tokens can never leak.
    package static func sanitizedEndpointDescription(from url: URL?) -> String {
        guard let url else { return "<invalid endpoint>" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    /// Human-readable, single-line description of a managed-backend status.
    package static func describe(_ status: ManagedBackendStatus) -> String {
        switch status {
        case .preparingModel(let progress):
            return "preparing model (\(describe(progress)))"
        case .pausedModelDownload(let progress):
            return "model download paused (\(describe(progress)))"
        case .starting:
            return "starting"
        case .ready:
            return "ready"
        case .stopped:
            return "stopped"
        case .failed(let summary, let detail):
            // Unlike the popover (one short sentence only), the diagnostics
            // report is the place for the full failure story.
            if let detail {
                return "failed: \(summary) — \(detail)"
            }
            return "failed: \(summary)"
        }
    }

    private static func describe(_ progress: ModelDownloadProgress) -> String {
        if let fraction = progress.fraction {
            return String(format: "downloading %.0f%%", fraction * 100)
        }
        if let totalBytes = progress.totalBytes {
            return "downloading \(progress.downloadedBytes) of \(totalBytes) bytes"
        }
        return "downloading"
    }
}
