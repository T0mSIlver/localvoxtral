import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    var viewModel: DictationViewModel
    var backendManager: BackendManager
    @State private var shortcutValidationError: String?

    private var endpointBinding: Binding<String> {
        Binding(
            get: {
                settings.endpointURL(for: settings.realtimeProvider)
            },
            set: { newValue in
                settings.realtimeAPIEndpointURL = newValue
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                settings.modelName(for: settings.realtimeProvider)
            },
            set: { newValue in
                settings.realtimeAPIModelName = newValue
            }
        )
    }

    private var dictationShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: {
                settings.dictationShortcut
            },
            set: { newValue in
                viewModel.updateDictationShortcut(newValue)
            }
        )
    }

    private var overlayBufferShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.overlayBufferShortcut },
            set: { newValue in
                viewModel.updateOverlayBufferShortcut(newValue)
            }
        )
    }

    private var livePasteShortcutBinding: Binding<DictationShortcut?> {
        Binding(
            get: { settings.livePasteShortcut },
            set: { newValue in
                viewModel.updateLivePasteShortcut(newValue)
            }
        )
    }

    var body: some View {
        TabView {
            ConnectionSettingsPane(
                settings: settings,
                viewModel: viewModel,
                backendManager: backendManager,
                endpointBinding: endpointBinding,
                modelBinding: modelBinding
            )
            .tabItem {
                Label("Endpoints", systemImage: "network")
            }

            DictationSettingsPane(
                settings: settings,
                viewModel: viewModel,
                dictationShortcutBinding: dictationShortcutBinding,
                overlayBufferShortcutBinding: overlayBufferShortcutBinding,
                livePasteShortcutBinding: livePasteShortcutBinding,
                shortcutValidationError: $shortcutValidationError
            )
            .tabItem {
                Label("Dictation", systemImage: "mic")
            }

            TextProcessingSettingsPane(
                settings: settings,
                viewModel: viewModel
            )
            .tabItem {
                Label("Text Processing", systemImage: "text.badge.checkmark")
            }

            AboutSettingsPane(viewModel: viewModel)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum SettingsLayout {
    static let pageSpacing: CGFloat = 16
    static let pagePadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 10
    static let cardSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 14
    static let labelWidth: CGFloat = 128
    static let cornerRadius: CGFloat = 18
}

private struct ConnectionSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let backendManager: BackendManager
    let endpointBinding: Binding<String>
    let modelBinding: Binding<String>

    private var dictationBackendModeBinding: Binding<BackendMode> {
        Binding(
            get: { settings.dictationBackendMode },
            set: { newValue in
                viewModel.applyDictationBackendModeChange(newValue)
            }
        )
    }

    private var polishingBackendModeBinding: Binding<BackendMode> {
        Binding(
            get: { settings.polishingBackendMode },
            set: { newValue in
                viewModel.applyPolishingBackendModeChange(newValue)
            }
        )
    }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Dictation") {
                SettingsFieldRow(title: "Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: dictationBackendModeBinding) {
                            ForEach(BackendMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsHelpText(settings.dictationBackendMode.dictationDescription)
                    }
                }

                switch settings.dictationBackendMode {
                case .externalURL:
                    SettingsFieldRow(title: "Endpoint") {
                        TextField(settings.endpointPlaceholder, text: endpointBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(settings.modelPlaceholder, text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField("Required for remote providers", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                case .managedLocal:
                    ManagedBackendStatusRow(
                        title: "Status",
                        spec: BackendCatalog.voxmlx,
                        endpoint: ManagedBackendEndpoints.realtimeURLString,
                        status: backendManager.voxmlxStatus
                    )
                }
            }

            SettingsGroup(title: "Polishing") {
                SettingsFieldRow(title: "Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: polishingBackendModeBinding) {
                            ForEach(BackendMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsHelpText(settings.polishingBackendMode.polishingDescription)
                    }
                }

                switch settings.polishingBackendMode {
                case .externalURL:
                    SettingsFieldRow(title: "Endpoint") {
                        TextField(
                            "http://127.0.0.1:8080/v1/chat/completions",
                            text: $settings.llmPolishingEndpointURL
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "API key") {
                        SecureField(
                            "Required for remote providers",
                            text: $settings.llmPolishingAPIKey
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    SettingsFieldRow(title: "Model") {
                        TextField(
                            "mlx-community/Qwen3.5-0.8B-8bit",
                            text: $settings.llmPolishingModel
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                case .managedLocal:
                    ManagedBackendStatusRow(
                        title: "Status",
                        spec: BackendCatalog.mlxLM,
                        endpoint: ManagedBackendEndpoints.polishingURLString,
                        status: backendManager.mlxLMStatus
                    )
                }

                if settings.polishingBackendMode == .managedLocal, !settings.llmPolishingEnabled {
                    SettingsHelpText(
                        "LLM polishing is disabled - enable it in the Text Processing tab to start this backend."
                    )
                } else {
                    SettingsHelpText("Used only while LLM polishing is enabled (Text Processing tab).")
                }
            }
        }
    }
}

private struct ManagedBackendStatusRow: View {
    let title: String
    let spec: ManagedBackendSpec
    let endpoint: String
    let status: ManagedBackendStatus

    var body: some View {
        SettingsFieldRow(title: title) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(spec.displayName) - \(endpoint)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))

                ManagedBackendStatusLabel(status: status)
            }
        }
    }
}

private struct ManagedBackendStatusLabel: View {
    let status: ManagedBackendStatus

    var body: some View {
        HStack(spacing: 8) {
            if case .installing(let progress) = status {
                if let fraction = installFraction(from: progress) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 54)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 54)
                }
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch status {
        case .notInstalled:
            return "Not installed"
        case .installing(let progress):
            return installingText(progress)
        case .starting:
            return "Starting"
        case .ready:
            return "Ready"
        case .stopped:
            return "Stopped"
        case .failed(let summary, _):
            return "Failed: \(summary)"
        }
    }

    private var statusColor: Color {
        if case .failed = status {
            return .red
        }
        return .secondary
    }

    private func installFraction(from progress: BackendInstallProgress) -> Double? {
        guard case .downloading(let fraction) = progress else { return nil }
        return fraction
    }

    private func installingText(_ progress: BackendInstallProgress) -> String {
        switch progress {
        case .downloading(let fraction):
            guard let fraction else { return "Downloading" }
            return "Downloading \(Int((fraction * 100).rounded()))%"
        case .verifying:
            return "Verifying"
        case .installing(let logLine):
            return logLine.trimmed.isEmpty ? "Installing" : "Installing: \(logLine)"
        case .finished:
            return "Installed"
        }
    }
}

private struct DictationSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let dictationShortcutBinding: Binding<DictationShortcut?>
    let overlayBufferShortcutBinding: Binding<DictationShortcut?>
    let livePasteShortcutBinding: Binding<DictationShortcut?>
    @Binding var shortcutValidationError: String?
    @State private var overlayValidationError: String?
    @State private var livePasteValidationError: String?

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Start dictation with") {
                SettingsFieldRow(title: "Trigger") {
                    Picker("", selection: Binding(
                        get: { settings.modifierOnlyHotKeyEnabled },
                        set: { newValue in
                            settings.modifierOnlyHotKeyEnabled = newValue
                            viewModel.applyHotKeySettingsChange()
                        }
                    )) {
                        Text("Single modifier key").tag(true)
                        Text("Keyboard shortcuts").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if settings.modifierOnlyHotKeyEnabled {
                    SettingsFieldRow(title: "Modifier key") {
                        Picker("", selection: Binding(
                            get: { settings.modifierOnlyHotKeyModifier },
                            set: { newValue in
                                settings.modifierOnlyHotKeyModifier = newValue
                                viewModel.applyHotKeySettingsChange()
                            }
                        )) {
                            ForEach(ModifierOnlyHotKeyManager.ModifierKey.allCases) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    SettingsFieldRow(title: "Tap") {
                        Text("Overlay Buffer — toggle dictation on and off.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    SettingsFieldRow(title: "Hold") {
                        Text("Live Auto-Paste — talk while held, stops on release.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    SettingsFieldRow(title: "Hold delay") {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { settings.modifierOnlyHoldDelay },
                                    set: { newValue in
                                        settings.modifierOnlyHoldDelay = newValue
                                        viewModel.applyHotKeySettingsChange()
                                    }
                                ),
                                in: 0.1...0.8,
                                step: 0.05
                            )
                            Text("\(Int(settings.modifierOnlyHoldDelay * 1000))ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                } else {
                    SettingsFieldRow(title: "Overlay Buffer") {
                        HStack(alignment: .center, spacing: 8) {
                            ShortcutRecorderField(
                                shortcut: overlayBufferShortcutBinding,
                                validationError: $overlayValidationError,
                                fixedWidth: 132
                            )
                            .frame(height: 24, alignment: .leading)

                            Button("Reset") {
                                overlayValidationError = nil
                                viewModel.updateOverlayBufferShortcut(
                                    SettingsStore.defaultDictationShortcut)
                            }
                            .disabled(
                                settings.overlayBufferShortcut == SettingsStore.defaultDictationShortcut)
                        }
                    }

                    if let overlayValidationError {
                        SettingsMessageRow(overlayValidationError, color: .red)
                    }

                    if settings.overlayBufferShortcut == nil {
                        SettingsMessageRow(
                            "Overlay Buffer shortcut is currently disabled.",
                            color: .secondary
                        )
                    }

                    SettingsFieldRow(title: "Live Auto-Paste") {
                        HStack(alignment: .center, spacing: 8) {
                            ShortcutRecorderField(
                                shortcut: livePasteShortcutBinding,
                                validationError: $livePasteValidationError,
                                fixedWidth: 132
                            )
                            .frame(height: 24, alignment: .leading)

                            if settings.livePasteShortcut != nil {
                                Button("Clear") {
                                    livePasteValidationError = nil
                                    viewModel.updateLivePasteShortcut(nil)
                                }
                            }
                        }
                    }

                    if let livePasteValidationError {
                        SettingsMessageRow(livePasteValidationError, color: .red)
                    }

                    if settings.livePasteShortcut == nil {
                        SettingsMessageRow(
                            "Live Auto-Paste shortcut is not set. Record one above to enable.",
                            color: .secondary
                        )
                    }

                    SettingsFieldRow(title: "Shortcut behavior") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $settings.dictationShortcutMode) {
                                ForEach(DictationShortcutMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            SettingsHelpText(settings.dictationShortcutMode.description)
                        }
                    }
                }
            }

            SettingsGroup(title: "Menu bar") {
                SettingsFieldRow(title: "Output mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $settings.dictationOutputMode) {
                            ForEach(DictationOutputMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        SettingsHelpText(settings.dictationOutputMode.description)
                        SettingsHelpText(
                            "Used when starting dictation from the menu bar. Keyboard triggers above select their mode directly."
                        )
                    }
                }
            }

            SettingsGroup(title: "General") {
                ToggleSettingRow(
                    title: "Auto-copy final segment",
                    subtitle: "Copy the finalized segment to the clipboard after dictation stops.",
                    isOn: $settings.autoCopyEnabled
                )
            }
        }
    }
}

private struct TextProcessingSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel

    private var isLLMPolishingAvailableInCurrentMode: Bool {
        settings.dictationOutputMode == .overlayBuffer
    }

    private var llmPolishingEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.llmPolishingEnabled },
            set: { newValue in
                let wasEnabled = settings.llmPolishingEnabled
                settings.llmPolishingEnabled = newValue

                if newValue, !wasEnabled {
                    viewModel.prepareLLMPolishingPromptAccessIfNeeded()
                }
                // Turning polishing off stops the managed mlx-lm process
                // (Managed local mode only). External URL mode owns no local
                // process, and re-enabling stays lazy: the next dictation
                // restarts it via the managed backend bootstrap.
                viewModel.llmPolishingEnabledDidChange(newValue)
            }
        )
    }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Replacements") {
                ToggleSettingRow(
                    title: "Exact match replacements",
                    subtitle:
                        "Apply dictionary replacements while streaming in Live Auto-Paste and before commit in Overlay Buffer.",
                    isOn: $settings.replacementDictionaryEnabled
                )
                .help(
                    "In Live Auto-Paste, corrections briefly retype the last word in place. In apps that don't report the cursor position, avoid clicking elsewhere mid-dictation — a correction landing after the cursor moved can overwrite a few characters at the new position."
                )
            }

            SettingsGroup(title: "LLM Polishing") {
                if !isLLMPolishingAvailableInCurrentMode {
                    SettingsAvailabilityCard(
                        title: "Unavailable in Live Auto-Paste output mode",
                        message:
                            "LLM polishing runs before Overlay Buffer commits. Switch Dictation > Output mode to Overlay Buffer to enable it.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                Group {
                    ToggleSettingRow(
                        title: "LLM polishing",
                        subtitle:
                            "Send dictation text to an OpenAI-compatible chat completions server.",
                        isOn: llmPolishingEnabledBinding
                    )

                    // Live mirror of the polishing backend state at the point
                    // of control, so the toggle <-> server relationship is
                    // visible without tab-hopping (and the future inline model
                    // download progress renders right here).
                    switch settings.polishingBackendMode {
                    case .managedLocal:
                        SettingsFieldRow(title: "Backend") {
                            VStack(alignment: .leading, spacing: 6) {
                                ManagedBackendStatusLabel(status: viewModel.backendManager.mlxLMStatus)
                                SettingsHelpText(
                                    "Managed mlx-lm - starts with dictation while polishing is on. Details in the Endpoints tab."
                                )
                            }
                        }
                    case .externalURL:
                        SettingsHelpText(
                            "Uses the polishing server configured in the Endpoints tab."
                        )
                    }
                }
                .disabled(!isLLMPolishingAvailableInCurrentMode)
                .opacity(isLLMPolishingAvailableInCurrentMode ? 1.0 : 0.5)
            }

            SettingsGroup(title: "Shared Configuration") {
                SettingsFieldRow(title: "Config folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Open Config Folder") {
                            viewModel.openConfigFolder()
                        }

                        SettingsHelpText(
                            "Dictionary changes apply to live corrections and overlay finalization."
                        )
                    }
                }

                SettingsFieldRow(title: "Included files") {
                    SettingsFileNotes(notes: [
                        SettingsFileNote(
                            name: "replacement_dictionary.toml",
                            description:
                                "Replacements used in both output modes."
                        ),
                        SettingsFileNote(
                            name: "llm_system_prompt.toml",
                            description: "System prompt used for LLM polishing."
                        ),
                        SettingsFileNote(
                            name: "llm_user_prompt.toml",
                            description:
                                "User prompt template used for LLM polishing. Remove the {{replacement_dictionary}} placeholder if you do not want to send the dictionary to the LLM."
                        ),
                    ])
                }
            }
        }
    }
}

private struct AboutSettingsPane: View {
    let viewModel: DictationViewModel

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "localvoxtral"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "dev"
    }

    var body: some View {
        SettingsPage {
            SettingsGroup(title: "Application") {
                SettingsFieldRow(title: "Name") {
                    Text(appName)
                }

                SettingsFieldRow(title: "Version") {
                    Text("\(appVersion) (build \(appBuild))")
                }
            }

            SettingsGroup(title: "Diagnostics") {
                SettingsFieldRow(title: "Export") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Export Diagnostics…") {
                            viewModel.exportDiagnostics()
                        }

                        SettingsHelpText(
                            "Writes a redacted report to the Desktop; review before sharing."
                        )
                    }
                }
            }
        }
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(SettingsLayout.pagePadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: SettingsLayout.cardSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsLayout.cardPadding)
            .background {
                RoundedRectangle(
                    cornerRadius: SettingsLayout.cornerRadius,
                    style: .continuous
                )
                .fill(Color(nsColor: .quaternarySystemFill))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: SettingsLayout.cornerRadius,
                        style: .continuous
                    )
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsAvailabilityCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    private let cornerRadius: CGFloat = 16
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .fill(tint.opacity(0.10))
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(tint.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsHelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsFileNote: Identifiable {
    let id = UUID()
    let name: String
    let description: String
}

private struct SettingsFileNotes: View {
    let notes: [SettingsFileNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))

                    Text(note.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsInlineMessage: View {
    let message: String
    let color: Color

    init(_ message: String, color: Color) {
        self.message = message
        self.color = color
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsMessageRow: View {
    let message: String
    let color: Color

    init(_ message: String, color: Color) {
        self.message = message
        self.color = color
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
            Color.clear
                .frame(width: SettingsLayout.labelWidth, height: 1)
            SettingsInlineMessage(message, color: color)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToggleSettingRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                if let subtitle {
                    SettingsHelpText(subtitle)
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
