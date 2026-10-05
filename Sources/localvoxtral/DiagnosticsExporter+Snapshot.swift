import Foundation

extension DiagnosticsExporter {
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
        // The snapshot reports whether each key is set, so it has to have read
        // them. Export is user-initiated, which is the only moment a keychain
        // prompt for a key the user's engines do not use is fair
        // (`SettingsStore.ensureSecretsLoaded`).
        settings.ensureAllSecretsLoaded()

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
}
