import SwiftUI

/// Dependency container injected through the SwiftUI environment.
/// Views/ViewModels see only the protocols; swapping mocks for live
/// implementations happens here and in `RizzAppApp`.
struct AppServices {
    let generation: any GenerationServicing
    let analysis: any AnalysisServicing
    let usage: any UsageServicing
    let subscription: any SubscriptionServicing

    static let mock = AppServices(
        generation: MockGenerationService(),
        analysis: MockAnalysisService(),
        usage: MockUsageStore(),
        subscription: MockSubscriptionService()
    )

    /// Live services: real backend generation/analysis/usage and real
    /// RevenueCat subscriptions. The installation ID is shared between the
    /// backend (quota) and RevenueCat (app user ID) so the webhook can link
    /// them.
    static func live(config: APIConfig) -> AppServices {
        let identity = KeychainInstallationIdentityService()
        let installationID = identity.installationID
        let client = APIClient(config: config, installationID: installationID)
        let usage = LiveUsageService(client: client)
        return AppServices(
            generation: LiveGenerationService(client: client) { usage.apply($0) },
            analysis: LiveAnalysisService(client: client) { usage.apply($0) },
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
