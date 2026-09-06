import Foundation

/// A purchasable plan as shown on the paywall. `price` and `period` come
/// from StoreKit via RevenueCat (localized) — the UI must never hard-code
/// price strings.
struct SubscriptionPlan: Identifiable, Equatable {
    let id: String
    let name: String
    /// Localized price string, e.g. "$6.99".
    let price: String
    /// Billing period display word, e.g. "month" / "year".
    let period: String
    /// Optional secondary line, e.g. "About $4.17/month".
    let detail: String?
}

/// Everything the UI needs to know about the subscription — no RevenueCat
/// types cross this boundary.
struct SubscriptionStatus: Equatable {
    var isPremium = false
    /// Display name of the active plan, when known.
    var planName: String?
    var expiresAt: Date?
    /// False when the user has cancelled but access has not lapsed yet.
    var willRenew = false

    static let free = SubscriptionStatus()
}

/// Abstraction over subscriptions. The UI knows `isPremium`, offerings,
/// purchase, and restore — never RevenueCat implementation details.
protocol SubscriptionServicing: AnyObject {
    var status: SubscriptionStatus { get }
    var isPremium: Bool { get }

    /// Refreshes entitlement state (launch, foreground, after purchase).
    func refresh() async

    func offerings() async throws -> [SubscriptionPlan]

    /// Returns false if the user cancelled the purchase sheet.
    @discardableResult
    func purchase(_ plan: SubscriptionPlan) async throws -> Bool

    /// Returns true if a `plus` entitlement was found and restored.
    @discardableResult
    func restorePurchases() async throws -> Bool

    /// Apple's subscription management page.
    var manageSubscriptionsURL: URL? { get }
}

extension SubscriptionServicing {
    var isPremium: Bool { status.isPremium }

    var manageSubscriptionsURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }
}

enum SubscriptionError: Error {
    /// Store integration not available (e.g. mock/dev builds, or the SDK
    /// could not be configured).
    case notConfigured
    /// Offerings could not be loaded from the store.
    case offeringsUnavailable
    /// Purchase or restore failed for a store-side reason.
    case purchaseFailed

    /// Friendly, non-technical copy for the UI.
    var displayMessage: String {
        switch self {
        case .notConfigured:
            "Subscriptions aren't available right now."
        case .offeringsUnavailable:
            "Couldn't load plans. Check your connection and try again."
        case .purchaseFailed:
            "That didn't go through. No charge was made."
        }
    }
}
