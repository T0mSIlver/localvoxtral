import Foundation

/// How often the hosted "Suggest terms" pass runs by itself, in saved
/// dictations (`TermSuggestionCadence`). `never` leaves only the button.
enum TermSuggestionInterval: Int, CaseIterable, Identifiable, Sendable {
    case every25 = 25
    case every50 = 50
    case every100 = 100
    case every200 = 200
    case never = 0

    var id: Int { rawValue }

    /// Nil for `never`.
    var dictations: Int? { self == .never ? nil : rawValue }

    var displayName: String {
        dictations.map { "Every \($0) dictations" } ?? "Never"
    }
}
