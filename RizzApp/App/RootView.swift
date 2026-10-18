import SwiftUI

/// Fail-closed launch gate. The core tabs do not exist in the view hierarchy
/// until both RevenueCat and the authenticated backend confirm access.
struct RootView: View {
    @Environment(AppAccessModel.self) private var access
    @Environment(\.services) private var services

    var body: some View {
        Group {
            switch access.state {
            case .loading:
                GateMessageView(
                    title: "Checking your subscription",
                    message: "This should only take a moment.",
                    showsProgress: true
                )
            case .subscribed:
                CoreTabView()
            case .subscriptionRequired:
                PaywallView(onVerified: { await access.subscriptionDidVerify() })
            case .verificationUnavailable:
                GateMessageView(
                    title: "Subscription verification unavailable",
                    message: "We couldn't securely verify access. Check your connection and try again.",
                    retry: { Task { await access.bootstrap() } },
                    restore: {
                        Task {
                            _ = try? await services.subscription.restorePurchases()
                            await access.bootstrap()
                        }
                    }
                )
            case .configurationError(let message):
                GateMessageView(title: "Configuration required", message: message)
            }
        }
    }
}

private struct CoreTabView: View {
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
        .sheet(isPresented: $flow.isShowingAllowanceReached) {
            AllowanceReachedView()
        }
        .task {
            // No-op for mocks; fetches backend usage in live mode.
            await services.usage.refreshIfNeeded()
        }
    }
}

private struct GateMessageView: View {
    @Environment(\.openURL) private var openURL
    let title: String
    let message: String
    var showsProgress = false
    var retry: (() -> Void)?
    var restore: (() -> Void)?

    var body: some View {
        ZStack {
            GradientBackground()
            VStack(spacing: Spacing.lg) {
                if showsProgress { LoadingDots() }
                Text(title)
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if let retry {
                    Button("Try Again", action: retry)
                        .buttonStyle(.primary)
                }
                if let restore {
                    Button("Restore Purchases", action: restore)
                        .buttonStyle(.pill)
                }
                Button("Manage Subscription") {
                    openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
                }
                .buttonStyle(.pill)
                HStack(spacing: Spacing.md) {
                    Button("Support") { openURL(LegalLinks.support) }
                    Button("Terms") { openURL(LegalLinks.terms) }
                    Button("Privacy") { openURL(LegalLinks.privacy) }
                }
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(Spacing.screenMargin)
        }
    }
}

private struct AllowanceReachedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            GradientBackground()
            VStack(spacing: Spacing.lg) {
                Text("Monthly allowance reached")
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Your subscription is active. Your generation allowance will reset with the next billing period.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Done") { dismiss() }
                    .buttonStyle(.primary)
                Button("Manage Subscription") {
                    openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
                }
                .buttonStyle(.pill)
            }
            .padding(Spacing.screenMargin)
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
        .environment(AppAccessModel(services: .mock))
        .environment(AppFlowModel())
        .environment(ChatViewModel.preview)
        .environment(AnalyzeViewModel.preview)
}
