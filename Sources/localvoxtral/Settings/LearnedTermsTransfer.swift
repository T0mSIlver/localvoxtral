import AppKit
import UniformTypeIdentifiers

/// Text Processing's Import… and Export… (#523): every learned term to or
/// from a file, to move them between machines. Each reports one short line
/// for the row's status.
@MainActor
enum LearnedTermsTransfer {
    static func exportTerms(from store: LearnedTermStore?, report: @escaping @MainActor (String?) -> Void) {
        report(nil)
        guard let store else { return }
        let data: Data
        do {
            data = try LearnedTermsExport.data(for: store.snapshot(), exportedAt: Date())
        } catch {
            Log.persistence.error(
                "learned terms: export encode failed: \(error.localizedDescription, privacy: .public)"
            )
            report("Could not export the terms.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export learned terms"
        panel.nameFieldStringValue = LearnedTermsExport.defaultFileName
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            // Off the main actor: the destination can be a network volume.
            let saved = await Task.detached(priority: .userInitiated) {
                do {
                    try data.write(to: url, options: .atomic)
                    Log.persistence.info("learned terms: exported \(data.count, privacy: .public) bytes")
                    return true
                } catch {
                    Log.persistence.error(
                        "learned terms: export write failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return false
                }
            }.value
            report(saved ? "Exported." : "Could not save the file.")
        }
    }

    static func importTerms(into store: LearnedTermStore?, report: @escaping @MainActor (String?) -> Void) {
        report(nil)
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.title = "Import learned terms"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let read = await Task.detached(priority: .userInitiated) {
                Result { try LearnedTermsExport.projects(from: Data(contentsOf: url)) }
            }.value
            switch read {
            case .failure(let error):
                Log.persistence.error(
                    "learned terms: import refused: \(String(describing: error), privacy: .public)"
                )
                report(importRefusal(error))
            case .success(let projects):
                let summary = await withCheckedContinuation { continuation in
                    store.importProjects(projects) { continuation.resume(returning: $0) }
                }
                report(importResult(summary))
            }
        }
    }

    private static func importResult(_ summary: LearnedTermsExport.ImportSummary) -> String {
        switch (summary.terms, summary.projects) {
        case (0, _): "No terms to import."
        case (1, _): "Imported 1 term."
        case (let terms, 1): "Imported \(terms) terms."
        case (let terms, let projects): "Imported \(terms) terms in \(projects) projects."
        }
    }

    private static func importRefusal(_ error: any Error) -> String {
        switch error as? LearnedTermsExport.ImportError {
        case .newerVersion: "Made by a newer version of localvoxtral."
        case .unreadable: "Not a learned terms file."
        case nil: "Could not read the file."
        }
    }
}
