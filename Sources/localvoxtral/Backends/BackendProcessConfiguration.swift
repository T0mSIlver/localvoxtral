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
    /// How long a helper must stay ready before its next crash counts as the
    /// first of a new run rather than one more consecutive failure.
    var healthyRunDuration: Duration = .seconds(60)
    /// The helper's readiness response names its pid. Readiness then also
    /// requires that pid to be the supervised child's: another process that
    /// binds the port while the child loads must not pass for it (#1760).
    var readinessReportsOwnerPID = false
}
