import AppKit
import SwiftUI

struct ConnectionSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let backendManager: BackendManager
    let endpointBinding: Binding<String>
    let modelBinding: Binding<String>

    private var polishingEndpointBinding: Binding<String> {
        Binding(
            get: { settings.llmPolishingEndpointURL },
            set: { viewModel.engines.applyLLMPolishingEndpointChange($0) }
        )
    }

    private var dictationBackendModeBinding: Binding<BackendMode> {
        Binding(
            get: { settings.dictationBackendMode },
            set: { newValue in
                viewModel.engines.applyDictationBackendModeChange(newValue)
            }
        )
    }

    private var polishingBackendModeBinding: Binding<BackendMode> {
        Binding(
            get: { settings.polishingBackendMode },
            set: { newValue in
                viewModel.engines.applyPolishingBackendModeChange(newValue)
            }
        )
    }

    private var managedPolishingModelBinding: Binding<String> {
        Binding(
            get: { settings.resolvedManagedLLMPolishingModel },
            set: { viewModel.engines.applyLLMPolishingModelChange($0) }
        )
    }

    private var managedSpeechModelBinding: Binding<String> {
        Binding(
            get: { settings.resolvedManagedSpeechModel.repoID },
            set: { viewModel.engines.applyManagedSpeechModelChange($0) }
        )
    }

    private var managedSpeechModelHelp: String {
        let option = settings.resolvedManagedSpeechModel
        return SpeechModelPickerSupport.helpText(
            for: option,
            isDownloaded: ManagedModelCache.isDownloaded(
                repoID: option.repoID,
                revision: option.revision
            )
        )
    }

    private var speechdCacheLimitBinding: Binding<SpeechdCacheLimit> {
        Binding(
            get: { settings.speechdCacheLimit },
            set: { viewModel.engines.applySpeechdCacheLimitChange($0) }
        )
    }

    private var speechdStepCadenceBinding: Binding<SpeechdStepCadence> {
        Binding(
            get: { settings.speechdStepCadence },
            set: { viewModel.engines.applySpeechdStepCadenceChange($0) }
        )
    }

    private var mistralDictationModelEntries: [MistralModelPickerEntry] {
        MistralModelCatalog.pickerEntries(
            for: .dictation,
            catalog: settings.mistralModelCatalog,
            storedModel: settings.mistralDictationModel,
            defaultModel: MistralRealtimeWebSocketClient.defaultModel
        )
    }

    private var mistralPolishingModelEntries: [MistralModelPickerEntry] {
        MistralModelCatalog.pickerEntries(
            for: .polishing,
            catalog: settings.mistralModelCatalog,
            storedModel: settings.mistralPolishingModel,
            defaultModel: MistralPolishDefaults.model
        )
    }

    private var mistralDictationModelBinding: Binding<String> {
        Binding(
            get: {
                MistralModelCatalog.selectionTag(
                    storedModel: settings.mistralDictationModel,
                    catalog: settings.mistralModelCatalog,
                    defaultModel: MistralRealtimeWebSocketClient.defaultModel
                )
            },
            set: { settings.mistralDictationModel = $0 }
        )
    }

    private var mistralPolishingModelBinding: Binding<String> {
        Binding(
            get: {
                MistralModelCatalog.selectionTag(
                    storedModel: settings.mistralPolishingModel,
                    catalog: settings.mistralModelCatalog,
                    defaultModel: MistralPolishDefaults.model
                )
            },
            set: { settings.mistralPolishingModel = $0 }
        )
    }

    /// Changes when the pickers could show a different list: a new key, or an
    /// engine switched onto Mistral.
    private var mistralModelListTrigger: String {
        let usesMistral =
            settings.dictationBackendMode == .mistralAPI
            || settings.polishingBackendMode == .mistralAPI
        return usesMistral ? settings.trimmedMistralAPIKey : ""
    }

    private enum LearnMore {
        static let mistralAPI = URL(
            string:
                "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/under-the-hood.md#mistral-api"
        )!
    }

    private var managedPolishingModelEntries: [PolishModelPickerEntry] {
        PolishModelPickerSupport.entries(storedRepoID: settings.resolvedManagedLLMPolishingModel)
    }

    /// Nil when the stored repo is not one of the offered entries — the row then
    /// renders without an explanation, exactly as it did before.
    private var managedPolishingModelHelp: String? {
        guard
            let selectedEntry = managedPolishingModelEntries.first(
                where: { $0.repoID == settings.resolvedManagedLLMPolishingModel }
            )
        else { return nil }

        return PolishModelPickerSupport.helpText(
            for: selectedEntry,
            isDownloaded: ManagedModelCache.isDownloaded(
                repoID: selectedEntry.repoID,
                revision: selectedEntry.option?.revision
            )
        )
    }

    var body: some View {
        SettingsPage(tab: .endpoints) {
            SettingsGroup(title: "Dictation") {
                SettingsFieldRow(
                    title: "Mode"
                ) {
                    Picker("", selection: dictationBackendModeBinding) {
                        ForEach(BackendMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch settings.dictationBackendMode {
                case .externalURL:
                    SettingsFieldRow(title: "Server URL") {
                        TextField(settings.endpointPlaceholder, text: endpointBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(settings.modelPlaceholder, text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(
                        title: "API key",
                        status: settings.secretStoreFailureSummary,
                        statusAccessibilityIdentifier: "engines.dictation.apiKey.status"
                    ) {
                        SecureField("Required for remote providers", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }
                case .mistralAPI:
                    MistralModelPickerRow(
                        entries: mistralDictationModelEntries,
                        selection: mistralDictationModelBinding,
                        status: viewModel.engines.mistralModelListState.statusLine,
                        identifier: "engines.dictation.mistralModel"
                    )

                    SettingsFieldRow(title: "Status") {
                        MistralConfigurationStatusLabel(
                            summary: settings.mistralAPIStatusSummary,
                            isConfigured: settings.isMistralAPIConfigured
                        )
                    }
                case .managedLocal:
                    SettingsFieldRow(title: "Model") {
                        Picker("", selection: managedSpeechModelBinding) {
                            ForEach(SpeechModelCatalog.options, id: \.repoID) { option in
                                Text(option.displayName).tag(option.repoID)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityIdentifier("engines.dictation.managedModel")
                    } footer: {
                        SettingsHelpText(managedSpeechModelHelp)
                    }

                    if settings.resolvedManagedSpeechModel.showsMemoryLimit {
                        SettingsFieldRow(title: "Memory limit") {
                            Picker("", selection: speechdCacheLimitBinding) {
                                ForEach(SpeechdCacheLimit.allCases) { limit in
                                    Text(limit.displayName).tag(limit)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .accessibilityIdentifier("engines.dictation.memoryLimit")
                        }
                    }

                    SettingsFieldRow(
                        title: "Step interval"
                    ) {
                        Picker("", selection: speechdStepCadenceBinding) {
                            ForEach(SpeechdStepCadence.allCases) { cadence in
                                Text(cadence.displayName).tag(cadence)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    ManagedBackendStatusRow(
                        title: "Status",
                        status: backendManager.speechdStatus,
                        identifierPrefix: "engines.dictation",
                        onPause: { viewModel.engines.pauseManagedModelDownload(for: BackendCatalog.speechd) },
                        onResume: { viewModel.engines.resumeManagedModelDownload(for: BackendCatalog.speechd) },
                        onCancel: { viewModel.engines.cancelManagedModelDownload(for: BackendCatalog.speechd) }
                    )
                }
            }

            SettingsGroup(title: "Polishing") {
                SettingsFieldRow(
                    title: "Mode"
                ) {
                    Picker("", selection: polishingBackendModeBinding) {
                        ForEach(BackendMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch settings.polishingBackendMode {
                case .externalURL:
                    SettingsFieldRow(
                        title: "Server URL"
                    ) {
                        TextField(
                            "http://127.0.0.1:8080",
                            text: polishingEndpointBinding
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(
                        title: "API key",
                        status: settings.secretStoreFailureSummary,
                        statusAccessibilityIdentifier: "engines.polishing.apiKey.status"
                    ) {
                        SecureField(
                            "Required for remote providers",
                            text: $settings.llmPolishingAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(
                            "mlx-community/Qwen3.5-4B-OptiQ-4bit",
                            text: $settings.llmPolishingModel
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: SettingsLayout.textFieldWidth)
                    }
                case .mistralAPI:
                    MistralModelPickerRow(
                        entries: mistralPolishingModelEntries,
                        selection: mistralPolishingModelBinding,
                        status: viewModel.engines.mistralModelListState.statusLine,
                        identifier: "engines.polishing.mistralModel"
                    )

                    SettingsFieldRow(title: "Status") {
                        MistralConfigurationStatusLabel(
                            summary: settings.mistralAPIStatusSummary,
                            isConfigured: settings.isMistralAPIConfigured
                        )
                    }
                case .managedLocal:
                    SettingsFieldRow(title: "Model") {
                        Picker("", selection: managedPolishingModelBinding) {
                            ForEach(managedPolishingModelEntries) { entry in
                                Text(entry.label).tag(entry.repoID)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    } footer: {
                        if let managedPolishingModelHelp {
                            SettingsHelpText(managedPolishingModelHelp)
                        }
                    }

                    ManagedBackendStatusRow(
                        title: "Status",
                        status: backendManager.polishdStatus,
                        identifierPrefix: "engines.polishing",
                        onPause: { viewModel.engines.pauseManagedModelDownload(for: BackendCatalog.polishd) },
                        onResume: { viewModel.engines.resumeManagedModelDownload(for: BackendCatalog.polishd) },
                        onCancel: { viewModel.engines.cancelManagedModelDownload(for: BackendCatalog.polishd) }
                    )
                }
            }

            // Always present, and its content never changes with a mode: this
            // is the provider ACCOUNT, not one engine's configuration. Both
            // pickers above can point at it, one, or neither.
            SettingsGroup(title: "Mistral API", learnMoreURL: LearnMore.mistralAPI) {
                SettingsFieldRow(
                    title: "API key",
                    status: settings.secretStoreFailureSummary,
                    statusAccessibilityIdentifier: "engines.mistral.apiKey.status"
                ) {
                    SecureField(
                        "Paste a key from console.mistral.ai",
                        text: $settings.mistralAPIKey
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: SettingsLayout.textFieldWidth)
                    .accessibilityIdentifier("engines.mistral.apiKey")
                }

                SettingsFieldRow(
                    title: "Verify",
                    status: viewModel.engines.mistralAPIKeyCheckState.statusLine,
                    statusAccessibilityIdentifier: "engines.mistral.verify.status"
                ) {
                    Button("Check key") { viewModel.engines.checkMistralAPIKey() }
                        .disabled(
                            !settings.isMistralAPIConfigured
                                || viewModel.engines.mistralAPIKeyCheckState.isChecking
                        )
                        .accessibilityIdentifier("engines.mistral.verify")
                }

                SettingsFieldRow(title: "Quick setup") {
                    Button("Use Mistral for dictation and polishing") {
                        viewModel.engines.applyMistralQuickSetup(apiKey: settings.mistralAPIKey)
                    }
                    .disabled(!settings.isMistralAPIConfigured)
                    .accessibilityIdentifier("engines.mistral.quickSetup")
                }

                MistralUsageRow(viewModel: viewModel)
            }
        }
        .task(id: mistralModelListTrigger) {
            guard !mistralModelListTrigger.isEmpty else { return }
            viewModel.engines.refreshMistralModelCatalog()
        }
    }
}

/// What the Mistral requests made from this Mac cost over a chosen window,
/// estimated from list prices in the local ledger.
private struct MistralUsageRow: View {
    let viewModel: DictationViewModel
    @AppStorage("mistralUsagePeriod") private var periodRawValue =
        MistralUsagePeriod.thirtyDays.rawValue

    private var period: Binding<MistralUsagePeriod> {
        Binding(
            get: { MistralUsagePeriod(rawValue: periodRawValue) ?? .thirtyDays },
            set: { periodRawValue = $0.rawValue }
        )
    }

    private var summary: MistralUsageSummary {
        // Read so a ledger write re-renders the row.
        _ = viewModel.engines.mistralUsageRevision
        return viewModel.engines.mistralUsageLedger?.summary(for: period.wrappedValue)
            ?? MistralUsageSummary()
    }

    var body: some View {
        let summary = summary
        SettingsFieldRow(
            title: "Usage",
            status: summary.line,
            statusAccessibilityIdentifier: "engines.mistral.usage.status"
        ) {
            Picker("", selection: period) {
                ForEach(MistralUsagePeriod.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("engines.mistral.usage.period")
        } footer: {
            if let note = summary.unpricedNote {
                SettingsHelpText(note)
            }
        }
    }
}

/// A Mistral engine's model menu: the default first, then Mistral's own
/// models, then partner models under their maker's name.
private struct MistralModelPickerRow: View {
    let entries: [MistralModelPickerEntry]
    let selection: Binding<String>
    let status: String?
    let identifier: String

    var body: some View {
        SettingsFieldRow(
            title: "Model",
            status: status,
            statusAccessibilityIdentifier: "\(identifier).status"
        ) {
            Picker("", selection: selection) {
                ForEach(MistralModelCatalog.Section.allCases, id: \.self) { section in
                    let rows = entries.filter { $0.section == section }
                    if !rows.isEmpty {
                        Section(section.rawValue) {
                            ForEach(rows) { entry in
                                Text(entry.label).tag(entry.tag)
                            }
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(identifier)
            // Capped so a long model name cannot squeeze the label, and
            // trailing like every other menu in the pane: the cap's frame
            // centres its content otherwise.
            .frame(maxWidth: SettingsLayout.textFieldWidth, alignment: .trailing)
        }
    }
}

/// The Mistral engines' one-line readiness. Dimmed while unconfigured, so the
/// pane reads at a glance without a second colour vocabulary beside the managed
/// engines' status light.
private struct MistralConfigurationStatusLabel: View {
    let summary: String
    let isConfigured: Bool

    var body: some View {
        Text(summary)
            .font(.caption)
            .foregroundStyle(isConfigured ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
    }
}

/// A managed engine's readiness, plus the controls for the model download it
/// starts on its own. `identifierPrefix` namespaces those controls per engine
/// ("engines.dictation" / "engines.polishing"); the rest of the row is
/// identical for both.
struct ManagedBackendStatusRow: View {
    let title: String
    let status: ManagedBackendStatus
    let identifierPrefix: String
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        SettingsFieldRow(title: title) {
            HStack(spacing: 8) {
                ManagedBackendStatusLabel(status: status)
                ManagedBackendDownloadControls(
                    status: status,
                    identifierPrefix: identifierPrefix,
                    onPause: onPause,
                    onResume: onResume,
                    onCancel: onCancel
                )
            }
        }
    }
}

/// Pause/Resume/Cancel for the automatic model download. Present only while
/// there is a download to act on, so a ready or failed engine's row looks
/// exactly as it did before.
private struct ManagedBackendDownloadControls: View {
    let status: ManagedBackendStatus
    let identifierPrefix: String
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch status {
        case .preparingModel:
            button("Pause", identifier: "\(identifierPrefix).download.pause", action: onPause)
            button("Cancel", identifier: "\(identifierPrefix).download.cancel", action: onCancel)
        case .pausedModelDownload:
            button("Resume", identifier: "\(identifierPrefix).download.resume", action: onResume)
            button("Cancel", identifier: "\(identifierPrefix).download.cancel", action: onCancel)
        case .starting, .ready, .stopped, .failed:
            EmptyView()
        }
    }

    private func button(
        _ title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(identifier)
    }
}

struct ManagedBackendStatusLabel: View {
    let status: ManagedBackendStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            // Determinate progress renders as a 54pt linear bar; the
            // indeterminate case is a circular spinner, which must NOT get
            // the bar's fixed width (it centers inside it, reading as a big
            // blob of horizontal padding next to the caption text).
            // A paused download keeps its bar — the bytes are still there and
            // resuming continues from them — but never the spinner, which would
            // claim movement that has stopped.
            switch status {
            case .preparingModel(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 54)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            case .pausedModelDownload(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 54)
                }
            case .starting, .ready, .stopped, .failed:
                EmptyView()
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch status {
        case .preparingModel(let progress):
            return modelDownloadText(progress)
        case .pausedModelDownload(let progress):
            guard let totalBytes = progress.totalBytes, totalBytes > 0 else {
                return "Paused"
            }
            let downloaded = min(progress.downloadedBytes, totalBytes)
            return "Paused, \(Self.byteText(downloaded)) of \(Self.byteText(totalBytes))"
        case .starting:
            return "Starting"
        case .ready:
            return "Ready"
        case .stopped:
            return "Stopped"
        case .failed(let summary, _):
            return "Failed. \(summary)"
        }
    }

    private var statusColor: Color {
        switch status {
        case .ready:
            return .green
        case .preparingModel, .starting:
            return .orange
        case .failed:
            return .red
        // Paused reads as inactive, like stopped: orange is this pane's
        // "something is running" colour and nothing is.
        case .stopped, .pausedModelDownload:
            return .secondary
        }
    }

    private func modelDownloadText(_ progress: ModelDownloadProgress) -> String {
        guard let totalBytes = progress.totalBytes, totalBytes > 0 else {
            // Bytes moving but no total (CDN sent no length for some file):
            // show movement rather than pretending we are still checking.
            if progress.downloadedBytes > 0 {
                return "Downloading model, \(Self.byteText(progress.downloadedBytes))"
            }
            // No total yet: the downloader is still resolving what (if
            // anything) needs fetching — on a warm cache this phase is all
            // the user ever sees, so don't claim a download is happening.
            return "Checking model..."
        }
        // Clamp: the downloader's aggregate can transiently disagree with the
        // dry-run total (retries, resumed partials); never render > 100%.
        let downloaded = min(progress.downloadedBytes, totalBytes)
        return "Downloading model, \(Self.byteText(downloaded)) of \(Self.byteText(totalBytes))"
    }

    private static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
