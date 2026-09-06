import Foundation

/// A purchasable plan as shown on the paywall. In Phase 7 these come from
/// RevenueCat offerings with localized App Store pricing — the UI must never
/// hard-code price strings.
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

/// Abstraction over subscriptions. The UI knows `isPremium`, offerings,
/// purchase, and restore — never RevenueCat-specific types.
protocol SubscriptionServicing: AnyObject {
    var isPremium: Bool { get }
    func offerings() async throws -> [SubscriptionPlan]
    func purchase(_ plan: SubscriptionPlan) async throws
    func restorePurchases() async throws
}

enum SubscriptionError: Error {
    /// Store integration not connected yet (development builds).
    case notConfigured
}
