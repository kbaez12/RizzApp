import SwiftUI

/// First-use disclosure shown before the first generation. Accurate,
/// short, and dismissible only by acknowledgement — no dark patterns.
struct PrivacyDisclosureView: View {
    let onAcknowledge: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Spacing.lg) {
                Spacer()

                Text("Before we start")
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(
                        "When you upload a screenshot or paste a conversation, that content is sent to a third-party AI provider so we can write your replies."
                    )
                    Text(
                        "We don't keep those conversations or screenshots as part of the normal generation flow. They're processed to produce a reply, then discarded."
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
                .font(Typography.subheadline)
                .foregroundStyle(Theme.accent)

                Spacer()

                Button("Got it", action: onAcknowledge)
                    .buttonStyle(.primary)
                    .padding(.bottom, Spacing.md)
            }
            .padding(.horizontal, Spacing.screenMargin)
        }
    }
}

#Preview {
    PrivacyDisclosureView(onAcknowledge: {})
        .preferredColorScheme(.dark)
}
