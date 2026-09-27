import SwiftUI

/// One line per project quick capture can route to (#811): what the project
/// is and what it has. Each field starts filled (#891) with the line the
/// project's agent wrote, else its README summary, which is what the router
/// reads. An edit becomes the user's line and replaces the agent's; an
/// emptied field, or one set back to that text, returns to it.
struct QuickCaptureProjectLinesSheet: View {
    @Bindable var settings: SettingsStore
    let projects: [QuickCaptureProject]
    let onDone: () -> Void

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
        .frame(width: 620, height: 420)
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
