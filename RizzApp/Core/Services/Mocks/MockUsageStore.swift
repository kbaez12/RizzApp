import Foundation
import Observation

/// In-memory subscriber allowance tracker for previews and tests. Production
/// enforcement always lives on the authenticated backend.
@Observable
final class MockUsageStore: UsageServicing {
    struct Config {
        var monthlyAllowance = 150
        var includedRefinementsPerAnalysis = 2
    }

    private let config: Config
    private(set) var tier: UsageStatus.Tier
    private var analysesUsed = 0
    private var refinementsUsedThisAnalysis = 0

    init(config: Config = Config(), isSubscribed: Bool = true) {
        self.config = config
        tier = isSubscribed ? .plus : .free
    }

    private var limit: Int {
        tier == .plus ? config.monthlyAllowance : 0
    }

    var status: UsageStatus {
        UsageStatus(
            remaining: max(0, limit - analysesUsed),
            limit: limit,
            tier: tier,
            refinementsRemaining: tier == .plus
                ? max(0, config.includedRefinementsPerAnalysis - refinementsUsedThisAnalysis)
                : 0
        )
    }

    func canStartFullGeneration() -> Bool {
        analysesUsed < limit
    }

    func consumeFullGeneration() {
        analysesUsed += 1
        refinementsUsedThisAnalysis = 0
    }

    func canRefine() -> Bool {
        tier == .plus &&
            (refinementsUsedThisAnalysis < config.includedRefinementsPerAnalysis ||
             canStartFullGeneration())
    }

    func consumeRefinement() {
        if refinementsUsedThisAnalysis < config.includedRefinementsPerAnalysis {
            refinementsUsedThisAnalysis += 1
        } else {
            // Included refinements exhausted: consume one full analysis and
            // start a fresh refinement budget for the new result set.
            consumeFullGeneration()
        }
    }

    /// Test helper for an initially unsubscribed store.
    func upgradeToPlus() {
        tier = .plus
    }
}
