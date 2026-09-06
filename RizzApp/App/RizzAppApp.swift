import SwiftUI

@main
struct RizzAppApp: App {
    @State private var flowModel = AppFlowModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flowModel)
                // Mock vs live is decided once in AppServices.current,
                // driven by AppConfig.serviceMode.
                .environment(\.services, AppServices.current)
                .preferredColorScheme(.dark)
        }
    }
}
