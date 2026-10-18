import XCTest
@testable import RizzApp

@MainActor
final class AppAccessModelTests: XCTestCase {
    func testCoreAccessRequiresSubscriptionAndPlusUsage() async {
        let subscription = AccessTestSubscription(
            result: SubscriptionStatus(isPremium: true, planName: "Monthly")
        )
        let usage = AccessTestUsage(tier: .plus)
        let model = AppAccessModel(services: services(subscription: subscription, usage: usage))

        XCTAssertEqual(model.state, .loading)
        await model.bootstrap()
        XCTAssertEqual(model.state, .subscribed)
    }

    func testInactiveSubscriberStaysAtPaywall() async {
        let subscription = AccessTestSubscription(result: .free)
        let model = AppAccessModel(
            services: services(subscription: subscription, usage: AccessTestUsage(tier: .free))
        )

        await model.bootstrap()
        XCTAssertEqual(model.state, .subscriptionRequired)
    }

    func testVerificationFailureNeverUnlocks() async {
        let subscription = AccessTestSubscription(
            result: .free,
            error: SubscriptionError.verificationUnavailable
        )
        let model = AppAccessModel(
            services: services(subscription: subscription, usage: AccessTestUsage(tier: .plus))
        )

        await model.bootstrap()
        XCTAssertEqual(model.state, .verificationUnavailable)
    }

    func testStoreEntitlementRejectedByBackendStaysClosed() async {
        let subscription = AccessTestSubscription(
            result: SubscriptionStatus(isPremium: true, planName: "Monthly"),
            error: SubscriptionError.backendNotEntitled
        )
        let model = AppAccessModel(
            services: services(subscription: subscription, usage: AccessTestUsage(tier: .free))
        )

        await model.bootstrap()
        XCTAssertEqual(model.state, .subscriptionRequired)
    }

    func testConfigurationErrorBlocksBeforeBootstrap() {
        let blocked = AppServices(
            generation: MockGenerationService(),
            analysis: MockAnalysisService(),
            usage: AccessTestUsage(tier: .free),
            subscription: AccessTestSubscription(result: .free),
            requiresSubscriptionVerification: true,
            configurationError: "Missing public configuration."
        )

        let model = AppAccessModel(services: blocked)
        XCTAssertEqual(model.state, .configurationError("Missing public configuration."))
    }

    func testPremiumAccessStaysUnavailableUntilVerificationCompletes() async {
        let subscription = SequencedSubscription()
        let model = AppAccessModel(
            services: services(subscription: subscription, usage: AccessTestUsage(tier: .plus))
        )

        XCTAssertEqual(model.state, .loading)
        let bootstrap = Task { await model.bootstrap() }
        await waitUntil { subscription.pendingCount == 1 }
        XCTAssertEqual(model.state, .loading)
        XCTAssertFalse(subscription.status.isPremium)

        await subscription.completeNext(
            .success(SubscriptionStatus(isPremium: true, planName: "Monthly"))
        )
        await bootstrap.value
        XCTAssertEqual(model.state, .subscribed)
    }

    func testOlderBootstrapResultCannotRestoreAccessAfterIdentityChange() async {
        let subscription = SequencedSubscription()
        let model = AppAccessModel(
            services: services(subscription: subscription, usage: AccessTestUsage(tier: .plus))
        )

        let first = Task { await model.bootstrap() }
        await waitUntil { subscription.pendingCount == 1 }

        let second = Task { await model.bootstrap() }
        await waitUntil { subscription.pendingCount == 2 }

        await subscription.completeNext(
            .success(SubscriptionStatus(isPremium: true, planName: "Monthly"))
        )
        await first.value
        XCTAssertEqual(model.state, .loading)

        await subscription.completeNext(.success(.free))
        await second.value
        XCTAssertEqual(model.state, .subscriptionRequired)
    }

    func testFailedIdentityTransitionLeavesAccessClosed() async {
        let subscription = SequencedSubscription()
        let model = AppAccessModel(
            services: services(subscription: subscription, usage: AccessTestUsage(tier: .plus))
        )

        let first = Task { await model.bootstrap() }
        await waitUntil { subscription.pendingCount == 1 }
        let second = Task { await model.bootstrap() }
        await waitUntil { subscription.pendingCount == 2 }

        await subscription.completeNext(
            .success(SubscriptionStatus(isPremium: true, planName: "Monthly"))
        )
        await first.value
        await subscription.completeNext(.failure(SubscriptionError.verificationUnavailable))
        await second.value

        XCTAssertEqual(model.state, .verificationUnavailable)
    }

    func testRequireSubscriptionInvalidatesInFlightPremiumUnlock() async {
        let subscription = SequencedSubscription()
        let model = AppAccessModel(
            services: services(subscription: subscription, usage: AccessTestUsage(tier: .plus))
        )

        let bootstrap = Task { await model.bootstrap() }
        await waitUntil { subscription.pendingCount == 1 }
        model.requireSubscription()
        await subscription.completeNext(
            .success(SubscriptionStatus(isPremium: true, planName: "Monthly"))
        )
        await bootstrap.value

        XCTAssertEqual(model.state, .subscriptionRequired)
    }

    private func services(
        subscription: any SubscriptionServicing,
        usage: any UsageServicing
    ) -> AppServices {
        AppServices(
            generation: MockGenerationService(),
            analysis: MockAnalysisService(),
            usage: usage,
            subscription: subscription,
            requiresSubscriptionVerification: true,
            configurationError: nil
        )
    }
}

private final class AccessTestSubscription: SubscriptionServicing {
    private(set) var status: SubscriptionStatus = .free
    let result: SubscriptionStatus
    let error: Error?

    init(result: SubscriptionStatus, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func refresh() async {}

    func verify() async throws -> SubscriptionStatus {
        if let error { throw error }
        status = result
        return result
    }

    func offerings() async throws -> [SubscriptionPlan] { [] }
    func purchase(_ plan: SubscriptionPlan) async throws -> Bool { false }
    func restorePurchases() async throws -> Bool { false }
}

private final class SequencedSubscription: SubscriptionServicing {
    private(set) var status: SubscriptionStatus = .free
    private var pending: [CheckedContinuation<Result<SubscriptionStatus, Error>, Never>] = []

    var pendingCount: Int { pending.count }

    func refresh() async {}

    func verify() async throws -> SubscriptionStatus {
        let result = await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
        switch result {
        case .success(let status):
            self.status = status
            return status
        case .failure(let error):
            throw error
        }
    }

    func completeNext(_ result: Result<SubscriptionStatus, Error>) async {
        guard !pending.isEmpty else {
            XCTFail("No in-flight verification to complete")
            return
        }
        pending.removeFirst().resume(returning: result)
        await Task.yield()
    }

    func offerings() async throws -> [SubscriptionPlan] { [] }
    func purchase(_ plan: SubscriptionPlan) async throws -> Bool { false }
    func restorePurchases() async throws -> Bool { false }
}

@MainActor
private func waitUntil(_ predicate: @escaping () -> Bool) async {
    for _ in 0..<200 {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Condition never became true")
}

private final class AccessTestUsage: UsageServicing {
    let status: UsageStatus

    init(tier: UsageStatus.Tier) {
        status = UsageStatus(
            remaining: tier == .plus ? 150 : 0,
            limit: tier == .plus ? 150 : 0,
            tier: tier,
            refinementsRemaining: 0
        )
    }

    func canStartFullGeneration() -> Bool { status.remaining > 0 }
    func consumeFullGeneration() {}
    func canRefine() -> Bool { status.refinementsRemaining > 0 }
    func consumeRefinement() {}
    func refreshIfNeeded() async {}
    func invalidate() {}
}
