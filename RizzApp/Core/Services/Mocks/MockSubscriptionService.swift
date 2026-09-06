import Foundation
import Observation

/// Offline subscription stand-in for mock mode and previews. Offerings
/// mirror the shape RevenueCat provides; purchase/restore intentionally
/// fail with `.notConfigured` — we never fake successful App Store
/// purchases. `startPremium` exists only so premium UI states can be seen
/// without the store.
@Observable
final class MockSubscriptionService: SubscriptionServicing {
    private(set) var status: SubscriptionStatus

    init(startPremium: Bool = false) {
        status = startPremium
            ? SubscriptionStatus(
                isPremium: true,
                planName: "Yearly",
                expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 365),
                willRenew: true
            )
            : .free
    }

    func refresh() async {}

    func offerings() async throws -> [SubscriptionPlan] {
        // Mocked example pricing. Real localized prices come from
        // RevenueCat/StoreKit in live mode — do not ship these strings.
        [
            SubscriptionPlan(
                id: "$rc_monthly",
                name: "Monthly",
                price: "$6.99",
                period: "month",
                detail: nil
            ),
            SubscriptionPlan(
                id: "$rc_annual",
                name: "Yearly",
                price: "$49.99",
                period: "year",
                detail: "About $4.17/month"
            ),
        ]
    }

    @discardableResult
    func purchase(_ plan: SubscriptionPlan) async throws -> Bool {
        throw SubscriptionError.notConfigured
    }

    @discardableResult
    func restorePurchases() async throws -> Bool {
        throw SubscriptionError.notConfigured
    }
}
