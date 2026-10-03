import AppKit
import Foundation
import Observation

/// What the History pane shows and does. The pane is a drawing of this.
@MainActor
@Observable
final class DictationHistoryModel {
    static let pageSize = 100

    private(set) var entries: [DictationHistoryEntry] = []
    /// Dictations in the store, whatever the search says.
    private(set) var totalCount = 0
    /// Whether the store holds more matches than `entries` shows.
    private(set) var hasMore = false
    private(set) var hasLoaded = false
    /// Shown in place of the dictations when the store did not open or
    /// failed to answer (#985). An empty list would read as "no history".
    private(set) var unavailableText: String?
    /// Recordings on disk and their size, for the Storage group. Nil until
    /// the first read lands, and after one fails: not known is not zero, and
    /// zero is what lets a switch delete without asking (#1166).
    private(set) var audioSummary: (recordings: Int, bytes: Int)?
    private(set) var diagnosticRecordSummary: (records: Int, bytes: Int)?
    /// Which backups hold something. Nil until the first read lands, and
    /// after one fails; nil offers no backups to delete.
    private(set) var backupsSummary: DictationHistoryBackupsSummary?

    var searchText = ""
    var filter = DictationHistoryQuery.Filter.all
    /// Set when another pane opens History on the dictations it counted over
    /// a period; the pane shows it as a row the user can clear.
    var since: Date?
    /// The row showing its whole text, its transcript and its actions.
    var expandedEntryID: UUID?

    @ObservationIgnored private var limit = pageSize
    /// The search and filter `limit` was grown under. A different one starts
    /// from the first page; a store write under the same one keeps the pages
    /// the user asked for.
    @ObservationIgnored private var pagedQuery = DictationHistoryQuery()
    /// A slow read must not overwrite the result of the one started after it.
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private let store: @MainActor () -> DictationSessionStore?
    @ObservationIgnored private let unavailable: @MainActor () -> String?
    @ObservationIgnored private let copyToPasteboard: @MainActor (String) -> Void
    @ObservationIgnored private let appName: @MainActor (String) -> String?
    @ObservationIgnored private var appNames: [String: String?] = [:]

    init(
        store: @escaping @MainActor () -> DictationSessionStore?,
        unavailable: @escaping @MainActor () -> String? = { nil },
        copyToPasteboard: @escaping @MainActor (String) -> Void = DictationHistoryModel.systemCopy,
        appName: @escaping @MainActor (String) -> String? = DictationHistoryModel.installedAppName
    ) {
        self.store = store
        self.unavailable = unavailable
        self.copyToPasteboard = copyToPasteboard
        self.appName = appName
    }

    convenience init(viewModel: DictationViewModel) {
        self.init(
            store: { [weak viewModel] in viewModel?.sessionStore },
            unavailable: { [weak viewModel] in viewModel?.historyUnavailableText })
    }

    var isFiltering: Bool {
        filter != .all || since != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        guard let store = store() else {
            entries = []
            totalCount = 0
            hasMore = false
            hasLoaded = true
            unavailableText = unavailable()
            return
        }
        var query = DictationHistoryQuery()
        query.searchText = searchText
        query.filter = filter
        query.since = since
        if query != pagedQuery {
            pagedQuery = query
            limit = Self.pageSize
        }
        // One more than shown is how "Show more" knows it has something.
        query.limit = limit + 1
        let fetched = await store.entries(matching: query)
        let count = await store.count()
        guard generation == reloadGeneration else { return }
        entries = Array(fetched.prefix(limit))
        hasMore = fetched.count > limit
        totalCount = count
        hasLoaded = true
        unavailableText = unavailable()
        if let expandedEntryID, !entries.contains(where: { $0.id == expandedEntryID }) {
            self.expandedEntryID = nil
        }
    }

    func reloadStorageSummary() async {
        audioSummary = await store()?.audioSummary()
        diagnosticRecordSummary = await store()?.diagnosticRecordSummary()
        backupsSummary = await store()?.backupsSummary()
    }

    /// Whether switching "Keep dictation audio" off asks before deleting.
    /// Only a count known to be zero turns it off at once, and only when
    /// no quarantined recording is left to offer (#1574).
    var turningAudioOffAsksFirst: Bool {
        (audioSummary.map { $0.recordings > 0 } ?? true) || backupsSummary?.audio == true
    }

    /// Whether switching "Keep diagnostic records" off asks before deleting,
    /// by the audio switch's rule.
    var turningRecordsOffAsksFirst: Bool {
        (diagnosticRecordSummary.map { $0.records > 0 } ?? true) || backupsSummary?.diagnosticRecords == true
    }

    /// Delete All stays available while backups hold something, so an empty
    /// History can still delete them (#1574).
    var canDeleteAll: Bool { totalCount > 0 || backupsSummary?.holdsAnything == true }

    /// Whether Don't keep asks when it deletes no dictation: only to offer
    /// the backups.
    var dontKeepAsksWithNothingToDelete: Bool { backupsSummary?.holdsAnything == true }

    func showMore() async {
        limit += Self.pageSize
        await reload()
    }

    func toggleExpanded(_ entry: DictationHistoryEntry) {
        expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
    }

    func copyFinalText(of entry: DictationHistoryEntry) {
        copyToPasteboard(entry.finalText)
    }

    func copyTranscript(of entry: DictationHistoryEntry) {
        copyToPasteboard(entry.rawText)
    }

    func delete(_ entry: DictationHistoryEntry) async {
        // Gone from the list before the store answers: the row the user
        // deleted must not sit there for a frame.
        entries.removeAll { $0.id == entry.id }
        store()?.delete(id: entry.id)
        await reload()
    }

    func deleteAll(removingBackups: Bool) async {
        entries = []
        store()?.deleteAll(removingBackups: removingBackups)
        await reload()
        // Delete All of an empty History changes no row, so nothing else
        // reloads what the backups hold.
        await reloadStorageSummary()
    }

    /// How many dictations `retention` would delete if it applied at `now`.
    /// Nil when the store could not count them.
    func countDeleted(by retention: DictationHistoryRetention, now: Date) async -> Int? {
        guard let cutoff = retention.cutoff(now: now) else { return 0 }
        guard let store = store() else { return 0 }
        return await store.count(olderThan: cutoff)
    }

    /// The target app's name, or nil when the dictation recorded none or the
    /// app is no longer installed. LaunchServices is asked once per bundle id.
    func targetAppName(for entry: DictationHistoryEntry) -> String? {
        guard let bundleID = entry.targetAppBundleID, !bundleID.isEmpty else { return nil }
        if let known = appNames[bundleID] { return known }
        let name = appName(bundleID)
        appNames[bundleID] = name
        return name
    }

    static func systemCopy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func installedAppName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// The words on a History row that are derived rather than stored.
enum DictationHistoryRowText {
    /// "Today 14:32", "Yesterday 09:05", then a date. `now`, the calendar and
    /// the locale are arguments so a test pins all three.
    static func timestamp(
        for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        let clock = date.formatted(time)

        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0
        switch daysAgo {
        case 0: return "Today \(clock)"
        case 1: return "Yesterday \(clock)"
        default:
            var day = Date.FormatStyle(date: .abbreviated, time: .omitted)
            day.locale = locale
            day.calendar = calendar
            day.timeZone = calendar.timeZone
            return "\(date.formatted(day)) \(clock)"
        }
    }

    /// What changed the transcript, or nil when nothing did. "Polished" is
    /// kept for a model; the replacement dictionary and the clipboard marker
    /// change text with polishing off.
    static func change(for entry: DictationHistoryEntry) -> String? {
        guard entry.textWasChanged else { return nil }
        return entry.polishRan ? "Polished" : "Edited"
    }

    /// What went wrong with the dictation, or nil when nothing did. One of
    /// these is why the row is worth finding again.
    static func problem(for entry: DictationHistoryEntry) -> String? {
        if !entry.commitSucceeded { return "Not inserted" }
        if entry.status == .llmFailed { return "Polish failed" }
        return nil
    }

    /// The model and timing line of an expanded row.
    static func details(for entry: DictationHistoryEntry) -> String {
        var parts = [entry.model]
        if let seconds = entry.polishingDurationSeconds {
            parts.append("polish \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
        }
        if entry.polishProfile == PolishPromptProfile.agent.rawValue {
            parts.append("agent")
        }
        if let tokens = entry.polishPromptTokens {
            parts.append("\(tokens.formatted()) prompt tokens")
        }
        return parts.joined(separator: " · ")
    }
}
