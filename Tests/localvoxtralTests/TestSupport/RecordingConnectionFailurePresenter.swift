import Foundation
@testable import localvoxtral

/// Keeps every failure the view model asked to show, and shows nothing.
@MainActor
final class RecordingConnectionFailurePresenter: ConnectionFailurePresenting {
    struct Failure: Equatable {
        let title: String
        let message: String
        let technicalDetails: String?
    }

    private(set) var presented: [Failure] = []

    func present(title: String, message: String, technicalDetails: String?) {
        presented.append(Failure(title: title, message: message, technicalDetails: technicalDetails))
    }
}
