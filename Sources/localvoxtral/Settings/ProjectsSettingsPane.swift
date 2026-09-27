import ClaudeContextWire
import SwiftUI

/// Every project quick capture lists, one table row each (#939): where its
/// issues go, where it is checked out, when it was last used and the drafts
/// waiting on it. A row opens the project's sheet.
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

    struct OpenProject: Identifiable {
        let id: String
    }

    private var rows: [ProjectsPaneRow] {
        _ = viewModel.learnedTermRevision
        return inbox?.projectRows(dictationProjectKeys: dictationProjectKeys) ?? []
    }

    var body: some View {
        let rows = rows
        SettingsPage(tab: .projects) {
            SettingsGroup(title: "Projects", learnMoreURL: ProjectsLearnMore.projects) {
                if rows.isEmpty {
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
                            openProject = OpenProject(id: row.key)
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
                }
            }
        }
        .sheet(item: $openProject) { open in
            ProjectDetailSheet(
                projectKey: open.id,
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
        .task {
            if let store = viewModel.sessionStore {
                let entries = await store.entries(since: Date().addingTimeInterval(-7 * 86_400))
                dictationProjectKeys = entries.map(\.projectKey)
            }
            await inbox?.refreshProjects(force: true)
        }
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
    @State private var isShowingTerms = false

    /// Chips shown before Show all.
    private static let visibleTerms = 12

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
                        termsGroup(row)
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
        .sheet(isPresented: $isShowingTerms) {
            LearnedTermsSheet(viewModel: viewModel, project: row.map { ($0.name, $0.keys) }) {
                isShowingTerms = false
            }
        }
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

    // MARK: Terms

    private func termsGroup(_ row: ProjectsPaneRow) -> some View {
        let showAll: (title: String, action: () -> Void)? =
            row.terms.isEmpty ? nil : (title: "Show all \(row.terms.count)", action: { isShowingTerms = true })
        return SettingsGroup(title: "Terms", headerAction: showAll) {
            SettingsGroupRow {
                if row.terms.isEmpty {
                    Text("No terms yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ProjectTermChips(terms: Array(row.terms.prefix(Self.visibleTerms)))
                }
            }
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

/// A project's terms as chips that wrap.
private struct ProjectTermChips: View {
    let terms: [String]

    var body: some View {
        ProjectChipFlow(spacing: 6) {
            ForEach(terms, id: \.self) { term in
                Text(term)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }
}

/// Lays its children left to right and wraps them onto new lines.
private struct ProjectChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, extra > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
