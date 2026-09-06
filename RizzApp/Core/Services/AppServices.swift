import SwiftUI

/// Dependency container injected through the SwiftUI environment.
/// Views/ViewModels see only the protocols; swapping mocks for live
/// implementations (Phases 4–7) happens here and in `RizzAppApp`.
struct AppServices {
    let generation: any GenerationServicing
    let usage: any UsageServicing
    let subscription: any SubscriptionServicing

    static let mock = AppServices(
        generation: MockGenerationService(),
        usage: MockUsageStore(),
        subscription: MockSubscriptionService()
    )

    /// Live services: real backend generation/usage and real RevenueCat
    /// subscriptions. The installation ID is shared between the backend
    /// (quota) and RevenueCat (app user ID) so the webhook can link them.
    static func live(config: APIConfig) -> AppServices {
        let identity = KeychainInstallationIdentityService()
        let installationID = identity.installationID
        let client = APIClient(config: config, installationID: installationID)
        let usage = LiveUsageService(client: client)
        let generation = LiveGenerationService(client: client) { status in
            usage.apply(status)
        }
        return AppServices(
            generation: generation,
            usage: usage,
            subscription: RevenueCatSubscriptionService(
                publicSDKKey: config.revenueCatPublicKey,
                installationID: installationID
            )
        )
    }

    /// The single wiring point — resolved once from `AppConfig.serviceMode`.
    /// Views and ViewModels never know which mode is active.
    static let current: AppServices = {
        switch AppConfig.serviceMode {
        case .mock:
            return .mock
        case .liveDevelopment:
            return .live(config: AppConfig.api)
        }
    }()
}

private struct AppServicesKey: EnvironmentKey {
    static let defaultValue = AppServices.mock
}

extension EnvironmentValues {
    var services: AppServices {
        get { self[AppServicesKey.self] }
        set { self[AppServicesKey.self] = newValue }
    }
}
