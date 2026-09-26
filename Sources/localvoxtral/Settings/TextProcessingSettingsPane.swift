import AppKit
import SwiftUI

struct TextProcessingSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    @State private var isShowingLearnedTerms = false

    static let speakerProfileExample = """
        Backend engineer at Acme, mostly Swift and Python.
        • Names I say a lot: Qwen, Claude Code, vLLM, Ghostty
        """

    /// What the Polishing rows do, including when Claude Desktop gets the
    /// agent prompt (only with the session-context settings on, #669).
    private static let polishingLearnMoreURL = URL(
        string: "https://github.com/T0mSIlver/localvoxtral/blob/main/docs/coding-agents.md#polishing"
    )!

    private var isLLMPolishingReachable: Bool {
        settings.isOverlayBufferSessionReachable
    }

    /// Reading `learnedTermRevision` is what re-renders the row after a
    /// dictation: the store is a plain class, so nothing else observes it.
    private var learnedTermCount: Int {
        _ = viewModel.learnedTermRevision
        return viewModel.learnedTermStore?.summary().terms ?? 0
    }

    private var learnedTermStatus: String {
        _ = viewModel.learnedTermRevision
        guard let summary = viewModel.learnedTermStore?.summary(), summary.terms > 0 else {
            return "0"
        }
        return summary.projects > 1
            ? "\(summary.terms) in \(summary.projects) projects"
            : "\(summary.terms)"
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
                // Turning polishing off stops the managed polishd process
                // (Managed local mode only). External URL mode owns no local
                // process, and re-enabling starts managed polishd eagerly.
                viewModel.engines.llmPolishingEnabledDidChange(newValue)
            }
        )
    }

    var body: some View {
        SettingsPage(tab: .textProcessing) {
            SettingsGroup(title: "About you") {
                SettingsFieldRow(
                    title: "In your words",
                    layout: .stacked
                ) {
                    TextEditor(text: $settings.polishSpeakerProfile)
                        .font(.body)
                        .frame(height: 96)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .overlay(alignment: .topLeading) {
                            if settings.polishSpeakerProfile.isEmpty {
                                // TextEditor has no prompt of its own. The
                                // 5pt inset is NSTextView's line-fragment
                                // padding, so the example sits where typed
                                // text will.
                                Text(Self.speakerProfileExample)
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        )
                        .accessibilityIdentifier("settings.aboutYou.profile")
                } footer: {
                    if settings.polishSpeakerProfile.count
                        > LLMPromptTemplates.speakerProfileMaxCharacters
                    {
                        Text("Only the first \(LLMPromptTemplates.speakerProfileMaxCharacters) characters are sent.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsFieldRow(
                    title: "Names and terms",
                    layout: .stacked
                ) {
                    SpeakerTermsField(terms: $settings.polishSpeakerTerms)
                }

                SettingsFieldRow(
                    title: "Suggestions",
                    layout: .stacked
                ) {
                    SpeakerTermSuggestionsView(model: viewModel.termSuggestions)
                }

                SettingsFieldRow(title: "Suggest by itself") {
                    Picker("", selection: $settings.termSuggestionInterval) {
                        ForEach(TermSuggestionInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(viewModel.termSuggestions.unavailableReason != nil)
                    .accessibilityIdentifier("settings.aboutYou.suggestInterval")
                }
            }

            SettingsGroup(title: "Polishing", learnMoreURL: Self.polishingLearnMoreURL) {
                if !isLLMPolishingReachable {
                    SettingsAvailabilityCard(
                        title: "No Overlay Buffer shortcut",
                        message:
                            "Polishing runs on Overlay Buffer dictations. Record a shortcut in Dictation.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                Group {
                    SettingsFieldRow(
                        title: "Enable for Overlay Buffer"
                    ) {
                        Toggle("", isOn: llmPolishingEnabledBinding)
                            .labelsHidden()
                    }

                    SettingsFieldRow(title: "Agent prompt profile in terminals and Claude Desktop") {
                        Toggle("", isOn: $settings.agentPolishProfileEnabled)
                            .labelsHidden()
                    }

                    SettingsFieldRow(
                        title: "Say \"paste clipboard\" to paste clipboard"
                    ) {
                        Toggle("", isOn: $settings.clipboardPayloadMacroEnabled)
                            .labelsHidden()
                    }
                }
                .disabled(!isLLMPolishingReachable)
                .opacity(isLLMPolishingReachable ? 1.0 : 0.5)
            }

            SettingsGroup(title: "Advanced") {
                SettingsFieldRow(
                    title: "Dismissed suggestions",
                    status: "\(settings.polishDismissedTermSuggestions.count)"
                ) {
                    Button("Forget") {
                        settings.polishDismissedTermSuggestions = []
                    }
                    .disabled(settings.polishDismissedTermSuggestions.isEmpty)
                }

                SettingsFieldRow(
                    title: "Terms learned from polishing",
                    status: learnedTermStatus
                ) {
                    HStack(spacing: 8) {
                        // Enabled at zero: the sheet is where a new machine
                        // imports terms (#523).
                        Button("Show") {
                            isShowingLearnedTerms = true
                        }
                        .accessibilityIdentifier("settings.learnedTerms.show")
                        Button("Forget") {
                            viewModel.learnedTermStore?.forgetAll()
                        }
                        .disabled(learnedTermCount == 0)
                    }
                }
                .sheet(isPresented: $isShowingLearnedTerms) {
                    LearnedTermsSheet(viewModel: viewModel) {
                        isShowingLearnedTerms = false
                    }
                }

                SettingsFieldRow(title: "Replacement dictionary (legacy)") {
                    Toggle("", isOn: $settings.replacementDictionaryEnabled)
                        .labelsHidden()
                }

                SettingsFieldRow(title: "Config folder") {
                    Button("Open") {
                        viewModel.openConfigFolder()
                    }
                }

                // Stacked: a list of file names with descriptions is a
                // full-width block, not a control. `terminal_apps.toml` is
                // deliberately absent: it is a launch-time import source,
                // not a live config file — the Terminals section is the UI.
                SettingsFieldRow(title: "Files", layout: .stacked) {
                    SettingsFileNotes(notes: [
                        SettingsFileNote(name: "replacement_dictionary.toml"),
                        SettingsFileNote(name: "llm_system_prompt.toml"),
                        SettingsFileNote(name: "llm_user_prompt.toml"),
                        SettingsFileNote(name: "llm_system_prompt_agent.toml"),
                        SettingsFileNote(name: "llm_user_prompt_agent.toml"),
                    ])
                }
            }
        }
    }
}

/// The terms list: chips you remove with their ×, one field that adds on
/// Return (a comma-separated paste adds several).
private struct SpeakerTermsField: View {
    @Binding var terms: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !terms.isEmpty {
                SpeakerTermsFlow(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        HStack(spacing: 4) {
                            Text(term)
                                .lineLimit(1)
                            Button {
                                terms.removeAll { $0 == term }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(term)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                    }
                }
            }

            TextField("", text: $draft, prompt: Text("Qwen, Claude Code, vLLM…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    // Past a cap, or a duplicate: the text stays so the
                    // Return visibly did nothing instead of eating the term.
                    let updated = SpeakerTerms.adding(draft, to: terms)
                    guard updated != terms else { return }
                    terms = updated
                    draft = ""
                }
                .accessibilityIdentifier("settings.aboutYou.termsField")
        }
    }
}

/// Suggested terms as ghost chips: the + adds one to the list, the × refuses
/// it for good. Nothing is added without a click.
private struct SpeakerTermSuggestionsView: View {
    let model: SpeakerTermSuggestionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.suggestions.isEmpty {
                SpeakerTermsFlow(spacing: 6) {
                    ForEach(model.suggestions, id: \.self) { term in
                        HStack(spacing: 4) {
                            Button {
                                model.accept(term)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "plus")
                                        .font(.caption2.weight(.bold))
                                    Text(term).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(term)")

                            Button {
                                model.dismiss(term)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Never suggest \(term)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(
                            Capsule().strokeBorder(
                                Color.secondary.opacity(0.6),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        )
                    }
                }
            }

            if model.phase == .loading {
                SpeakerTermSuggestionsProgress(model: model)
            } else {
                HStack(spacing: 8) {
                    Button(model.suggestions.isEmpty ? "Suggest terms" : "Suggest again") {
                        model.start()
                    }
                    .disabled(model.unavailableReason != nil)
                    .accessibilityIdentifier("settings.aboutYou.suggestTerms")

                    if !model.suggestions.isEmpty {
                        Button("Add all") { model.acceptAll() }
                    }

                    if let reason = model.unavailableReason {
                        Text(reason)
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                    switch model.phase {
                    case .nothingFound:
                        Text("Nothing new to suggest.")
                            .font(.callout).foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    case .idle, .loading:
                        EmptyView()
                    }
                    }
                }

                if model.unavailableReason == nil {
                    Text("Uses API credits")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.paneAppeared() }
        .onDisappear { model.paneDisappeared() }
    }
}

/// A run in flight: empty dashed chips breathing where the suggestions will
/// land, and one line that keeps counting — what is being read, for how long.
/// The clock is the whole message that this can take minutes.
private struct SpeakerTermSuggestionsProgress: View {
    let model: SpeakerTermSuggestionModel

    private static let placeholderWidths: [CGFloat] = [64, 96, 52, 80, 70]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(Self.placeholderWidths.enumerated()), id: \.offset) { index, width in
                    Capsule()
                        .strokeBorder(
                            Color.secondary.opacity(0.6),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                        .frame(width: width, height: 22)
                        .phaseAnimator([0.25, 0.9]) { chip, opacity in
                            chip.opacity(opacity)
                        } animation: { _ in
                            .easeInOut(duration: 0.9).delay(Double(index) * 0.15)
                        }
                }
            }
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusLine(at: context.date))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Stop") { model.stop() }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.aboutYou.suggestProgress")
    }

    private func statusLine(at date: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(model.startedAt ?? date)))
        let clock = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        guard model.readingCount > 0 else { return clock }
        return "Reading \(model.readingCount) dictations · \(clock)"
    }
}

/// Left-to-right wrapping rows for the term chips. Only used where the parent
/// proposes a finite width (a stacked settings row); with no width proposed
/// everything sits on one row.
private struct SpeakerTermsFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, in: proposal.width ?? .infinity)
        return CGSize(
            width: proposal.width ?? (frames.map(\.maxX).max() ?? 0),
            height: frames.map(\.maxY).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (subview, frame) in zip(subviews, frames(for: subviews, in: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(for subviews: Subviews, in width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

private struct SettingsFileNote: Identifiable {
    let id = UUID()
    let name: String
}

private struct SettingsFileNotes: View {
    let notes: [SettingsFileNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                Text(note.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
