import SwiftUI

/// Standard white rounded card with a soft shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = Spacing.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
            .shadow(color: Theme.shadow, radius: 10, y: 4)
    }
}

#Preview {
    Card {
        Text("Preview card")
            .font(Typography.body)
            .foregroundStyle(Theme.textPrimary)
    }
    .padding()
    .background(GradientBackground())
}
