import SwiftUI

@main
struct RizzAppApp: App {
    @State private var flowModel = AppFlowModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flowModel)
                .preferredColorScheme(.dark)
        }
    }
}
