import Foundation
import Observation
@_spi(Internal) import RevenueCat

/// RevenueCat-backed subscriptions. This is the ONLY file that imports
/// RevenueCat — everything else talks to `SubscriptionServicing`.
///
/// RevenueCat is configured only after Supabase anonymous authentication.
/// Customer Authentication validates the Supabase OIDC token, so the client
/// cannot select or forge a RevenueCat App User ID. The backend independently
/// validates the same Supabase bearer token.
@Observable
final class RevenueCatSubscriptionService: SubscriptionServicing {
    /// Single entitlement identifier configured in RevenueCat.
    private static let entitlementID = "plus"

    private(set) var status: SubscriptionStatus = .free

    /// Maps our plan IDs back to RevenueCat packages so views never see one.
    private var packagesByPlanID: [String: Package] = [:]
    private let publicSDKKey: String
    private let authentication: any AuthenticationServicing
    private let client: APIClient
    private let onUsageSynced: (UsageStatus) -> Void
    /// Bound to the current Supabase user ID. A process-wide Boolean is
    /// not enough: a new anonymous user must not keep the previous
    /// RevenueCat customer session.
    private let identity: RevenueCatIdentitySynchronizer
    private var isConfigured = false

    init(
        publicSDKKey: String,
        authentication: any AuthenticationServicing,
        client: APIClient,
        onUsageSynced: @escaping (UsageStatus) -> Void
    ) {
        self.publicSDKKey = publicSDKKey
        self.authentication = authentication
        self.client = client
        self.onUsageSynced = onUsageSynced
        self.identity = RevenueCatIdentitySynchronizer { user in
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                Purchases.shared.authentication.logIn(
                    using: .oidc(Data(user.accessToken.utf8))
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func refresh() async {
        _ = try? await verify()
    }

    @discardableResult
    func verify() async throws -> SubscriptionStatus {
        let userID = try await configureIfNeeded()
        let info: CustomerInfo
        do {
            info = try await Purchases.shared.customerInfo()
        } catch {
            await revokeLocalAccess(ifBoundTo: userID)
            throw SubscriptionError.verificationUnavailable
        }
        guard await stillBound(to: userID) else {
            await revokeLocalAccess(ifBoundTo: userID)
            throw SubscriptionError.verificationUnavailable
        }
        guard hasActiveEntitlement(info) else {
            await revokeLocalAccess(ifBoundTo: userID)
            return status
        }
        try await confirmBackend(for: userID)
        guard await stillBound(to: userID) else {
            await revokeLocalAccess(ifBoundTo: userID)
            throw SubscriptionError.verificationUnavailable
        }
        apply(info)
        return status
    }

    func offerings() async throws -> [SubscriptionPlan] {
        try await configureIfNeeded()
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
        let userID = try await configureIfNeeded()
        guard let package = packagesByPlanID[plan.id] else {
            throw SubscriptionError.notConfigured
        }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return false }
            guard await stillBound(to: userID) else {
                await revokeLocalAccess(ifBoundTo: userID)
                throw SubscriptionError.verificationUnavailable
            }
            guard hasActiveEntitlement(result.customerInfo) else {
                await revokeLocalAccess(ifBoundTo: userID)
                throw SubscriptionError.purchaseFailed
            }
            try await confirmBackend(for: userID)
            guard await stillBound(to: userID) else {
                await revokeLocalAccess(ifBoundTo: userID)
                throw SubscriptionError.verificationUnavailable
            }
            apply(result.customerInfo)
            return status.isPremium
        } catch let error as SubscriptionError {
            throw error
        } catch {
            throw SubscriptionError.purchaseFailed
        }
    }

    func restorePurchases() async throws -> Bool {
        let userID = try await configureIfNeeded()
        do {
            let info = try await Purchases.shared.restorePurchases()
            guard await stillBound(to: userID) else {
                await revokeLocalAccess(ifBoundTo: userID)
                throw SubscriptionError.verificationUnavailable
            }
            guard hasActiveEntitlement(info) else {
                await revokeLocalAccess(ifBoundTo: userID)
                return false
            }
            try await confirmBackend(for: userID)
            guard await stillBound(to: userID) else {
                await revokeLocalAccess(ifBoundTo: userID)
                throw SubscriptionError.verificationUnavailable
            }
            apply(info)
            return status.isPremium
        } catch let error as SubscriptionError {
            throw error
        } catch {
            throw SubscriptionError.purchaseFailed
        }
    }

    // MARK: - Mapping

    @discardableResult
    private func configureIfNeeded() async throws -> String {
        let user: AuthenticatedUser
        do {
            user = try await authentication.authenticatedUser()
        } catch {
            throw SubscriptionError.verificationUnavailable
        }
        guard UUID(uuidString: user.id) != nil, !publicSDKKey.isEmpty else {
            throw SubscriptionError.notConfigured
        }
        if !isConfigured {
            Purchases.logLevel = .warn
            let configuration = Configuration.Builder(withAPIKey: publicSDKKey)
                .with(iamEnabled: true)
                .build()
            Purchases.configure(with: configuration)
            isConfigured = true
        }
        let switchedIdentities = await identity.authenticatedUserID.map { $0 != user.id } ?? false
        if switchedIdentities {
            status = .free
        }
        do {
            let didLogIn = try await identity.authenticate(user)
            if didLogIn {
                status = .free
            }
        } catch {
            await revokeLocalAccess(ifBoundTo: user.id)
            throw error
        }
        return user.id
    }

    private func stillBound(to userID: String) async -> Bool {
        await identity.authenticatedUserID == userID
    }

    /// Drops local premium only for the identity that failed or changed.
    /// A stale attempt must not erase a newer user's in-flight verification.
    private func revokeLocalAccess(ifBoundTo userID: String) async {
        let boundID = await identity.authenticatedUserID
        if boundID == nil || boundID == userID {
            status = .free
        }
    }

    private func confirmBackend(for userID: String) async throws {
        do {
            let synced: SubscriptionSyncResponse = try await client.send(.subscriptionSync)
            guard synced.usage.tier == .plus else {
                await revokeLocalAccess(ifBoundTo: userID)
                throw SubscriptionError.backendNotEntitled
            }
            onUsageSynced(synced.usage)
        } catch let error as SubscriptionError {
            throw error
        } catch APIError.subscriptionRequired {
            await revokeLocalAccess(ifBoundTo: userID)
            throw SubscriptionError.backendNotEntitled
        } catch {
            await revokeLocalAccess(ifBoundTo: userID)
            throw SubscriptionError.verificationUnavailable
        }
    }

    private func hasActiveEntitlement(_ info: CustomerInfo) -> Bool {
        guard let entitlement = info.entitlements[Self.entitlementID] else { return false }
        return entitlement.isActive
            && (entitlement.expirationDate.map { $0 > Date() } ?? false)
    }

    private func apply(_ info: CustomerInfo) {
        guard let entitlement = info.entitlements[Self.entitlementID],
              hasActiveEntitlement(info) else {
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

/// Accepts the backend's entitlement-and-usage response while retaining
/// compatibility with an early raw-usage development response.
private struct SubscriptionSyncResponse: Decodable {
    let usage: UsageStatus

    private enum CodingKeys: String, CodingKey {
        case usage
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let usage = try container.decodeIfPresent(UsageStatus.self, forKey: .usage) {
            self.usage = usage
        } else {
            self.usage = try UsageStatus(from: decoder)
        }
    }
}
