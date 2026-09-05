import SwiftUI

/// Hosts the navigation stack and modal sheets. Route destinations are
/// placeholders until each feature screen is built in Phase 2.
struct RootView: View {
    @Environment(AppFlowModel.self) private var flow

    var body: some View {
        @Bindable var flow = flow

        NavigationStack(path: $flow.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
        .sheet(isPresented: $flow.isShowingSettings) {
            placeholder("Settings")
        }
        .sheet(isPresented: $flow.isShowingPaywall) {
            placeholder("Paywall")
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .screenshotPreview: placeholder("Screenshot Preview")
        case .pasteText: placeholder("Paste Text")
        case .goalSelection: placeholder("Goal Selection")
        case .results: placeholder("Results")
        }
    }

    /// Temporary stand-in for screens built in Phase 2.
    private func placeholder(_ title: String) -> some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                Text(title)
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Coming in Phase 2")
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppFlowModel())
        .preferredColorScheme(.dark)
}
