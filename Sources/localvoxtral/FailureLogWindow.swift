import AppKit
import ClaudeContextWire
import SwiftUI

/// The log categories that tell a failure's story. Deltas and Insertion,
/// which can hold dictated text, are in neither.
enum ConnectionFailureLog: Equatable, Sendable {
    case realtime
    case polishing

    var categories: [String] {
        switch self {
        case .realtime: ["Dictation", "Realtime", "MlxRealtime", "Backends"]
        case .polishing: ["Polishing", "Backends"]
        }
    }
}

/// What the Show Log window shows: the failure's technical details, then
/// the app's recent lines in the failure's categories, read with `log show`
/// as `localvoxtral logs` reads them, so a private value stays `<private>`.
@MainActor
@Observable
final class FailureLogModel {
    enum Lines: Equatable {
        case loading
        case loaded(String)
        case unreadable(String)
    }

    let details: String?
    private(set) var lines: Lines = .loading

    init(details: String?, lines: Lines = .loading) {
        self.details = details
        self.lines = lines
    }

    /// The text the Copy button puts on the clipboard.
    var copyText: String {
        var parts: [String] = []
        if let details { parts.append(details) }
        switch lines {
        case .loaded(let text): parts.append(text)
        case .unreadable(let sentence): parts.append(sentence)
        case .loading: break
        }
        return parts.joined(separator: "\n\n")
    }

    /// Reads the last `AgentCLIFailureLogQuery.defaultWindow` before `now`.
    /// `readLog` blocks until `log` exits, so it runs off the main actor.
    func load(
        _ log: ConnectionFailureLog,
        now: Date,
        timeZone: TimeZone = .current,
        readLog: @escaping @Sendable ([String]) -> Result<Data, AgentCLILogsReadFailure> = AgentCLILogs.readWithLogShow
    ) async {
        let query = AgentCLIFailureLogQuery(
            categories: log.categories, since: now.addingTimeInterval(-AgentCLIFailureLogQuery.defaultWindow))
        Log.backends.notice("Show Log: reading categories \(log.categories.joined(separator: ","), privacy: .public)")
        let result = await Task.detached {
            AgentCLILogs.failureLog(query, timeZone: timeZone, readLog: readLog)
        }.value
        switch result {
        case .success(let text):
            lines = .loaded(text)
        case .failure(let failure):
            Log.backends.error("Show Log: could not read the log: \(failure.message, privacy: .public)")
            lines = .unreadable("Could not read the log: \(failure.message).")
        }
    }
}

struct FailureLogView: View {
    let model: FailureLogModel
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let details = model.details {
                Text(details)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                switch model.lines {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let text):
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    // Newest lines last, so the failure is in view on open.
                    .defaultScrollAnchor(.bottom)
                case .unreadable(let sentence):
                    Text(sentence)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.copyText, forType: .string)
                }
                .disabled(model.lines == .loading)
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 360)
    }
}

/// Owns the one Show Log window; a second Show Log replaces its content.
@MainActor
final class FailureLogWindowController {
    private var window: NSWindow?

    func show(_ log: ConnectionFailureLog, details: String?) {
        let model = FailureLogModel(details: details)
        let view = FailureLogView(model: model) { [weak self] in self?.window?.close() }
        let window = window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "localvoxtral Log"
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        window.contentViewController = NSHostingController(rootView: view)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { await model.load(log, now: Date()) }
    }
}
