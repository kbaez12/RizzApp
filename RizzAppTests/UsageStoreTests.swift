import XCTest
@testable import RizzApp

/// Quota arithmetic for the mock usage store: 5 lifetime free analyses,
/// 2 free refinements per analysis, configurable Plus allowance.
final class UsageStoreTests: XCTestCase {
    func testFreeTierStartsWithFiveAnalyses() {
        let store = MockUsageStore()
        XCTAssertEqual(store.status.remaining, 5)
        XCTAssertEqual(store.status.limit, 5)
        XCTAssertEqual(store.status.tier, .free)
        XCTAssertTrue(store.canStartFullGeneration())
    }

    func testFullGenerationsExhaust() {
        let store = MockUsageStore()
        for _ in 0..<5 { store.consumeFullGeneration() }
        XCTAssertEqual(store.status.remaining, 0)
        XCTAssertFalse(store.canStartFullGeneration())
    }

    func testTwoFreeRefinementsThenFullGenerationCharged() {
        let store = MockUsageStore()
        store.consumeFullGeneration() // start analysis: 4 remaining, 2 refinements

        store.consumeRefinement()
        store.consumeRefinement()
        XCTAssertEqual(store.status.remaining, 4, "Free refinements must not charge analyses")
        XCTAssertEqual(store.status.refinementsRemaining, 0)

        store.consumeRefinement() // third refinement costs a full generation
        XCTAssertEqual(store.status.remaining, 3)
        XCTAssertEqual(store.status.refinementsRemaining, 2, "New analysis resets refinement budget")
    }

    func testRefinementBudgetResetsOnNewGeneration() {
        let store = MockUsageStore()
        store.consumeFullGeneration()
        store.consumeRefinement()
        XCTAssertEqual(store.status.refinementsRemaining, 1)

        store.consumeFullGeneration() // e.g. "Generate 3 More"
        XCTAssertEqual(store.status.refinementsRemaining, 2)
    }

    func testCanRefineFallsBackToFullGenerationAvailability() {
        let store = MockUsageStore(config: .init(freeLifetimeLimit: 1))
        store.consumeFullGeneration() // uses the only analysis
        store.consumeRefinement()
        store.consumeRefinement()     // free budget now exhausted
        XCTAssertFalse(store.canStartFullGeneration())
        XCTAssertFalse(store.canRefine(), "No free refinements and no analyses left")
    }

    func testPlusAllowanceIsConfigurable() {
        let store = MockUsageStore(config: .init(plusMonthlyAllowance: 150))
        store.upgradeToPlus()
        XCTAssertEqual(store.status.limit, 150)
        XCTAssertEqual(store.status.tier, .plus)
    }
}
