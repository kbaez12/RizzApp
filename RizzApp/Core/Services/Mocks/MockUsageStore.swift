import Foundation
import Observation

/// In-memory quota tracker for Phase 2. All quota arithmetic lives here —
/// never in views. NOT production enforcement; the backend becomes the
/// authoritative source in Phase 6.
@Observable
final class MockUsageStore: UsageServicing {
    struct Config {
        var freeLifetimeLimit = 5
        /// Configurable server-side later; approximate initial Plus allowance.
        var plusMonthlyAllowance = 150
        var freeRefinementsPerAnalysis = 2
    }

    private let config: Config
    private(set) var tier: UsageStatus.Tier = .free
    private var analysesUsed = 0
    private var refinementsUsedThisAnalysis = 0

    init(config: Config = Config()) {
        self.config = config
    }

    private var limit: Int {
        tier == .plus ? config.plusMonthlyAllowance : config.freeLifetimeLimit
    }

    var status: UsageStatus {
        UsageStatus(
            remaining: max(0, limit - analysesUsed),
            limit: limit,
            tier: tier,
            refinementsRemaining: max(0, config.freeRefinementsPerAnalysis - refinementsUsedThisAnalysis)
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
        refinementsUsedThisAnalysis < config.freeRefinementsPerAnalysis || canStartFullGeneration()
    }

    func consumeRefinement() {
        if refinementsUsedThisAnalysis < config.freeRefinementsPerAnalysis {
            refinementsUsedThisAnalysis += 1
        } else {
            // Free refinement budget exhausted — this costs a full generation
            // and starts a fresh refinement budget for the new result set.
            consumeFullGeneration()
        }
    }

    /// Test/dev helper — flips to Plus. Real entitlement arrives in Phase 7.
    func upgradeToPlus() {
        tier = .plus
    }
}
