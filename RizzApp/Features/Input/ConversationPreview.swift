import SwiftUI

/// Renders a mock conversation as chat bubbles — the Phase 2 stand-in for a
/// real screenshot. In Phase 3 the preview shows the user's selected image
/// instead, and this view remains only for previews/mocking.
struct ConversationPreview: View {
    let conversation: MockConversation

    var body: some View {
        VStack(spacing: Spacing.sm + 2) {
            ForEach(conversation.messages) { message in
                Text(message.text)
                    .font(Typography.body)
                    .foregroundStyle(message.isFromUser ? Theme.textOnAccent : Theme.textPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm + 2)
                    .background(
                        message.isFromUser ? Theme.accent : Theme.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: message.isFromUser ? .trailing : .leading
                    )
            }
        }
    }
}

#Preview {
    ConversationPreview(conversation: MockConversation.samples[0])
        .padding()
        .background(Theme.background)
        .preferredColorScheme(.dark)
}
