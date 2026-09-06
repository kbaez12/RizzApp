import Foundation
import Observation
import RevenueCat

/// RevenueCat-backed subscriptions. This is the ONLY file that imports
/// RevenueCat — everything else talks to `SubscriptionServicing`.
///
/// No account system: RevenueCat is configured with our anonymous
/// installation ID as the app user ID, so the RevenueCat webhook can map an
/// entitlement change to the same installation row the quota system uses.
@Observable
final class RevenueCatSubscriptionService: SubscriptionServicing {
    /// Single entitlement identifier configured in RevenueCat.
    private static let entitlementID = "plus"

    private(set) var status: SubscriptionStatus = .free

    /// Maps our plan IDs back to RevenueCat packages so views never see one.
    private var packagesByPlanID: [String: Package] = [:]

    init(publicSDKKey: String, installationID: String) {
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: publicSDKKey, appUserID: installationID)
    }

    func refresh() async {
        guard let info = try? await Purchases.shared.customerInfo() else { return }
        apply(info)
    }

    func offerings() async throws -> [SubscriptionPlan] {
        let offerings: Offerings
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            throw SubscriptionError.offeringsUnavailable
        }
        guard let current = offerings.current, !current.availablePackages.isEmpty else {
            throw SubscriptionError.offeringsUnavailable
        }

        // Monthly first, then yearly (the paywall preselects the last item).
        let ordered = current.availablePackages.sorted { lhs, rhs in
            rank(lhs.packageType) < rank(rhs.packageType)
        }
        packagesByPlanID = Dictionary(
            uniqueKeysWithValues: ordered.map { ($0.identifier, $0) }
        )
        return ordered.map(plan(from:))
    }

    func purchase(_ plan: SubscriptionPlan) async throws -> Bool {
        guard let package = packagesByPlanID[plan.id] else {
            throw SubscriptionError.notConfigured
        }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return false }
            apply(result.customerInfo)
            return status.isPremium
        } catch {
            throw SubscriptionError.purchaseFailed
        }
    }

    func restorePurchases() async throws -> Bool {
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            return status.isPremium
        } catch {
            throw SubscriptionError.purchaseFailed
        }
    }

    // MARK: - Mapping

    private func apply(_ info: CustomerInfo) {
        guard let entitlement = info.entitlements[Self.entitlementID],
              entitlement.isActive else {
            status = .free
            return
        }
        status = SubscriptionStatus(
            isPremium: true,
            planName: displayName(forProductID: entitlement.productIdentifier),
            expiresAt: entitlement.expirationDate,
            willRenew: entitlement.willRenew
        )
    }

    private func plan(from package: Package) -> SubscriptionPlan {
        let product = package.storeProduct
        return SubscriptionPlan(
            id: package.identifier,
            name: name(for: package.packageType),
            // Localized Apple pricing — never hard-coded.
            price: product.localizedPriceString,
            period: periodWord(for: package.packageType),
            detail: monthlyEquivalent(for: package)
        )
    }

    private func rank(_ type: PackageType) -> Int {
        switch type {
        case .monthly: 0
        case .annual: 1
        default: 2
        }
    }

    private func name(for type: PackageType) -> String {
        switch type {
        case .monthly: "Monthly"
        case .annual: "Yearly"
        default: "Plus"
        }
    }

    private func periodWord(for type: PackageType) -> String {
        switch type {
        case .monthly: "month"
        case .annual: "year"
        default: "period"
        }
    }

    private func displayName(forProductID productID: String) -> String {
        productID.localizedCaseInsensitiveContains("year") ? "Yearly" : "Monthly"
    }

    /// "About $4.17/month" for annual plans, derived from the real price so
    /// no savings claim is invented.
    private func monthlyEquivalent(for package: Package) -> String? {
        guard package.packageType == .annual else { return nil }
        let product = package.storeProduct
        let perMonth = product.price / 12
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = product.priceFormatter?.locale ?? .current
        guard let formatted = formatter.string(from: perMonth as NSDecimalNumber) else {
            return nil
        }
        return "About \(formatted)/month"
    }
}
