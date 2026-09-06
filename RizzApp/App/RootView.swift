import SwiftUI

/// Hosts the navigation stack and modal sheets (Settings, Paywall).
struct RootView: View {
    @Environment(AppFlowModel.self) private var flow
    @Environment(\.services) private var services

    var body: some View {
        @Bindable var flow = flow

        NavigationStack(path: $flow.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .sheet(isPresented: $flow.isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $flow.isShowingPaywall) {
            PaywallView()
        }
        .tint(Theme.accent)
        .task {
            // No-op for mocks; fetches backend usage in live mode.
            await services.usage.refreshIfNeeded()
            await services.subscription.refresh()
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .screenshotPreview: ScreenshotPreviewView()
        case .pasteText: PasteTextView()
        case .goalSelection: GoalSelectionView()
        case .results: ResultsView()
        }
    }
}

#Preview {
    RootView()
        .environment(AppFlowModel())
        .preferredColorScheme(.dark)
}
