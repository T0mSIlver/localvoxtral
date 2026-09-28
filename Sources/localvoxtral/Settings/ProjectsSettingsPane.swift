import ClaudeContextWire
import SwiftUI

/// Every project quick capture lists, one table row each (#939): where its
/// issues go, where it is checked out, when it was last used and the drafts
/// waiting on it. A row opens the project's sheet. The terms outside every
/// project close the table as "No project" (#972), so this pane is the one
/// place learned terms are seen, pinned and forgotten.
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

    enum OpenProject: Identifiable, Hashable {
        case project(key: String)
        case unlisted

        var id: Self { self }
    }

    private var rows: [ProjectsPaneRow] {
        _ = viewModel.learnedTermRevision
        return inbox?.projectRows(dictationProjectKeys: dictationProjectKeys) ?? []
    }

    var body: some View {
        let rows = rows
        let unlisted = inbox?.unlistedTerms()
        SettingsPage(tab: .projects) {
            SettingsGroup(title: "Projects", learnMoreURL: ProjectsLearnMore.projects) {
                if rows.isEmpty && unlisted == nil {
                    SettingsGroupRow {
                        Text("No projects. A project appears once you dictate into a coding agent there.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SettingsGroupRow {
                        ProjectsTableColumns(
                            name: Text("Project"), filing: Text("Files issues in"), checkouts: Text("Checkouts"),
                            lastUsed: Text("Last used"), drafts: Text("Drafts")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        Button {
                            openProject = .project(key: row.key)
                        } label: {
                            SettingsGroupRow {
                                ProjectsTableColumns(
                                    name: Text(row.name).fontWeight(.semibold),
                                    filing: ProjectsFilingText(filing: row.filing),
                                    checkouts: Text(row.checkouts()).foregroundStyle(.secondary),
                                    lastUsed: Text(ProjectsPane.lastUsed(row.lastUsed, now: Date()))
                                        .foregroundStyle(.secondary),
                                    drafts: Text(row.draftsWaiting == 0 ? "–" : "\(row.draftsWaiting)")
                                        .foregroundStyle(.secondary)
                                )
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("projects.row")
                    }
                    if let unlisted {
                        Button {
                            openProject = .unlisted
                        } label: {
                            SettingsGroupRow {
                                ProjectsTableColumns(
                                    name: Text(LearnedTermProjectResolver.shared.name).fontWeight(.semibold),
                                    filing: Text("–").foregroundStyle(.secondary),
                                    checkouts: Text("–").foregroundStyle(.secondary),
                                    lastUsed: Text(ProjectsPane.lastUsed(unlisted.lastUsed, now: Date()))
                                        .foregroundStyle(.secondary),
                                    drafts: Text("–").foregroundStyle(.secondary)
                                )
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("projects.noProject")
                    }
                }
            }
        }
        .sheet(item: $openProject) { open in
            switch open {
            case .project(let key):
                projectSheet(key)
            case .unlisted:
                UnlistedTermsSheet(viewModel: viewModel, inbox: inbox) {
                    openProject = nil
                }
            }
        }
        .task {
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
}

/// The table's five columns, the header's and each row's alike.
private struct ProjectsTableColumns<Name: View, Filing: View, Checkouts: View, LastUsed: View, Drafts: View>: View {
    let name: Name
    let filing: Filing
    let checkouts: Checkouts
    let lastUsed: LastUsed
    let drafts: Drafts

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            name.frame(width: 120, alignment: .leading)
            filing.frame(maxWidth: .infinity, alignment: .leading)
            checkouts.frame(width: 104, alignment: .leading)
            lastUsed.frame(width: 70, alignment: .leading)
            drafts.frame(width: 40, alignment: .trailing)
        }
        .lineLimit(2)
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

    @State private var isEditingRepository = false
    @State private var repositoryDraft = ""
    @State private var isEditingDescription = false
    @State private var descriptionDraft = ""
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
                        ProjectTermsGroup(terms: row.terms, keys: row.keys, store: viewModel.learnedTermStore)
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
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 640)
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
                    terms: unlisted?.terms ?? [], keys: unlisted?.keys ?? [], store: viewModel.learnedTermStore)
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
    @State private var query = ""
    @State private var isConfirmingForgetAll = false

    /// More terms than this and a search field leads the list.
    static let searchAbove = 12
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
                if terms.count > Self.searchAbove {
                    SettingsGroupRow {
                        TextField("Search \(terms.count) terms", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("projects.terms.search")
                    }
                }
                let shown = ProjectsPane.matching(terms, query: query)
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
