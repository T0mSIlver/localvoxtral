import Foundation

struct BackendProcessConfiguration: Sendable {
    var name: String
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var readinessURL: URL
    var readinessPollInterval: Duration = .milliseconds(500)
    var readinessTimeout: Duration = .seconds(600)
    var terminationGracePeriod: Duration = .seconds(5)
    var maxConsecutiveRestartFailures: Int = 5
}
