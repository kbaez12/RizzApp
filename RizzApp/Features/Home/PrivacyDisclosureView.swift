import SwiftUI

/// First-use disclosure shown before the first AI request. Accurate, short,
/// and no dark patterns: "Not now" simply cancels the request.
struct PrivacyDisclosureView: View {
    let onAcknowledge: () -> Void
    let onCancel: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Spacer()

            Text("Before we start")
                .font(Typography.title)
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(
                    "When you upload a screenshot or paste a conversation, that content is sent to a third-party AI provider so we can write your replies or analysis."
                )
                Text(
                    "We don't keep those conversations or screenshots. They're processed to produce a result, then discarded."
                )
                Text(
                    "The AI provider processes the content you send. Their own privacy policy applies to that processing."
                )
            }
            .font(Typography.body)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Read our Privacy Policy") {
                openURL(LegalLinks.privacy)
            }
            .font(Typography.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)

            Spacer()

            VStack(spacing: Spacing.sm) {
                Button("Got it", action: onAcknowledge)
                    .buttonStyle(.primary)
                Button("Not now", action: onCancel)
                    .font(Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: 44)
            }
            .padding(.bottom, Spacing.sm)
        }
        .padding(.horizontal, Spacing.screenMargin)
        .background(GradientBackground())
    }
}

#Preview {
    PrivacyDisclosureView(onAcknowledge: {}, onCancel: {})
}
