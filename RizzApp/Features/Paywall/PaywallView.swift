import SwiftUI

/// Mock paywall. Plans come from `SubscriptionServicing` (never hard-coded
/// in the view) so Phase 7 can swap in RevenueCat offerings with localized
/// pricing. Purchases intentionally surface a "not connected" development
/// message — no fake successful purchases, no dark patterns.
struct PaywallView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var plans: [SubscriptionPlan] = []
    @State private var selectedPlanID: String?
    @State private var showsNotConnectedAlert = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                header

                VStack(spacing: Spacing.md) {
                    if plans.isEmpty {
                        LoadingDots()
                            .frame(height: 120)
                    } else {
                        ForEach(plans) { plan in
                            planCard(plan)
                        }
                    }
                }

                Spacer()

                VStack(spacing: Spacing.md) {
                    Button("Continue") {
                        showsNotConnectedAlert = true
                    }
                    .buttonStyle(.primary)
                    .disabled(selectedPlanID == nil)
                    .opacity(selectedPlanID == nil ? 0.4 : 1)

                    footerLinks
                }
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.md)
        }
        .task {
            guard plans.isEmpty else { return }
            plans = (try? await services.subscription.offerings()) ?? []
            selectedPlanID = plans.last?.id
        }
        .alert("Subscriptions aren't connected yet", isPresented: $showsNotConnectedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This is a development build. Purchases arrive with RevenueCat in a later phase.")
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(Spacing.md)
            }
            .accessibilityLabel("Close")
        }
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Text("RizzApp Plus")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                benefit("150 conversation analyses a month")
                benefit("All six goals and refinements")
                benefit("Cancel anytime")
            }
            .padding(.top, Spacing.sm)
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
        }
    }

    private func planCard(_ plan: SubscriptionPlan) -> some View {
        let isSelected = selectedPlanID == plan.id
        return Button {
            selectedPlanID = plan.id
        } label: {
            HStack {
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
                Spacer()
                Text("\(plan.price)/\(plan.period)")
                    .font(Typography.headline)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
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
        HStack(spacing: Spacing.lg) {
            Button("Restore") { showsNotConnectedAlert = true }
            Button("Terms") {}      // Placeholder — production URL in Phase 10.
            Button("Privacy") {}    // Placeholder — production URL in Phase 10.
        }
        .font(Typography.caption)
        .foregroundStyle(Theme.textSecondary)
    }
}

#Preview {
    PaywallView()
        .preferredColorScheme(.dark)
}
