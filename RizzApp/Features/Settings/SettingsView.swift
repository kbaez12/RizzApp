import SwiftUI

/// Settings — deliberately small. Subscription status/actions, legal links,
/// support, version.
struct SettingsView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showsPaywall = false
    @State private var isWorking = false
    @State private var noticeMessage: String?

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var subscription: SubscriptionStatus { services.subscription.status }

    private var statusValue: String {
        guard subscription.isPremium else {
            let usage = services.usage.status
            return "Free · \(usage.remaining) of \(usage.limit) left"
        }
        return subscription.planName.map { "Plus · \($0)" } ?? "Plus"
    }

    /// Renewal/expiration detail, only when we actually know it.
    private var renewalDetail: String? {
        guard subscription.isPremium, let expiresAt = subscription.expiresAt else { return nil }
        let date = expiresAt.formatted(date: .abbreviated, time: .omitted)
        return subscription.willRenew ? "Renews \(date)" : "Access ends \(date)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(icon: "sparkles", title: "Subscription", value: statusValue)
                    if let renewalDetail {
                        Text(renewalDetail)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if subscription.isPremium {
                        button(icon: "arrow.up.right.square", title: "Manage Subscription") {
                            if let url = services.subscription.manageSubscriptionsURL {
                                openURL(url)
                            }
                        }
                    } else {
                        button(icon: "arrow.up.circle", title: "Upgrade to Plus") {
                            showsPaywall = true
                        }
                    }
                    button(icon: "arrow.clockwise", title: "Restore Purchases") {
                        Task { await restore() }
                    }
                    .disabled(isWorking)
                } footer: {
                    if let noticeMessage {
                        Text(noticeMessage)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    button(icon: "hand.raised", title: "Privacy Policy") {
                        openURL(LegalLinks.privacy)
                    }
                    button(icon: "doc.text", title: "Terms of Use") {
                        openURL(LegalLinks.terms)
                    }
                    button(icon: "envelope", title: "Contact Support") {
                        openURL(LegalLinks.support)
                    }
                } footer: {
                    if LegalLinks.arePlaceholders {
                        Text("Development build: privacy, terms and support URLs are still placeholders.")
                            .font(Typography.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    row(icon: "info.circle", title: "Version", value: appVersion)
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Typography.caption)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsPaywall) {
            PaywallView()
        }
        .task {
            // Reflects renewals/expirations that happened while away.
            await services.subscription.refresh()
        }
    }

    // MARK: - Rows

    private func row(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: icon)
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Spacing.sm)
            Text(value)
                .font(Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func button(
        icon: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Typography.body)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func restore() async {
        isWorking = true
        noticeMessage = nil
        do {
            let restored = try await services.subscription.restorePurchases()
            noticeMessage = restored
                ? "Subscription restored."
                : "No previous subscription found on this Apple ID."
        } catch {
            noticeMessage = (error as? SubscriptionError)?.displayMessage
                ?? "Couldn't restore right now."
        }
        isWorking = false
    }
}

#Preview {
    SettingsView()
        .environment(\.services, .mock)
        .preferredColorScheme(.dark)
}
