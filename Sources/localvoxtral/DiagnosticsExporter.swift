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
struct DiagnosticsSnapshot: Sendable, Equatable {
    var appVersion: String
    var appBuild: String
    var bundleIdentifier: String
    var osVersion: String
    var dictationBackendMode: String
    var polishingBackendMode: String
    var realtimeEndpoint: String
    var realtimeModel: String
    var hasRealtimeAPIKey: Bool
    var polishingSummary: String
    var hasPolishingAPIKey: Bool
    var speechdStatus: String
    var polishdStatus: String
    var speechdRecentOutput: [String]
    var polishdRecentOutput: [String]
}

enum DiagnosticsExporter {
    /// Filename prefix + format for the on-disk report. Timestamp is colons-free
    /// so it is safe in filenames on all filesystems.
    static let filenamePrefix = "localvoxtral-diagnostics-"
    static let filenameSuffix = ".txt"

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

    // MARK: - Snapshot building (reads live types; @MainActor)

    /// Builds a redacted snapshot from the live app state. This is the security
    /// boundary: it decides exactly what (non-secret) information leaves the app.
    @MainActor
    static func makeSnapshot(
        settings: SettingsStore,
        speechdStatus: ManagedBackendStatus,
        polishdStatus: ManagedBackendStatus,
        speechdRecentOutput: [String],
        polishdRecentOutput: [String],
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> DiagnosticsSnapshot {
        let info = bundle.infoDictionary
        let appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let appBuild = (info?["CFBundleVersion"] as? String) ?? "unknown"
        let bundleIdentifier = bundle.bundleIdentifier ?? "unknown"

        let realtimeEndpoint = sanitizedEndpointDescription(
            from: settings.resolvedWebSocketURL(for: settings.realtimeProvider)
        )
        let realtimeModel = settings.effectiveModelName(for: settings.realtimeProvider)

        let polishingSummary: String
        if let polishing = settings.llmPolishingConfiguration {
            // Deliberately the pre-normalization URL as the user typed it; the
            // wire request appends /v1/chat/completions to a base URL
            // (LLMPolishingService.normalizedChatCompletionsURL).
            polishingSummary = sanitizedEndpointDescription(from: polishing.endpointURL)
        } else {
            polishingSummary = "<disabled>"
        }

        return DiagnosticsSnapshot(
            appVersion: appVersion,
            appBuild: appBuild,
            bundleIdentifier: bundleIdentifier,
            osVersion: processInfo.operatingSystemVersionString,
            dictationBackendMode: settings.dictationBackendMode.displayName,
            polishingBackendMode: settings.polishingBackendMode.displayName,
            realtimeEndpoint: realtimeEndpoint,
            realtimeModel: realtimeModel,
            hasRealtimeAPIKey: !settings.apiKey.trimmed.isEmpty,
            polishingSummary: polishingSummary,
            hasPolishingAPIKey: !settings.llmPolishingAPIKey.trimmed.isEmpty,
            speechdStatus: describe(speechdStatus),
            polishdStatus: describe(polishdStatus),
            speechdRecentOutput: speechdRecentOutput,
            polishdRecentOutput: polishdRecentOutput
        )
    }

    // MARK: - Report rendering (pure)

    /// Renders the snapshot as a single readable text report. `now` is an
    /// injected clock seam (no `Date()` here) so tests are deterministic.
    static func makeReport(snapshot: DiagnosticsSnapshot, now: Date) -> String {
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
    static func writeReport(
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
    static func sanitizedEndpointDescription(from url: URL?) -> String {
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
    static func describe(_ status: ManagedBackendStatus) -> String {
        switch status {
        case .preparingModel(let progress):
            return "preparing model (\(describe(progress)))"
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
