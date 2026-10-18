import SwiftUI

/// Dependency container injected through the SwiftUI environment.
/// Views/ViewModels see only the protocols; swapping mocks for live
/// implementations happens here and in `RizzAppApp`.
struct AppServices {
    let generation: any GenerationServicing
    let analysis: any AnalysisServicing
    let usage: any UsageServicing
    let subscription: any SubscriptionServicing
    let requiresSubscriptionVerification: Bool
    let configurationError: String?

    static let mock = AppServices(
        generation: MockGenerationService(),
        analysis: MockAnalysisService(),
        usage: MockUsageStore(),
        subscription: MockSubscriptionService(startPremium: true),
        requiresSubscriptionVerification: false,
        configurationError: nil
    )

    /// Live services share one Supabase anonymous-auth session. Its verified
    /// user UUID identifies RevenueCat while its JWT authenticates backend
    /// requests; the backend independently binds the two.
    static func live(config: APIConfig) -> AppServices {
        let authentication = SupabaseAuthService(config: config)
        let client = APIClient(config: config) {
            try await authentication.accessToken()
        }
        let usage = LiveUsageService(client: client)
        return AppServices(
            generation: LiveGenerationService(client: client) { usage.apply($0) },
            analysis: LiveAnalysisService(client: client) { usage.apply($0) },
            usage: usage,
            subscription: RevenueCatSubscriptionService(
                publicSDKKey: config.revenueCatPublicKey,
                authentication: authentication,
                client: client,
                onUsageSynced: { usage.apply($0) }
            ),
            requiresSubscriptionVerification: true,
            configurationError: nil
        )
    }

    /// Development-only live backend wiring. Purchases stay mocked so a
    /// development API test cannot contact RevenueCat or alter entitlements.
    static func liveDevelopment(config: APIConfig) -> AppServices {
        let authentication = SupabaseAuthService(config: config)
        let client = APIClient(config: config) {
            try await authentication.accessToken()
        }
        let usage = LiveUsageService(client: client)
        return AppServices(
            generation: LiveGenerationService(client: client) { usage.apply($0) },
            analysis: LiveAnalysisService(client: client) { usage.apply($0) },
            usage: usage,
            subscription: MockSubscriptionService(startPremium: true),
            requiresSubscriptionVerification: false,
            configurationError: nil
        )
    }

    /// The single wiring point — resolved once from `AppConfig.serviceMode`.
    /// Views and ViewModels never know which mode is active.
    static let current: AppServices = {
        switch AppConfig.serviceMode {
        case .mock:
            return .mock
        case .liveDevelopment:
            guard let config = AppConfig.developmentAPI else {
                return .mock
            }
            return .liveDevelopment(config: config)
        case .production:
            guard let config = AppConfig.productionAPI else {
                return configurationFailure()
            }
            return .live(config: config)
        case .configurationError:
            return configurationFailure()
        }
    }()

    private static func configurationFailure() -> AppServices {
        AppServices(
            generation: UnavailableGenerationService(),
            analysis: UnavailableAnalysisService(),
            usage: UnavailableUsageService(),
            subscription: UnavailableSubscriptionService(),
            requiresSubscriptionVerification: true,
            configurationError: "This build is missing its public Supabase or RevenueCat configuration."
        )
    }
}

private final class UnavailableGenerationService: GenerationServicing {
    func generate(
        for input: ConversationInput,
        goal: ResponseGoal,
        requestID: UUID
    ) async throws -> [GeneratedResponse] {
        throw GenerationError.failed
    }

    func refine(
        _ action: RefinementAction,
        input: ConversationInput,
        goal: ResponseGoal,
        previous: [GeneratedResponse],
        requestID: UUID
    ) async throws -> [GeneratedResponse] {
        throw GenerationError.failed
    }
}

private final class UnavailableAnalysisService: AnalysisServicing {
    func analyze(_ input: ConversationInput, requestID: UUID) async throws -> ChatAnalysis {
        throw GenerationError.failed
    }
}

private final class UnavailableUsageService: UsageServicing {
    let status = UsageStatus(remaining: 0, limit: 0, tier: .free, refinementsRemaining: 0)
    func canStartFullGeneration() -> Bool { false }
    func consumeFullGeneration() {}
    func canRefine() -> Bool { false }
    func consumeRefinement() {}
}

private final class UnavailableSubscriptionService: SubscriptionServicing {
    let status = SubscriptionStatus.free
    func refresh() async {}
    func verify() async throws -> SubscriptionStatus { throw SubscriptionError.notConfigured }
    func offerings() async throws -> [SubscriptionPlan] { throw SubscriptionError.notConfigured }
    func purchase(_ plan: SubscriptionPlan) async throws -> Bool {
        throw SubscriptionError.notConfigured
    }
    func restorePurchases() async throws -> Bool {
        throw SubscriptionError.notConfigured
    }
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
