import SwiftUI

/// Circular percentage indicator used by the Analyze experience.
struct InterestRing: View {
    let title: String
    let value: Int

    private var clampedValue: Int {
        min(max(value, 0), 100)
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ZStack {
                Circle()
                    .stroke(Theme.stroke, lineWidth: 8)

                Circle()
                    .trim(from: 0, to: Double(clampedValue) / 100)
                    .stroke(
                        Theme.brandGradient,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Text("\(clampedValue)%")
                    .font(Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
            .frame(width: 88, height: 88)

            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) interest")
        .accessibilityValue("\(clampedValue) percent")
    }
}

#Preview {
    HStack(spacing: Spacing.lg) {
        InterestRing(title: "You", value: 62)
        InterestRing(title: "Them", value: 81)
    }
    .padding()
    .background(GradientBackground())
}
