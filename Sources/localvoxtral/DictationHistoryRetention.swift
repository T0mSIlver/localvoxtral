import Foundation

/// How long a saved dictation stays in the history store
/// (`DictationSessionStore`). The store holds everything the user said, in
/// plain text, so the rule is a privacy setting first and a disk one second.
enum DictationHistoryRetention: String, CaseIterable, Identifiable, Sendable {
    case forever
    case days90 = "90d"
    case days30 = "30d"
    case days7 = "7d"
    /// Nothing is saved, and what was saved is deleted.
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forever: return "Forever"
        case .days90: return "90 days"
        case .days30: return "30 days"
        case .days7: return "7 days"
        case .off: return "Don't keep"
        }
    }

    /// Nil for `forever` and `off`, which are not an age.
    var days: Int? {
        switch self {
        case .forever, .off: return nil
        case .days90: return 90
        case .days30: return 30
        case .days7: return 7
        }
    }

    var savesDictations: Bool { self != .off }

    /// Dictations that started before this are deleted. Nil keeps everything;
    /// `off` answers `.distantFuture`, which is every dictation there is.
    func cutoff(now: Date) -> Date? {
        if self == .off { return .distantFuture }
        return days.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    /// Whether moving to `other` deletes dictations this rule would keep.
    func keepsLonger(than other: DictationHistoryRetention) -> Bool {
        func reach(_ rule: DictationHistoryRetention) -> Int {
            switch rule {
            case .forever: return .max
            case .off: return 0
            default: return rule.days ?? 0
            }
        }
        return reach(self) > reach(other)
    }
}
