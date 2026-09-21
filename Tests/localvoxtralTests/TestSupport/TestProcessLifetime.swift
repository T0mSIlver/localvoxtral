import XCTest
@testable import localvoxtral

@MainActor
private var retainedForTestProcessLifetime: [AnyObject] = []

extension XCTestCase {
    /// `DictationViewModel` owns app-lifetime services, so a test instance is
    /// kept for the life of the process: releasing it at teardown races the
    /// services' shutdown, and the connect-timeout a session arms (AGENTS.md)
    /// fires on whatever test runs ten seconds later.
    @MainActor
    func retainForTestProcessLifetime(_ viewModel: DictationViewModel) {
        retainedForTestProcessLifetime.append(viewModel)
    }
}
