import SwiftUI

/// Standard rounded card container used across the app.
struct Card<Content: View>: View {
    var padding: CGFloat = Spacing.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

#Preview {
    Card {
        Text("Preview card")
            .font(Typography.body)
            .foregroundStyle(Theme.textPrimary)
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
