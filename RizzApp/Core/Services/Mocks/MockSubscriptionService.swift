import Foundation

/// Fake subscription backend for Phase 2. Offerings mirror the shape
/// RevenueCat will provide in Phase 7; purchase/restore intentionally fail
/// with `.notConfigured` — we never fake successful App Store purchases.
final class MockSubscriptionService: SubscriptionServicing {
    var isPremium: Bool { false }

    func offerings() async throws -> [SubscriptionPlan] {
        // Mocked example pricing — real localized prices come from
        // RevenueCat/StoreKit in Phase 7. Do not ship these strings.
        [
            SubscriptionPlan(
                id: "plus_monthly",
                name: "Monthly",
                price: "$6.99",
                period: "month",
                detail: nil
            ),
            SubscriptionPlan(
                id: "plus_yearly",
                name: "Yearly",
                price: "$49.99",
                period: "year",
                detail: "About $4.17/month"
            ),
        ]
    }

    func purchase(_ plan: SubscriptionPlan) async throws {
        throw SubscriptionError.notConfigured
    }

    func restorePurchases() async throws {
        throw SubscriptionError.notConfigured
    }
}
