import SwiftUI

/// Paywall. Plans and prices come from `SubscriptionServicing` (RevenueCat
/// offerings with localized Apple pricing in live mode) — never hard-coded
/// here. No timers, no fake discounts, no pressure.
struct PaywallView: View {
    @Environment(\.services) private var services
    @Environment(\.openURL) private var openURL

    let onVerified: () async -> Void

    @State private var plans: [SubscriptionPlan] = []
    @State private var selectedPlanID: String?
    @State private var isLoading = true
    @State private var isPurchasing = false
    @State private var errorMessage: String?

    init(onVerified: @escaping () async -> Void = {}) {
        self.onVerified = onVerified
    }

    var body: some View {
        ZStack {
            GradientBackground()

            VStack(spacing: Spacing.lg) {
                header

                VStack(spacing: Spacing.md) {
                    if isLoading {
                        LoadingDots()
                            .frame(height: 140)
                    } else if plans.isEmpty {
                        unavailableState
                    } else {
                        ForEach(plans) { plan in
                            planCard(plan)
                        }
                    }
                }

                Spacer(minLength: Spacing.md)

                VStack(spacing: Spacing.md) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }

                    Button {
                        Task { await purchase() }
                    } label: {
                        if isPurchasing {
                            LoadingDots()
                        } else {
                            Text("Continue")
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(selectedPlanID == nil || isPurchasing)
                    .opacity(selectedPlanID == nil ? 0.4 : 1)

                    Text("Payment is charged to your Apple ID. The subscription renews automatically unless canceled at least 24 hours before the current period ends. Manage or cancel it in your App Store account.")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)

                    footerLinks
                }
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.md)
        }
        .task {
            guard plans.isEmpty else { return }
            await loadPlans()
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: Spacing.md) {
            Text("Subscribe to Greenshot")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                benefit("200 charged AI operations each month")
                benefit("Two follow-up refinements included per charged operation")
                benefit("Cancel anytime")
            }
        }
    }

    private func benefit(_ text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 15))
            Text(text)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unavailableState: some View {
        VStack(spacing: Spacing.md) {
            Text("Plans aren't available right now.")
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await loadPlans() }
            }
            .buttonStyle(.pill)
        }
        .frame(height: 140)
    }

    private func planCard(_ plan: SubscriptionPlan) -> some View {
        let isSelected = selectedPlanID == plan.id
        return Button {
            selectedPlanID = plan.id
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(plan.name)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if let detail = plan.detail {
                        Text(detail)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: Spacing.sm)
                Text("\(plan.price)/\(plan.period)")
                    .font(Typography.headline)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(Spacing.md)
            .background(
                isSelected ? Theme.accentMuted : Theme.surface,
                in: RoundedRectangle(cornerRadius: Radius.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: selectedPlanID)
    }

    private var footerLinks: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.lg) {
                Button("Restore Purchases") {
                    Task { await restore() }
                }
                Button("Manage") {
                    if let url = services.subscription.manageSubscriptionsURL {
                        openURL(url)
                    }
                }
                Button("Support") { openURL(LegalLinks.support) }
            }
            HStack(spacing: Spacing.lg) {
                Button("Terms") { openURL(LegalLinks.terms) }
                Button("Privacy") { openURL(LegalLinks.privacy) }
            }
        }
        .font(Typography.caption)
        .foregroundStyle(Theme.textSecondary)
        .disabled(isPurchasing)
    }

    // MARK: - Actions

    private func loadPlans() async {
        isLoading = true
        errorMessage = nil
        do {
            plans = try await services.subscription.offerings()
            // Preselect yearly (last) — better value, no pressure applied.
            selectedPlanID = plans.last?.id
        } catch {
            plans = []
            errorMessage = friendlyMessage(for: error)
        }
        isLoading = false
    }

    private func purchase() async {
        guard let plan = plans.first(where: { $0.id == selectedPlanID }) else { return }
        isPurchasing = true
        errorMessage = nil
        do {
            let purchased = try await services.subscription.purchase(plan)
            if purchased {
                await onVerified()
            }
            // User cancelled: no message, no nagging.
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
        isPurchasing = false
    }

    private func restore() async {
        isPurchasing = true
        errorMessage = nil
        do {
            let restored = try await services.subscription.restorePurchases()
            if restored {
                await onVerified()
            } else {
                errorMessage = "No previous subscription found on this Apple ID."
            }
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
        isPurchasing = false
    }

    private func friendlyMessage(for error: Error) -> String {
        (error as? SubscriptionError)?.displayMessage
            ?? "Something went wrong. Please try again."
    }
}

#Preview {
    PaywallView()
        .environment(\.services, .mock)
        .preferredColorScheme(.dark)
}
