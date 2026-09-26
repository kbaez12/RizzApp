import SwiftUI

/// Opened from the three-line button in the header. Short list of app-level
/// actions; nothing here nags.
struct MenuSheet: View {
    @Environment(AppFlowModel.self) private var flow
    @Environment(\.services) private var services
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Spacing.md) {
            Text(AppBrand.wordmark)
                .font(Typography.wordmark)
                .foregroundStyle(Theme.brandGradient)
                .shadow(color: Theme.ink, radius: 0, x: 2, y: 2)
                .padding(.top, Spacing.lg)

            VStack(spacing: 0) {
                row("Email Us", systemImage: "envelope") { openURL(LegalLinks.support) }
                Divider().padding(.leading, 52)
                if !services.subscription.status.isPremium {
                    row("Upgrade to Plus", systemImage: "sparkles") { flow.choose(.upgrade) }
                    Divider().padding(.leading, 52)
                }
                row("Settings", systemImage: "gearshape") { flow.choose(.settings) }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))

            HStack(spacing: Spacing.sm) {
                Button("Terms of Use") { openURL(LegalLinks.terms) }
                Text("·")
                Button("Privacy Policy") { openURL(LegalLinks.privacy) }
            }
            .font(Typography.caption)
            .foregroundStyle(Theme.textSecondary)

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GradientBackground())
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24)
                Text(title)
                    .font(Typography.body.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Spacing.md)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
