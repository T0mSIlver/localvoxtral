import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

/// The Insights pane's model: it reads the ledger, so it stays with the app.
final class DictationInsightsModelTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    /// Usage by feature sums the ledger over the period the pane's picker
    /// selects, and lists only the features that made a call in it.
    @MainActor
    func testUsageByFeatureFollowsThePeriod() async throws {
        let defaults = makeTestDefaults()
        let ledger = [
            UsageEntry(date: origin.addingTimeInterval(-3_600), feature: .polish, backend: .mistral,
                       model: "m", costEUR: 0.01),
            UsageEntry(date: origin.addingTimeInterval(-10 * 86_400), feature: .polish, backend: .bundledHelper,
                       model: "m"),
            UsageEntry(date: origin.addingTimeInterval(-10 * 86_400), feature: .quickCaptureDrafting,
                       backend: .claudeCode, model: "sonnet", agentCostUSD: 0.1),
        ]
        let model = DictationInsightsModel(
            defaults: defaults, store: { nil }, terms: { [] }, usage: { ledger })

        model.period = .week
        model.reloadUsage(now: origin)
        XCTAssertEqual(model.featureUsage.map(\.feature), [.polish])
        XCTAssertEqual(model.featureUsage.first?.calls, 1)

        model.period = .month
        model.reloadUsage(now: origin)
        XCTAssertEqual(model.featureUsage.map(\.feature), [.polish, .quickCaptureDrafting])
        XCTAssertEqual(model.featureUsage.first?.calls, 2)
    }
}
