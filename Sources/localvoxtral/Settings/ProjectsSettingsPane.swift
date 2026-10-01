import ClaudeContextWire
import SwiftUI

/// Every project quick capture lists, one table row each (#939): where its
/// issues go, where it is checked out, when it was last used and the drafts
/// waiting on it. A row opens the project's sheet. The terms outside every
/// project close the table as "No project" (#972), so this pane is the one
/// place learned terms are seen, pinned and forgotten.
///
/// Import… and Export… under Learned terms move every project's terms at
/// once, so they sit below the table, not in a project's sheet (#999).
///
/// Opening the pane asks GitHub again for every project's description.
struct ProjectsSettingsPane: View {
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    /// Nil in a view model that runs no services (previews, tests).
    let inbox: QuickCaptureInboxViewModel?
    let openInbox: () -> Void
    /// The project key of each dictation in the last seven days, read from
    /// History when the pane opens.
    @State private var dictationProjectKeys: [String?] = []
    @State private var openProject: OpenProject?
    @State private var transferMessage: String?

    enum OpenProject: Identifiable, Hashable {
        case project(key: String)
        case unlisted

        var id: Self { self }
    }

    private var rows: [ProjectsPaneRow] {
        _ = viewModel.learnedTermRevision
        return inbox?.projectRows(dictationProjectKeys: dictationProjectKeys) ?? []
    }

    /// Reading `learnedTermRevision` re-renders Export… after a dictation
    /// or an import: the store is a plain class, so nothing else observes it.
    private var hasLearnedTerms: Bool {
        _ = viewModel.learnedTermRevision
        return !(viewModel.learnedTermStore?.snapshot().projects.isEmpty ?? true)
    }

    var body: some View {
        let rows = rows
        let unlisted = inbox?.unlistedTerms()
        SettingsPage(tab: .projects) {
            SettingsGroup(title: "Projects", learnMoreURL: ProjectsLearnMore.projects) {
                if let store = viewModel.learnedTermStore, let problem = store.problem {
                    // The file also holds the projects: nothing else here
                    // means anything until it loads (#989).
                    StoredFileProblemRow(problem: problem, fileName: "learned-terms.json") {
                        _ = try await store.moveAsideAndStartOver()
                    }
                } else if rows.isEmpty && unlisted == nil {
                    SettingsGroupRow {
                        Text("No projects. A project appears once you dictate into a coding agent there.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SettingsGroupRow {
                        HStack(alignment: .firstTextBaseline, spacing: ProjectsTableColumnsSpacing.value) {
                            ProjectsTableColumns(
                                name: Text("Project"), filing: Text("Files issues in"), checkouts: Text("Checkouts"),
                                lastUsed: Text("Last used"), drafts: Text("Drafts")
                            )
                            Text("Group").frame(width: ProjectGroupPicker.width, alignment: .leading)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        SettingsGroupRow {
                            // The picker sits outside the row's button, so
                            // choosing a group does not open the sheet.
                            HStack(alignment: .firstTextBaseline, spacing: ProjectsTableColumnsSpacing.value) {
                                Button {
                                    openProject = .project(key: row.key)
                                } label: {
                                    ProjectsTableColumns(
                                        name: Text(row.name).fontWeight(.semibold),
                                        filing: ProjectsFilingText(filing: row.filing),
                                        checkouts: Text(row.checkouts()).foregroundStyle(.secondary),
                                        lastUsed: Text(ProjectsPane.lastUsed(row.lastUsed, now: Date()))
                                            .foregroundStyle(.secondary),
                                        drafts: Text(row.draftsWaiting == 0 ? "–" : "\(row.draftsWaiting)")
                                            .foregroundStyle(.secondary)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("projects.row")
                                ProjectGroupPicker(group: row.group) { group in
                                    Task { await inbox?.setGroup(group, keys: row.keys) }
                                }
                            }
                        }
                    }
                    if let unlisted {
                        SettingsGroupRow {
                            HStack(alignment: .firstTextBaseline, spacing: ProjectsTableColumnsSpacing.value) {
                                Button {
                                    openProject = .unlisted
                                } label: {
                                    ProjectsTableColumns(
                                        name: Text(LearnedTermProjectResolver.shared.name).fontWeight(.semibold),
                                        filing: Text("–").foregroundStyle(.secondary),
                                        checkouts: Text("–").foregroundStyle(.secondary),
                                        lastUsed: Text(ProjectsPane.lastUsed(unlisted.lastUsed, now: Date()))
                                            .foregroundStyle(.secondary),
                                        drafts: Text("–").foregroundStyle(.secondary)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("projects.noProject")
                                Text("–").foregroundStyle(.secondary)
                                    .frame(width: ProjectGroupPicker.width, alignment: .leading)
                            }
                        }
                    }
                }
            }

            SettingsGroup(title: "Learned terms", learnMoreURL: ProjectsLearnMore.learnedTerms) {
                SettingsFieldRow(title: "Move to another Mac", status: transferMessage) {
                    HStack(spacing: 8) {
                        // Enabled with no terms: a new machine imports (#523).
                        Button("Import…") {
                            LearnedTermsTransfer.importTerms(into: viewModel.learnedTermStore) {
                                transferMessage = $0
                            }
                        }
                        .accessibilityIdentifier("projects.learnedTerms.import")
                        if hasLearnedTerms {
                            Button("Export…") {
                                LearnedTermsTransfer.exportTerms(from: viewModel.learnedTermStore) {
                                    transferMessage = $0
                                }
                            }
                            .accessibilityIdentifier("projects.learnedTerms.export")
                        }
                    }
                }
            }
            if let store = viewModel.learnedTermStore {
                IgnoredProjectsGroup(store: store, revision: viewModel.learnedTermRevision)
            }
        }
        .sheet(item: $openProject) { open in
            switch open {
            case .project(let key):
                projectSheet(key)
                    .opensWithNothingFocused()
            case .unlisted:
                UnlistedTermsSheet(viewModel: viewModel, inbox: inbox) {
                    openProject = nil
                }
                .opensWithNothingFocused()
            }
        }
        .task {
            // Another running copy may have changed the projects (#1126).
            await viewModel.learnedTermStore?.reloadIfChanged()
            if let store = viewModel.sessionStore {
                let entries = await store.entries(since: Date().addingTimeInterval(-7 * 86_400))
                dictationProjectKeys = entries.map(\.projectKey)
            }
            await inbox?.refreshProjects(force: true)
        }
    }

    private func projectSheet(_ key: String) -> some View {
        ProjectDetailSheet(
            projectKey: key,
            settings: settings,
            viewModel: viewModel,
            inbox: inbox,
            dictationProjectKeys: dictationProjectKeys,
            openInbox: {
                openProject = nil
                openInbox()
            },
            onDone: { openProject = nil }
        )
    }
}

enum ProjectsLearnMore {
    static let projects = DocsLink.page("docs/coding-agents/#projects")
    static let learnedTerms = DocsLink.page("docs/dictation/#terms-learned-from-polishing")
}

/// The gap between the table's columns. With the Group column, the fixed
/// widths leave "Files issues in" about 100 points in the Settings window.
private enum ProjectsTableColumnsSpacing {
    static let value: CGFloat = 8
}

/// The table's five columns, the header's and each row's alike.
private struct ProjectsTableColumns<Name: View, Filing: View, Checkouts: View, LastUsed: View, Drafts: View>: View {
    let name: Name
    let filing: Filing
    let checkouts: Checkouts
    let lastUsed: LastUsed
    let drafts: Drafts

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ProjectsTableColumnsSpacing.value) {
            name.frame(width: 104, alignment: .leading)
            filing.frame(maxWidth: .infinity, alignment: .leading)
            checkouts.frame(width: 88, alignment: .leading)
            lastUsed.frame(width: 64, alignment: .leading)
            drafts.frame(width: 36, alignment: .trailing)
        }
        .lineLimit(2)
    }
}

/// The Group column (#1005): Work, Personal or None.
/// Borderless, so it reads as text like the other columns: a bordered
/// picker left "Files issues in" too narrow to read.
private struct ProjectGroupPicker: View {
    static let width: CGFloat = 72
    let group: ProjectGroup?
    let onChange: (ProjectGroup?) -> Void

    var body: some View {
        Menu {
            Picker("Group", selection: Binding(get: { group }, set: onChange)) {
                Text("None").tag(ProjectGroup?.none)
                ForEach(ProjectGroup.builtIn, id: \.self) { group in
                    Text(group.displayName).tag(ProjectGroup?.some(group))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(group?.displayName ?? "None")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .frame(width: Self.width, alignment: .leading)
        .accessibilityIdentifier("projects.row.group")
    }
}

/// Where File sends a project's issues, or why the project cannot say yet.
private struct ProjectsFilingText: View {
    let filing: ProjectsPaneRow.Filing

    var body: some View {
        switch filing {
        case .repository(let repository):
            Text(repository)
        case .forkUnpicked:
            warning("Fork: pick where to file")
        case .noRepository:
            warning("No GitHub repository")
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }
}

/// One project's four groups (#939), the same rows for every project:
/// Repository, Description, Terms, Activity.
struct ProjectDetailSheet: View {
    let projectKey: String
    @Bindable var settings: SettingsStore
    let viewModel: DictationViewModel
    let inbox: QuickCaptureInboxViewModel?
    let dictationProjectKeys: [String?]
    let openInbox: () -> Void
    let onDone: () -> Void

    init(
        projectKey: String, settings: SettingsStore, viewModel: DictationViewModel,
        inbox: QuickCaptureInboxViewModel?, dictationProjectKeys: [String?],
        openInbox: @escaping () -> Void, onDone: @escaping () -> Void, exportMessage: String? = nil
    ) {
        self.projectKey = projectKey
        _settings = Bindable(settings)
        self.viewModel = viewModel
        self.inbox = inbox
        self.dictationProjectKeys = dictationProjectKeys
        self.openInbox = openInbox
        self.onDone = onDone
        _exportMessage = State(initialValue: exportMessage)
    }

    @State private var isEditingRepository = false
    @State private var repositoryDraft = ""
    @State private var isEditingDescription = false
    @State private var descriptionDraft = ""
    @State private var removal: Removal?
    /// What Export Terms… reported: a failed backup must show before the
    /// user forgets the only copy.
    @State private var exportMessage: String?
    private var tokenCounter: PolishPromptTokenCounter {
        PolishPromptTokenCounter(settings: settings, ledger: viewModel.engines.usageLedger)
    }

    private var row: ProjectsPaneRow? {
        _ = viewModel.learnedTermRevision
        // Any of its keys: the leading checkout changes when the Mac's
        // folder goes or comes back.
        return inbox?.projectRows(dictationProjectKeys: dictationProjectKeys).first { $0.keys.contains(projectKey) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let row {
                Text(row.name)
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                        repositoryGroup(row)
                        descriptionGroup(row)
                        ProjectTermsGroup(
                            terms: row.terms, keys: row.keys, store: viewModel.learnedTermStore,
                            tokenCounter: tokenCounter)
                        activityGroup(row)
                    }
                }
                .settingsScrollEdgeEffectHidden()
            } else {
                Text("This project is no longer listed.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let row {
                    Button("Forget Project…") { removal = .forget(row) }
                        .accessibilityIdentifier("projects.forget")
                    Button("Ignore Project…") { removal = .ignore(row) }
                        .accessibilityIdentifier("projects.ignore")
                }
                if let exportMessage {
                    Text(exportMessage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("projects.exportStatus")
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 640)
        .confirmationDialog(
            removal?.title ?? "", isPresented: isConfirmingRemoval, titleVisibility: .visible, presenting: removal
        ) { removal in
            switch removal {
            case .forget(let row):
                Button("Forget Project", role: .destructive) {
                    viewModel.learnedTermStore?.forgetProject(keys: row.keys)
                    onDone()
                }
                exportButton(row)
            case .ignore(let row):
                Button("Ignore Project", role: .destructive) {
                    viewModel.learnedTermStore?.ignoreProject(
                        key: Self.ignoreKey(row), name: row.name, keys: row.keys)
                    onDone()
                }
                exportButton(row)
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.message)
        }
    }

    /// Forget Project and Ignore Project (#1006), each confirmed: the
    /// project's learned terms are lost.
    enum Removal {
        case forget(ProjectsPaneRow)
        case ignore(ProjectsPaneRow)

        var title: String {
            switch self {
            case .forget(let row): "Forget \(row.name)?"
            case .ignore(let row): "Ignore \(row.name)?"
            }
        }

        var message: String {
            switch self {
            case .forget(let row):
                "\(Self.terms(row)) It comes back the next time you dictate there."
            case .ignore(let row):
                "\(Self.terms(row)) localvoxtral stops learning there and its coding agent is not asked for terms. Dictation there works as before."
            }
        }

        private static func terms(_ row: ProjectsPaneRow) -> String {
            switch row.terms.count {
            case 0: "Its records are deleted."
            case 1: "Its records and its learned term are deleted."
            default: "Its records and its \(row.terms.count) learned terms are deleted."
            }
        }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    @ViewBuilder
    private func exportButton(_ row: ProjectsPaneRow) -> some View {
        if !row.terms.isEmpty {
            Button("Export Terms…") {
                LearnedTermsTransfer.exportTerms(from: viewModel.learnedTermStore) { exportMessage = $0 }
            }
        }
    }

    /// The ignore entry's key: the repository's record when the project has
    /// a remote, so every checkout of it is ignored; else its checkout's.
    static func ignoreKey(_ row: ProjectsPaneRow) -> String {
        row.keys.first { $0.hasPrefix(ProjectRemote.keyPrefix) } ?? row.key
    }

    // MARK: Repository

    private func repositoryGroup(_ row: ProjectsPaneRow) -> some View {
        SettingsGroup(title: "Repository", learnMoreURL: ProjectsLearnMore.projects) {
            SettingsFieldRow(title: "GitHub repository") {
                HStack(spacing: 8) {
                    Text(row.repository ?? "None")
                        .foregroundStyle(row.repository == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                    // An origin is changed in git; only a typed answer, or
                    // none, is the app's to change.
                    if row.repository == nil || row.repositoryTyped {
                        Button(row.repository == nil ? "Set…" : "Change…") {
                            repositoryDraft = row.repository ?? ""
                            isEditingRepository = true
                        }
                        .popover(isPresented: $isEditingRepository, arrowEdge: .bottom) {
                            repositoryEditor(row)
                        }
                    }
                }
            }
            SettingsFieldRow(title: "Checkouts") {
                Text(row.checkouts(macName: "This Mac"))
                    .foregroundStyle(.secondary)
            }
            SettingsFieldRow(title: "File issues here") {
                if let fork = row.repository, let upstream = row.upstream {
                    Picker("File issues here", selection: filing(fork: fork, upstream: upstream, row: row)) {
                        if case .forkUnpicked = row.filing {
                            Text("Choose").tag(String?.none)
                        }
                        Text(fork).tag(String?.some(fork))
                        Text(upstream).tag(String?.some(upstream))
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(row.issueRepository ?? "None")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func repositoryEditor(_ row: ProjectsPaneRow) -> some View {
        let trimmed = repositoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .trailing, spacing: 10) {
            TextField("owner/repository", text: $repositoryDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Button("Cancel") { isEditingRepository = false }
                Button("Save") {
                    isEditingRepository = false
                    Task { await inbox?.setTypedRepository(trimmed, projectKey: row.key) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!QuickCaptureInbox.isRepository(trimmed))
            }
        }
        .padding(12)
    }

    private func filing(fork: String, upstream: String, row: ProjectsPaneRow) -> Binding<String?> {
        Binding(
            get: {
                if case .forkUnpicked = row.filing { return nil }
                return row.issueRepository
            },
            set: { choice in
                guard let choice else { return }
                Task { await inbox?.setFilesUpstream(choice == upstream, repository: fork) }
            }
        )
    }

    // MARK: Description

    private func descriptionGroup(_ row: ProjectsPaneRow) -> some View {
        SettingsGroup(title: "Description", learnMoreURL: ProjectsLearnMore.projects) {
            SettingsGroupRow {
                HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
                    Text(row.description ?? "No description.")
                        .foregroundStyle(row.description == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Edit…") {
                        descriptionDraft = row.description ?? ""
                        isEditingDescription = true
                    }
                    .popover(isPresented: $isEditingDescription, arrowEdge: .bottom) {
                        descriptionEditor(row)
                    }
                }
            }
            SettingsFieldRow(title: "Written by") {
                Text(Self.writer(row.descriptionSource))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func descriptionEditor(_ row: ProjectsPaneRow) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextField("What it is and what it has", text: $descriptionDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .frame(width: 360)
            HStack {
                Button("Cancel") { isEditingDescription = false }
                Button("Save") {
                    isEditingDescription = false
                    saveDescription(descriptionDraft, row: row)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    /// The user's line replaces the automatic one; an emptied field, or one
    /// set back to that text, returns to it. A repository checked out in
    /// several places has one line, kept under its leading key.
    private func saveDescription(_ text: String, row: ProjectsPaneRow) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let automatic = inbox?.model.projectChoices.first { $0.key == row.key }?.automaticLine
        for key in row.keys.dropFirst() { settings.setQuickCaptureProjectLine("", for: key) }
        settings.setQuickCaptureProjectLine(trimmed == automatic ? "" : trimmed, for: row.key)
    }

    static func writer(_ source: ProjectsPaneRow.DescriptionSource) -> String {
        switch source {
        case .user: "You"
        case .github: "GitHub"
        case .agent: "The coding agent"
        case .readme: "The README"
        case .none: "No one yet"
        }
    }

    // MARK: Activity

    private func activityGroup(_ row: ProjectsPaneRow) -> some View {
        SettingsGroup(title: "Activity") {
            SettingsFieldRow(title: "Joined sessions") {
                HStack(spacing: 6) {
                    if row.sessions.running > 0 {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                    Text(Self.sessions(row.sessions))
                        .foregroundStyle(.secondary)
                }
            }
            SettingsFieldRow(title: "Captures") {
                HStack(spacing: 8) {
                    Text(Self.captures(waiting: row.draftsWaiting, filed: row.filed))
                        .foregroundStyle(.secondary)
                    Button("Open Inbox", action: openInbox)
                }
            }
            SettingsFieldRow(title: "Dictations") {
                Text("\(row.dictationsThisWeek) this week")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func sessions(_ sessions: ProjectsPaneRow.Sessions) -> String {
        guard sessions.running > 0 else { return "None running" }
        let names = sessions.agents.map { agent in
            switch agent {
            case .claude: "Claude Code"
            case .opencode: "opencode"
            case .vibe: "Mistral Vibe"
            case .codex: "Codex"
            }
        }
        return "\(sessions.running) running · " + names.joined(separator: ", ")
    }

    static func captures(waiting: Int, filed: Int) -> String {
        "\(waiting) \(waiting == 1 ? "draft" : "drafts") waiting · \(filed) filed"
    }
}

/// The terms outside every project, the table's "No project" entry (#972):
/// the same Terms group as a project's sheet, alone.
struct UnlistedTermsSheet: View {
    let viewModel: DictationViewModel
    let inbox: QuickCaptureInboxViewModel?
    let onDone: () -> Void

    private var unlisted: ProjectsPaneUnlisted? {
        _ = viewModel.learnedTermRevision
        return inbox?.unlistedTerms()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LearnedTermProjectResolver.shared.name)
                .font(.headline)
            ScrollView {
                // Forgetting the last term empties the group rather than
                // closing the sheet under the pointer.
                ProjectTermsGroup(
                    terms: unlisted?.terms ?? [], keys: unlisted?.keys ?? [], store: viewModel.learnedTermStore,
                    tokenCounter: PolishPromptTokenCounter(
                        settings: viewModel.settings, ledger: viewModel.engines.usageLedger))
            }
            .settingsScrollEdgeEffectHidden()
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 640)
    }
}

/// Every term of a project, in its sheet (#972): a search field once the
/// list is long, then each term with how far it has come, a pin and a
/// forget button. Forget All… in the header clears the project's terms.
/// A term shows once for all of the project's checkouts, and pin and forget
/// act on every checkout that holds it.
struct ProjectTermsGroup: View {
    let terms: [LearnedTerm]
    let keys: [String]
    let store: LearnedTermStore?
    /// Sizes the terms in the polish prompt; nil shows no size.
    var tokenCounter: PolishPromptTokenCounter? = nil
    @State private var sentTermsTokens: String?
    @State private var query = ""
    @State private var isConfirmingForgetAll = false

    /// More rows than this and the list scrolls inside the group, so the
    /// Activity group below stays in reach.
    static let scrollAbove = 8
    static let listHeight: CGFloat = 340

    var body: some View {
        let forgetAll: (title: String, action: () -> Void)? =
            terms.isEmpty ? nil : (title: "Forget All…", action: { isConfirmingForgetAll = true })
        SettingsGroup(title: "Terms", headerAction: forgetAll) {
            if terms.isEmpty {
                SettingsGroupRow {
                    Text("No terms yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                if let sentTermsTokens {
                    SettingsFieldRow(title: "Polish prompt", status: sentTermsTokens) {
                        EmptyView()
                    }
                }
                if terms.count > ProjectsPane.searchAbove {
                    SettingsGroupRow {
                        TextField("Search \(terms.count) terms", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("projects.terms.search")
                    }
                }
                let shown = ProjectsPane.shown(terms, query: query)
                if shown.isEmpty {
                    SettingsGroupRow {
                        Text("No term matches.")
                            .foregroundStyle(.secondary)
                    }
                } else if shown.count > Self.scrollAbove {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown, id: \.term) { row($0) }
                        }
                    }
                    .frame(height: Self.listHeight)
                    .accessibilityIdentifier("projects.terms.list")
                } else {
                    ForEach(shown, id: \.term) { row($0) }
                }
            }
        }
        .task(id: sentTerms) {
            guard let tokenCounter else { return }
            sentTermsTokens = await tokenCounter.count(PolishPromptParts.projectTermText(sentTerms), termList: true)
                .map(PolishPromptTokenText.projectTerms)
        }
        .confirmationDialog(
            "Forget all \(terms.count) terms of this project?", isPresented: $isConfirmingForgetAll
        ) {
            Button("Forget All", role: .destructive) {
                store?.forgetTerms(projectKeys: keys)
            }
        } message: {
            Text("Polishing stops using them until it learns them again.")
        }
    }

    private var canPin: Bool {
        guard let store else { return false }
        let terms = store.snapshot()
        return keys.contains { terms.canPin(projectKey: $0) }
    }

    /// The terms a dictation may send: the confirmed ones.
    private var sentTerms: [String] {
        terms.filter { $0.isConfirmed(minimumDictations: LearnedTerms.confirmedDictations) }.map(\.term)
    }

    private func row(_ term: LearnedTerm) -> some View {
        SettingsGroupRow {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(term.term)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Self.detail(for: term)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store?.setPinned(!term.isPinned, term: term.term, projectKeys: keys)
                } label: {
                    Image(systemName: term.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                // Pinned projects are never evicted, so their number is
                // capped where a pin would add one (#989).
                .disabled(!term.isPinned && !canPin)
                .help(!term.isPinned && !canPin
                    ? "\(LearnedTerms.maxProjects) projects already hold pins or a chosen repository." : "")
                .accessibilityLabel(term.isPinned ? "Unpin \(term.term)" : "Pin \(term.term)")
                Button {
                    store?.forget(term.term, projectKeys: keys)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Forget \(term.term)")
            }
        }
    }

    private static func detail(for term: LearnedTerm) -> Text {
        let parts = ProjectsPane.detail(for: term)
        guard let lastApplied = parts.lastApplied else { return Text(parts.text) }
        return Text("\(parts.text) \(lastApplied, format: .relative(presentation: .named))")
    }
}

/// The repositories the user ignored (#1006), collapsed at the bottom of
/// Projects, each with Un-ignore. Shown once there is one, or while
/// `ignored-projects.json` could not be read or written.
struct IgnoredProjectsGroup: View {
    let store: LearnedTermStore
    /// Read so the group redraws when the store changes.
    let revision: Int
    @State private var isExpanded: Bool

    init(store: LearnedTermStore, revision: Int, expanded: Bool = false) {
        self.store = store
        self.revision = revision
        _isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        let ignored = store.snapshot().ignored.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let problem = store.ignoredListProblem {
            SettingsGroup(title: "Ignored") {
                StoredFileProblemRow(problem: problem, fileName: LearnedTermStore.ignoredFileName) {
                    _ = try await store.moveIgnoredListAsideAndStartOver()
                }
            }
        } else if !ignored.isEmpty || store.ignoredListUnsaved {
            SettingsGroup(
                title: "Ignored",
                headerAction: (title: isExpanded ? "Hide" : "Show", action: { isExpanded.toggle() })
            ) {
                if isExpanded {
                    if store.ignoredListUnsaved { unsavedRow }
                    ForEach(ignored, id: \.key) { project in
                        SettingsGroupRow {
                            HStack(spacing: 10) {
                                Text(project.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Un-ignore") { store.unignoreProject(key: project.key) }
                                    .accessibilityIdentifier("projects.unignore")
                            }
                        }
                    }
                } else {
                    if store.ignoredListUnsaved { unsavedRow }
                    if !ignored.isEmpty {
                        SettingsGroupRow {
                            Text(ignored.count == 1 ? "1 project" : "\(ignored.count) projects")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("projects.ignored")
        }
    }

    /// `ignored-projects.json` could not be written: the store keeps the
    /// change and tries again at its next write (#1006).
    private var unsavedRow: some View {
        SettingsGroupRow {
            Text("Not saved yet. Retried at the next change.")
                .foregroundStyle(.red)
                .accessibilityIdentifier("projects.ignored.unsaved")
        }
    }
}
