import SwiftUI

@main
struct RizzAppApp: App {
    @State private var flowModel: AppFlowModel
    @State private var accessModel: AppAccessModel
    @State private var chatModel: ChatViewModel
    @State private var analyzeModel: AnalyzeViewModel

    // Mock vs live is decided once in AppServices.current, driven by
    // AppConfig.serviceMode.
    private let services = AppServices.current
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let flow = AppFlowModel()
        let services = AppServices.current
        let access = AppAccessModel(services: services)
        let consent = PrivacyConsentStore()
        let showAllowanceReached = { flow.isShowingAllowanceReached = true }
        let requireSubscription = { access.requireSubscription() }
        _flowModel = State(initialValue: flow)
        _accessModel = State(initialValue: access)
        _chatModel = State(initialValue: ChatViewModel(
            generation: services.generation,
            usage: services.usage,
            consent: consent,
            onQuotaExhausted: showAllowanceReached,
            onSubscriptionRequired: requireSubscription
        ))
        _analyzeModel = State(initialValue: AnalyzeViewModel(
            analysis: services.analysis,
            usage: services.usage,
            consent: consent,
            onQuotaExhausted: showAllowanceReached,
            onSubscriptionRequired: requireSubscription
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flowModel)
                .environment(accessModel)
                .environment(chatModel)
                .environment(analyzeModel)
                .environment(\.services, services)
                .preferredColorScheme(.light)
                .task { await accessModel.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await accessModel.bootstrap() }
                }
        }
    }
}
