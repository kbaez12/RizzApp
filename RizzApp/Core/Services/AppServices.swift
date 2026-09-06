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
