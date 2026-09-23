import Foundation

/// One replacement-dictionary entry: the exact spelling and the spoken forms
/// it replaces.
package struct ReplacementEntry: Equatable, Sendable {
    package let replaceWith: String
    package let matches: [String]

    package init(replaceWith: String, matches: [String]) {
        self.replaceWith = replaceWith
        self.matches = matches
    }
}
