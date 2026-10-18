import Foundation

/// Tracks which Supabase user RevenueCat last authenticated, so a new
/// anonymous identity cannot keep the previous customer's session.
///
/// `transition` tokens make overlapping logins fail closed: only the latest
/// attempt may bind, and a failed attempt cannot be completed by a stale
/// success callback.
struct RevenueCatIdentityBinding: Equatable {
    private(set) var authenticatedUserID: String?
    private(set) var transition = 0

    /// `nil` means RevenueCat is already bound to this user and must not
    /// skip server entitlement checks — only the OIDC login itself.
    mutating func beginAuthentication(for userID: String) -> Int? {
        if authenticatedUserID == userID {
            return nil
        }
        authenticatedUserID = nil
        transition += 1
        return transition
    }

    mutating func succeed(userID: String, transition: Int) -> Bool {
        guard transition == self.transition else { return false }
        authenticatedUserID = userID
        return true
    }

    mutating func fail(transition: Int) {
        guard transition == self.transition else { return }
        authenticatedUserID = nil
        self.transition += 1
    }
}

/// Serializes OIDC login against the current Supabase user. The login
/// closure is the only RevenueCat SPI seam; identity rules stay here so
/// they can be tested without the purchases SDK.
actor RevenueCatIdentitySynchronizer {
    private var binding = RevenueCatIdentityBinding()
    private let logIn: (AuthenticatedUser) async throws -> Void

    init(logIn: @escaping (AuthenticatedUser) async throws -> Void) {
        self.logIn = logIn
    }

    var authenticatedUserID: String? { binding.authenticatedUserID }

    /// Returns whether a new RevenueCat login ran. Callers must treat a
    /// transition as unentitled until backend verification succeeds.
    @discardableResult
    func authenticate(_ user: AuthenticatedUser) async throws -> Bool {
        guard UUID(uuidString: user.id) != nil else {
            throw SubscriptionError.notConfigured
        }
        guard let transition = binding.beginAuthentication(for: user.id) else {
            return false
        }
        do {
            try await logIn(user)
            if !binding.succeed(userID: user.id, transition: transition) {
                throw SubscriptionError.verificationUnavailable
            }
            return true
        } catch let error as SubscriptionError {
            binding.fail(transition: transition)
            throw error
        } catch {
            binding.fail(transition: transition)
            throw SubscriptionError.verificationUnavailable
        }
    }
}
