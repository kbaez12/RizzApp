import SwiftUI

/// Three tabs (Chat, Analyze, Settings) on a black tab bar, plus the
/// app-wide menu and paywall sheets.
struct RootView: View {
    @Environment(AppFlowModel.self) private var flow
    @Environment(\.services) private var services

    var body: some View {
        @Bindable var flow = flow

        TabView(selection: $flow.selectedTab) {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(AppFlowModel.Tab.chat)
                .modifier(BlackTabBar())

            AnalyzeView()
                .tabItem { Label("Analyze", systemImage: "magnifyingglass") }
                .tag(AppFlowModel.Tab.analyze)
                .modifier(BlackTabBar())

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppFlowModel.Tab.settings)
                .modifier(BlackTabBar())
        }
        .tint(.white)
        .sheet(isPresented: $flow.isShowingMenu, onDismiss: { flow.menuDidDismiss() }) {
            MenuSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $flow.isShowingPaywall) {
            PaywallView()
        }
        .task {
            // No-op for mocks; fetches backend usage in live mode.
            await services.usage.refreshIfNeeded()
            await services.subscription.refresh()
        }
    }
}

private struct BlackTabBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Theme.accent)
            .toolbarBackground(Theme.ink, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(.dark, for: .tabBar)
    }
}

#Preview {
    RootView()
        .environment(AppFlowModel())
        .environment(ChatViewModel.preview)
        .environment(AnalyzeViewModel.preview)
}
