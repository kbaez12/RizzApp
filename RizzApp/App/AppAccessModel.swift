import Foundation
import Observation

@MainActor
@Observable
final class AppAccessModel {
    enum State: Equatable {
        case loading
        case subscribed
        case subscriptionRequired
        case verificationUnavailable
        case configurationError(String)
    }

    private(set) var state: State
    private let services: AppServices
    /// Incremented for every access transition so a slower, older verify
    /// cannot restore premium after the current identity changed.
    private var accessGeneration = 0

    init(services: AppServices) {
        self.services = services
        if let message = services.configurationError {
            state = .configurationError(message)
        } else if services.requiresSubscriptionVerification {
            state = .loading
        } else {
            // Debug mocks/previews remain usable and never ship in Release.
            state = .subscribed
        }
    }

    func bootstrap() async {
        guard services.configurationError == nil,
              services.requiresSubscriptionVerification else {
            return
        }
        accessGeneration += 1
        let generation = accessGeneration
        state = .loading

        do {
            let subscription = try await services.subscription.verify()
            guard generation == accessGeneration else { return }
            guard subscription.isPremium else {
                state = .subscriptionRequired
                return
            }
            // Live subscription verification only returns premium after the
            // authenticated subscription-sync endpoint has confirmed access.
            // Do not race the observed usage cache's main-queue update here.
            state = .subscribed
        } catch APIError.subscriptionRequired, SubscriptionError.backendNotEntitled {
            guard generation == accessGeneration else { return }
            state = .subscriptionRequired
        } catch {
            guard generation == accessGeneration else { return }
            state = .verificationUnavailable
        }
    }

    func subscriptionDidVerify() async {
        await bootstrap()
    }

    func requireSubscription() {
        accessGeneration += 1
        state = .subscriptionRequired
    }
}
