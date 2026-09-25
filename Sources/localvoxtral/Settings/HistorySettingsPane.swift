import SwiftUI

/// Every saved dictation, newest first: find one, copy it, see what polishing
/// did to it, delete it. The Storage group is where the archive's size and
/// lifetime are decided.
struct HistorySettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    var navigator: SettingsNavigator?

    @State private var model: DictationHistoryModel
    /// A shorter retention waiting for the user's yes, with what it deletes.
    @State private var pendingRetention: PendingRetention?
    @State private var isConfirmingDeleteAll = false
    /// Recordings on disk, and the yes that turning audio off waits for.
    @State private var audioSummary: (recordings: Int, bytes: Int) = (0, 0)
    @State private var isConfirmingAudioOff = false

    /// Bumped by every pick in the retention menu. A count that comes back
    /// for an older pick is dropped: two quick picks must end on the second.
    @State private var retentionPick = 0

    private struct PendingRetention: Equatable {
        let retention: DictationHistoryRetention
        /// Nil when the store could not count them.
        let deletedCount: Int?
    }

    /// `model` is for a caller that needs the pane in a given state (a
    /// rendering check); the app lets the pane build its own.
    init(
        settings: SettingsStore, viewModel: DictationViewModel,
        navigator: SettingsNavigator? = nil, model: DictationHistoryModel? = nil
    ) {
        self.settings = settings
        self.viewModel = viewModel
        self.navigator = navigator
        _model = State(
            initialValue: model
                ?? DictationHistoryModel(store: { [weak viewModel] in viewModel?.sessionStore })
        )
    }

    var body: some View {
        SettingsPage(tab: .history) {
            storageGroup
            dictationsGroup
        }
        .onAppear {
            // Launch and each save apply the rule; a Mac left on for a month
            // without a dictation would otherwise list what it promised to drop.
            viewModel.applyDictationHistoryRetention()
            if let request = navigator?.historyRequest {
                model.filter = request.filter
                model.since = request.since
                navigator?.historyRequest = nil
            }
        }
        // One reload per store write and per query edit. The short wait lets a
        // burst of keystrokes cost one fetch; a store write reloads at once.
        .task(id: ReloadTrigger(
            revision: viewModel.dictationHistoryRevision,
            searchText: model.searchText,
            filter: model.filter,
            since: model.since
        )) {
            if model.hasLoaded, !model.searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            await model.reload()
        }
        .task(id: viewModel.dictationHistoryRevision) {
            audioSummary = await viewModel.sessionStore?.audioSummary() ?? (0, 0)
        }
    }

    private struct ReloadTrigger: Equatable {
        let revision: Int
        let searchText: String
        let filter: DictationHistoryQuery.Filter
        let since: Date?
    }

    // MARK: - Storage

    /// Nil at zero: the empty list below says so, and under Don't keep the
    /// picker does. A count left under Don't keep means the delete has not
    /// finished, or failed.
    private var storageStatus: String? {
        guard settings.dictationHistoryRetention.savesDictations else {
            switch model.totalCount {
            case 0: return nil
            case 1: return "1 dictation still to delete."
            default: return "\(model.totalCount.formatted()) dictations still to delete."
            }
        }
        switch model.totalCount {
        case 0: return nil
        case 1: return "1 dictation on this Mac."
        default: return "\(model.totalCount.formatted()) dictations on this Mac."
        }
    }

    private var retentionBinding: Binding<DictationHistoryRetention> {
        Binding(
            get: { settings.dictationHistoryRetention },
            set: { chooseRetention($0) }
        )
    }

    private var storageGroup: some View {
        SettingsGroup(title: "Storage") {
            SettingsFieldRow(
                title: "Keep dictations",
                status: storageStatus,
                statusAccessibilityIdentifier: "history.storage.status"
            ) {
                HStack(spacing: 8) {
                    Picker("", selection: retentionBinding) {
                        ForEach(DictationHistoryRetention.allCases) { retention in
                            Text(retention.displayName).tag(retention)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("history.storage.retention")

                    Button("Delete All…", role: .destructive) {
                        isConfirmingDeleteAll = true
                    }
                    .disabled(model.totalCount == 0)
                    .accessibilityIdentifier("history.storage.deleteAll")
                }
            }
            SettingsFieldRow(
                title: "Keep dictation audio",
                help: "Stays on this Mac and is never sent anywhere. About 2 MB a minute.",
                status: audioStatus
            ) {
                Toggle("", isOn: audioBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!settings.dictationHistoryRetention.savesDictations)
                    .accessibilityIdentifier("history.storage.audio")
            }
        }
        .confirmationDialog(
            audioSummary.recordings == 1
                ? "Delete 1 recording?"
                : "Delete \(audioSummary.recordings.formatted()) recordings?",
            isPresented: $isConfirmingAudioOff
        ) {
            Button("Delete Recordings", role: .destructive) { turnAudioOff() }
        } message: {
            Text("The dictations stay. This can't be undone.")
        }
        .confirmationDialog(
            "Delete all \(model.totalCount.formatted()) dictations?",
            isPresented: $isConfirmingDeleteAll
        ) {
            Button("Delete All", role: .destructive) {
                Task { await model.deleteAll() }
            }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            pendingRetentionTitle,
            isPresented: Binding(
                get: { pendingRetention != nil },
                set: { if !$0 { pendingRetention = nil } }
            ),
            presenting: pendingRetention
        ) { pending in
            Button(Self.deleteButtonTitle(count: pending.deletedCount), role: .destructive) {
                retentionPick += 1
                applyRetention(pending.retention)
            }
        } message: { pending in
            Text(
                pending.retention.savesDictations
                    ? "This can't be undone."
                    : "New dictations won't be saved, and term suggestions stop. This can't be undone."
            )
        }
    }

    /// Nil when there is nothing kept; history off disables the switch and
    /// the retention picker already says why.
    private var audioStatus: String? {
        guard audioSummary.recordings > 0 else { return nil }
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(audioSummary.bytes), countStyle: .file)
        return audioSummary.recordings == 1
            ? "1 recording, \(size)."
            : "\(audioSummary.recordings.formatted()) recordings, \(size)."
    }

    private var audioBinding: Binding<Bool> {
        Binding(
            get: { settings.dictationAudioEnabled && settings.dictationHistoryRetention.savesDictations },
            set: { keep in
                if keep {
                    settings.dictationAudioEnabled = true
                } else if audioSummary.recordings > 0 {
                    isConfirmingAudioOff = true
                } else {
                    turnAudioOff()
                }
            }
        )
    }

    private func turnAudioOff() {
        settings.dictationAudioEnabled = false
        // A dictation in progress keeps nothing either, even if the switch
        // goes back on before it stops.
        viewModel.session.audio.sessionRecording.begin(enabled: false)
        let deleting = viewModel.sessionStore?.deleteAllAudio()
        Task {
            await deleting?.value
            audioSummary = await viewModel.sessionStore?.audioSummary() ?? (0, 0)
        }
    }

    private static func deleteButtonTitle(count: Int?) -> String {
        guard let count else { return "Delete" }
        return count == 1 ? "Delete 1 Dictation" : "Delete \(count.formatted()) Dictations"
    }

    private var pendingRetentionTitle: String {
        guard let pendingRetention else { return "" }
        if let days = pendingRetention.retention.days {
            return "Delete dictations older than \(days) days?"
        }
        return "Delete every saved dictation?"
    }

    /// A rule that deletes something asks first; one that deletes nothing
    /// (longer, or nothing old enough yet) just applies.
    private func chooseRetention(_ retention: DictationHistoryRetention) {
        retentionPick += 1
        let pick = retentionPick
        pendingRetention = nil
        guard retention != settings.dictationHistoryRetention else { return }
        guard settings.dictationHistoryRetention.keepsLonger(than: retention) else {
            applyRetention(retention)
            return
        }
        Task {
            let deletedCount = await model.countDeleted(by: retention, now: Date())
            guard pick == retentionPick else { return }
            if deletedCount == 0 {
                applyRetention(retention)
            } else {
                pendingRetention = PendingRetention(retention: retention, deletedCount: deletedCount)
            }
        }
    }

    private func applyRetention(_ retention: DictationHistoryRetention) {
        settings.dictationHistoryRetention = retention
        viewModel.applyDictationHistoryRetention()
    }

    // MARK: - Dictations

    private var dictationsGroup: some View {
        @Bindable var model = model
        return SettingsGroup(title: "Dictations") {
            SettingsGroupRow {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("history.search")

                    Picker("", selection: $model.filter) {
                        Text("All").tag(DictationHistoryQuery.Filter.all)
                        Text("Not inserted").tag(DictationHistoryQuery.Filter.notInserted)
                        Text("Polish failed").tag(DictationHistoryQuery.Filter.polishFailed)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("history.filter")
                }
            }

            if let since = model.since {
                SettingsGroupRow {
                    HStack {
                        Text("Since \(since.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Show All") { model.since = nil }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("history.since.clear")
                    }
                }
            }

            if model.entries.isEmpty {
                SettingsGroupRow {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("history.empty")
                }
            } else {
                // Lazy: a page is a hundred rows of text, most of them never
                // scrolled to.
                LazyVStack(spacing: 0) {
                    ForEach(model.entries) { entry in
                        HistoryEntryRow(entry: entry, model: model)
                    }
                }
                if model.hasMore {
                    SettingsGroupRow {
                        Button("Show More") {
                            Task { await model.showMore() }
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("history.showMore")
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if !model.hasLoaded { return "Loading…" }
        if model.isFiltering { return "No dictation matches." }
        return settings.dictationHistoryRetention.savesDictations
            ? "No dictations yet."
            : "History is off."
    }
}

private struct HistoryEntryRow: View {
    let entry: DictationHistoryEntry
    let model: DictationHistoryModel

    @State private var isHovering = false

    private var isExpanded: Bool { model.expandedEntryID == entry.id }

    /// Hover says the row opens on a click; an open row keeps a lighter fill
    /// so it reads as the selected one.
    private var rowFill: Color {
        if isHovering { return Color.primary.opacity(0.06) }
        return isExpanded ? Color.primary.opacity(0.03) : .clear
    }

    var body: some View {
        SettingsGroupRow {
            // The header-to-text gap is the button label's 4pt in both
            // states, so opening a row does not nudge its first line.
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    model.toggleExpanded(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        header
                        if !isExpanded {
                            Text(entry.finalText)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history.row")

                if isExpanded { expandedBody }
            }
        }
        .background(rowFill)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .contextMenu {
            Button("Copy") { model.copyFinalText(of: entry) }
            if entry.textWasChanged {
                Button("Copy Transcript") { model.copyTranscript(of: entry) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await model.delete(entry) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            // `TimelineView` would keep "Today" honest across midnight; a row
            // that says Today for a few hours too long is not worth a timer.
            Text(DictationHistoryRowText.timestamp(for: entry.startedAt, now: Date()))
            if let appName = model.targetAppName(for: entry) {
                Text("·")
                Text(appName)
            }
            Spacer(minLength: 8)
            if let problem = DictationHistoryRowText.problem(for: entry) {
                Text(problem)
                    .foregroundStyle(.orange)
            } else if let change = DictationHistoryRowText.change(for: entry) {
                Text(change)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            expandedText
            actions
        }
    }

    @ViewBuilder
    private var expandedText: some View {
        if entry.textWasChanged {
            let diff = TranscriptDiff.words(from: entry.rawText, to: entry.finalText)
            Text(Self.marked(entry.finalText, ranges: diff.added, color: .green))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Transcript")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text(Self.marked(entry.rawText, ranges: diff.removed, color: .red))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.finalText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Copy") { model.copyFinalText(of: entry) }
                .accessibilityIdentifier("history.row.copy")
            if entry.textWasChanged {
                Button("Copy Transcript") { model.copyTranscript(of: entry) }
                    .accessibilityIdentifier("history.row.copyTranscript")
            }
            Button("Delete", role: .destructive) {
                Task { await model.delete(entry) }
            }
            .accessibilityIdentifier("history.row.delete")
            Spacer(minLength: 8)
            Text(DictationHistoryRowText.details(for: entry))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    /// `text` with a tinted background behind each of `ranges`.
    static func marked(_ text: String, ranges: [Range<String.Index>], color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges {
            guard
                let lower = AttributedString.Index(range.lowerBound, within: attributed),
                let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].backgroundColor = color.opacity(0.22)
        }
        return attributed
    }
}
