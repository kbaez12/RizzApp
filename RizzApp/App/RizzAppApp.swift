import SwiftUI

@main
struct RizzAppApp: App {
    @State private var flowModel = AppFlowModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flowModel)
                // Phase 2: all-mock services. Live implementations are
                // swapped in here in Phases 4–7.
                .environment(\.services, .mock)
                .preferredColorScheme(.dark)
        }
    }
}
