import SwiftUI

@main
struct RizzAppApp: App {
    @State private var flowModel: AppFlowModel
    @State private var chatModel: ChatViewModel
    @State private var analyzeModel: AnalyzeViewModel

    // Mock vs live is decided once in AppServices.current, driven by
    // AppConfig.serviceMode.
    private let services = AppServices.current

    init() {
        let flow = AppFlowModel()
        let services = AppServices.current
        let consent = PrivacyConsentStore()
        let showPaywall = { flow.isShowingPaywall = true }
        _flowModel = State(initialValue: flow)
        _chatModel = State(initialValue: ChatViewModel(
            generation: services.generation,
            usage: services.usage,
            consent: consent,
            onQuotaExhausted: showPaywall
        ))
        _analyzeModel = State(initialValue: AnalyzeViewModel(
            analysis: services.analysis,
            usage: services.usage,
            consent: consent,
            onQuotaExhausted: showPaywall
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flowModel)
                .environment(chatModel)
                .environment(analyzeModel)
                .environment(\.services, services)
                .preferredColorScheme(.light)
        }
    }
}
