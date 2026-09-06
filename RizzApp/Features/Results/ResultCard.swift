import SwiftUI
import UIKit

/// One generated reply: strategy label, text, and a copy button with
/// lightweight "Copied" feedback. Nothing is stored — copy goes straight
/// to the pasteboard.
struct ResultCard: View {
    let response: GeneratedResponse
    @State private var copied = false

    var body: some View {
        Card(padding: Spacing.md + 4) {
            VStack(alignment: .leading, spacing: Spacing.sm + 4) {
                HStack {
                    Text(response.label.uppercased())
                        .font(Typography.caption)
                        .kerning(1.2)
                        .foregroundStyle(Theme.accent)

                    Spacer()

                    Button(action: copy) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied" : "Copy")
                        }
                        .font(Typography.caption)
                        .foregroundStyle(copied ? Theme.success : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "Copied" : "Copy response")
                }

                Text(response.text)
                    .font(Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .sensoryFeedback(.success, trigger: copied) { _, newValue in newValue }
    }

    private func copy() {
        UIPasteboard.general.string = response.text
        withAnimation(.spring(duration: 0.25)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.25)) { copied = false }
        }
    }
}

#Preview {
    ResultCard(
        response: GeneratedResponse(
            type: .natural,
            label: "Natural",
            text: "gotta keep you interested somehow"
        )
    )
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
