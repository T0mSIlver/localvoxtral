import AppIntents
import AppKit
import localvoxtralCore
import notify

/// The Engines widget's button. It runs in the extension, so it reaches the
/// running app with a Darwin notification; the app turns polishing off the
/// way the Settings toggle does, then rewrites the snapshot.
struct TurnOffPolishIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Polish"
    static let description = IntentDescription("Turns off polishing in localvoxtral and frees the polish model's memory.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        let status = notify_post(WidgetShared.turnOffPolishNotification)
        if status == NOTIFY_STATUS_OK {
            Log.widgets.notice("asked the app to turn polish off")
        } else {
            Log.widgets.error("could not reach the app to turn polish off (notify status \(status, privacy: .public))")
        }
        return .result()
    }
}

/// The Last dictation widget's button: copies the text it shows.
struct CopyLastDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Last Dictation"
    static let description = IntentDescription("Copies your last dictation to the clipboard.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        guard let text = SnapshotFile.read()?.lastDictation?.text else {
            Log.widgets.notice("nothing to copy: the snapshot has no last dictation")
            return .result()
        }
        let copied = await MainActor.run {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        Log.widgets.notice("copied the last dictation: \(copied, privacy: .public)")
        return .result()
    }
}

enum DictationPeriodOption: String, AppEnum {
    case today
    case last7Days
    case last30Days

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [DictationPeriodOption: DisplayRepresentation] = [
        .today: "Today",
        .last7Days: "Last 7 days",
        .last30Days: "Last 30 days",
    ]

    var period: DictationWidgetPeriod {
        switch self {
        case .today: return .today
        case .last7Days: return .last7Days
        case .last30Days: return .last30Days
        }
    }
}

/// Edit Widget's one setting for the Dictation widget.
struct DictationPeriodIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Dictation"
    static let description = IntentDescription("Words, dictations and time saved over typing.")

    @Parameter(title: "Period", default: .today)
    var period: DictationPeriodOption
}
