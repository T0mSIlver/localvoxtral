import SwiftUI

/// One line per project quick capture can route to (#811): what the project
/// is and what it has. Each field starts filled (#891, #926) with GitHub's
/// description, else the line the project's agent wrote, else its README
/// summary, which is what the router reads. An edit becomes the user's line
/// and replaces them; an emptied field, or one set back to that text,
/// returns to it. A fork picks where File sends its issues.
///
/// Opening it asks GitHub again for every project's description.
struct QuickCaptureProjectLinesSheet: View {
    @Bindable var settings: SettingsStore
    let inbox: QuickCaptureInboxViewModel?
    let onDone: () -> Void

    private var projects: [QuickCaptureProject] {
        guard let inbox else { return [] }
        _ = inbox.projectsRevision
        return inbox.model.projectChoices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project descriptions")
                .font(.headline)
            if projects.isEmpty {
                Text("No projects. A project appears once you dictate into a coding agent there.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(projects, id: \.key) { project in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(project.name)
                            .frame(width: 140, alignment: .leading)
                            .lineLimit(1)
                        TextField(
                            "What it is and what it has",
                            text: line(for: project),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        if let fork = project.repository, let upstream = project.github?.parent {
                            Picker("File issues here", selection: filesUpstream(for: project, fork: fork)) {
                                Text("Issues in \(fork)").tag(false)
                                Text("Issues in \(upstream)").tag(true)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                .accessibilityIdentifier("settings.quickCaptureProjectLines.list")
            }
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 420)
        .task { await inbox?.refreshProjects(force: true) }
    }

    private func filesUpstream(for project: QuickCaptureProject, fork: String) -> Binding<Bool> {
        Binding(
            get: { project.issueRepository != fork },
            set: { upstream in Task { await inbox?.setFilesUpstream(upstream, repository: fork) } }
        )
    }

    private func line(for project: QuickCaptureProject) -> Binding<String> {
        Binding(
            get: { settings.quickCaptureProjectLines[project.key] ?? project.automaticLine ?? "" },
            set: { text in
                let isAutomatic = text.trimmingCharacters(in: .whitespacesAndNewlines) == project.automaticLine
                settings.setQuickCaptureProjectLine(isAutomatic ? "" : text, for: project.key)
            }
        )
    }
}
